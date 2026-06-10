import Darwin
import Foundation

/// Minimal reader for the MaxMind DB (.mmdb) binary format, which DB-IP's free
/// "IP to City Lite" database also uses. Resolves an IP to an approximate
/// city/country and lat/long, fully offline. The file is memory-mapped, so the
/// ~120MB database isn't held resident.
///
/// Format reference: https://maxmind.github.io/MaxMind-DB/
final class GeoIP: @unchecked Sendable {
    struct Location {
        var latitude: Double
        var longitude: Double
        var city: String?
        var country: String?
        var countryCode: String?
    }

    private let data: Data
    private let nodeCount: Int
    private let recordSize: Int
    private let nodeByteSize: Int
    private let searchTreeSize: Int
    private let ipVersion: Int

    private let lock = NSLock()
    private var cache: [String: Location?] = [:]

    init?(path: String) {
        guard let mapped = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else {
            return nil
        }
        self.data = mapped

        // Metadata follows the last occurrence of this marker (raw bytes
        // 0xAB 0xCD 0xEF, then the ASCII "MaxMind.com").
        let marker: [UInt8] = [0xAB, 0xCD, 0xEF] + Array("MaxMind.com".utf8)
        guard let markerStart = Self.lastIndex(of: marker, in: mapped) else { return nil }
        let metaStart = markerStart + marker.count
        let decoder = Decoder(data: mapped, pointerBase: metaStart)
        guard case let .map(meta) = decoder.decode(at: metaStart).value,
              case let .uint(nodeCount) = meta["node_count"],
              case let .uint(recordSize) = meta["record_size"],
              case let .uint(ipVersion) = meta["ip_version"] else {
            return nil
        }
        self.nodeCount = Int(nodeCount)
        self.recordSize = Int(recordSize)
        self.ipVersion = Int(ipVersion)
        self.nodeByteSize = Int(recordSize) * 2 / 8
        self.searchTreeSize = Int(nodeCount) * nodeByteSize
    }

    func lookup(_ ip: String) -> Location? {
        lock.lock()
        if let cached = cache[ip] { lock.unlock(); return cached }
        lock.unlock()

        let result = resolve(ip)

        lock.lock()
        cache[ip] = result
        lock.unlock()
        return result
    }

    // MARK: - Tree traversal

    private func resolve(_ ip: String) -> Location? {
        guard let bits = Self.addressBits(ip) else { return nil }
        var node = 0
        // For an IPv6 database, walk IPv4 addresses as IPv4-mapped (::ffff:a.b.c.d).
        let walk = (bits.count == 32 && ipVersion == 6) ? Self.ipv4MappedBits(bits) : bits

        for bit in walk {
            if node >= nodeCount { break }
            node = record(node: node, right: bit == 1)
            if node == nodeCount { return nil }       // explicit "no data"
            if node > nodeCount { break }              // reached a data pointer
        }
        guard node > nodeCount else { return nil }
        let offset = (node - nodeCount) + searchTreeSize
        return parseLocation(at: offset)
    }

    private func record(node: Int, right: Bool) -> Int {
        let base = node * nodeByteSize
        switch recordSize {
        case 24:
            let i = base + (right ? 3 : 0)
            return Int(data[i]) << 16 | Int(data[i + 1]) << 8 | Int(data[i + 2])
        case 28:
            if right {
                return Int(data[base + 4]) << 16 | Int(data[base + 5]) << 8 | Int(data[base + 6])
                    | (Int(data[base + 3] & 0x0F) << 24)
            } else {
                return Int(data[base]) << 16 | Int(data[base + 1]) << 8 | Int(data[base + 2])
                    | (Int(data[base + 3] & 0xF0) << 20)
            }
        case 32:
            let i = base + (right ? 4 : 0)
            return Int(data[i]) << 24 | Int(data[i + 1]) << 16 | Int(data[i + 2]) << 8 | Int(data[i + 3])
        default:
            return nodeCount // force "no data"
        }
    }

    // MARK: - Record decoding

    private func parseLocation(at offset: Int) -> Location? {
        let decoder = Decoder(data: data, pointerBase: searchTreeSize + 16)
        guard case let .map(top) = decoder.decode(at: offset).value else { return nil }

        func string(_ value: Value?) -> String? {
            if case let .string(s) = value { return s }
            return nil
        }
        func enName(_ value: Value?) -> String? {
            if case let .map(names) = value { return string(names["en"]) }
            return nil
        }
        func double(_ value: Value?) -> Double? {
            switch value {
            case let .double(d): return d
            case let .uint(u): return Double(u)
            default: return nil
            }
        }

        var city: String?
        if case let .map(cityMap) = top["city"] { city = enName(cityMap["names"]) }
        var country: String?
        var code: String?
        if case let .map(countryMap) = top["country"] {
            country = enName(countryMap["names"])
            code = string(countryMap["iso_code"])
        }
        guard case let .map(loc) = top["location"],
              let lat = double(loc["latitude"]),
              let lon = double(loc["longitude"]) else {
            return nil
        }
        return Location(latitude: lat, longitude: lon, city: city, country: country, countryCode: code)
    }

    // MARK: - Address parsing

    private static func addressBits(_ ip: String) -> [UInt8]? {
        var v4 = in_addr()
        if inet_pton(AF_INET, ip, &v4) == 1 {
            let bytes = withUnsafeBytes(of: v4.s_addr) { Array($0) }
            return bytes.flatMap { byte in (0..<8).map { UInt8((byte >> (7 - $0)) & 1) } }
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, ip, &v6) == 1 {
            let bytes = withUnsafeBytes(of: v6) { Array($0) }
            return bytes.flatMap { byte in (0..<8).map { UInt8((byte >> (7 - $0)) & 1) } }
        }
        return nil
    }

    /// 96-bit IPv4-mapped prefix (::ffff:0:0/96) + the 32 address bits.
    private static func ipv4MappedBits(_ v4Bits: [UInt8]) -> [UInt8] {
        var bits = [UInt8](repeating: 0, count: 80)
        bits += [UInt8](repeating: 1, count: 16)
        bits += v4Bits
        return bits
    }

    private static func lastIndex(of pattern: [UInt8], in data: Data) -> Int? {
        guard data.count >= pattern.count else { return nil }
        // Search backwards from the end (metadata lives in the last 128KB).
        let searchStart = max(0, data.count - 128 * 1024)
        var i = data.count - pattern.count
        while i >= searchStart {
            var match = true
            for j in 0..<pattern.count where data[i + j] != pattern[j] {
                match = false
                break
            }
            if match { return i }
            i -= 1
        }
        return nil
    }

    // MARK: - mmdb data-section decoder

    private enum Value {
        case map([String: Value])
        case array([Value])
        case string(String)
        case double(Double)
        case float(Float)
        case bytes([UInt8])
        case uint(UInt64)
        case int(Int64)
        case bool(Bool)
        case null
    }

    private struct Decoder {
        let data: Data
        let pointerBase: Int

        /// Decodes the value at `offset`, returning it and the offset just past it.
        func decode(at offset: Int) -> (value: Value, next: Int) {
            var i = offset
            let control = Int(data[i]); i += 1
            var type = control >> 5
            if type == 0 { // extended type
                type = 7 + Int(data[i]); i += 1
            }

            if type == 1 { // pointer
                let size = (control >> 3) & 0x3
                let lowBits = control & 0x7
                var pointer: Int
                switch size {
                case 0:
                    pointer = (lowBits << 8) | Int(data[i]); i += 1
                case 1:
                    pointer = ((lowBits << 16) | (Int(data[i]) << 8) | Int(data[i + 1])) + 2048; i += 2
                case 2:
                    pointer = ((lowBits << 24) | (Int(data[i]) << 16) | (Int(data[i + 1]) << 8) | Int(data[i + 2])) + 526336; i += 3
                default:
                    pointer = (Int(data[i]) << 24) | (Int(data[i + 1]) << 16) | (Int(data[i + 2]) << 8) | Int(data[i + 3]); i += 4
                }
                let target = decode(at: pointerBase + pointer).value
                return (target, i)
            }

            var size = control & 0x1F
            if size >= 29 {
                switch size {
                case 29: size = 29 + Int(data[i]); i += 1
                case 30: size = 285 + (Int(data[i]) << 8 | Int(data[i + 1])); i += 2
                default: size = 65821 + (Int(data[i]) << 16 | Int(data[i + 1]) << 8 | Int(data[i + 2])); i += 3
                }
            }

            switch type {
            case 2: // UTF-8 string
                let s = String(bytes: data[i..<i + size], encoding: .utf8) ?? ""
                return (.string(s), i + size)
            case 3: // double
                return (.double(Double(bitPattern: readUInt(at: i, size: 8))), i + 8)
            case 4: // bytes
                return (.bytes(Array(data[i..<i + size])), i + size)
            case 5, 6, 9, 10: // uint16/32/64/128 (128 truncated to 64)
                return (.uint(readUInt(at: i, size: size)), i + size)
            case 7: // map
                var map: [String: Value] = [:]
                var cursor = i
                for _ in 0..<size {
                    let (key, afterKey) = decode(at: cursor)
                    let (value, afterValue) = decode(at: afterKey)
                    if case let .string(k) = key { map[k] = value }
                    cursor = afterValue
                }
                return (.map(map), cursor)
            case 8: // int32
                let raw = readUInt(at: i, size: size)
                return (.int(Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: raw)))), i + size)
            case 11: // array
                var array: [Value] = []
                var cursor = i
                for _ in 0..<size {
                    let (value, after) = decode(at: cursor)
                    array.append(value)
                    cursor = after
                }
                return (.array(array), cursor)
            case 14: // bool
                return (.bool(size != 0), i)
            case 15: // float
                return (.float(Float(bitPattern: UInt32(truncatingIfNeeded: readUInt(at: i, size: 4)))), i + 4)
            default:
                return (.null, i + size)
            }
        }

        private func readUInt(at offset: Int, size: Int) -> UInt64 {
            var value: UInt64 = 0
            for k in 0..<size {
                value = (value << 8) | UInt64(data[offset + k])
            }
            return value
        }
    }
}
