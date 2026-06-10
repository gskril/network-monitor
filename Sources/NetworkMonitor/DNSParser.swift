import Darwin
import Foundation

/// Parses captured frames into (IP address → queried hostname) mappings.
///
/// Strategy: for each DNS *response*, take the first question's name (the
/// hostname the app actually asked for) and map every A/AAAA answer address
/// to it — following CNAME chains implicitly, since the question name is what
/// the user cares about, not the canonical alias.
enum DNSParser {
    // Link-layer types we handle (from <pcap/dlt.h>).
    static let dltNull: Int32 = 0
    static let dltEN10MB: Int32 = 1
    static let dltRaw: Int32 = 12
    static let dltLoop: Int32 = 108

    struct Mapping {
        var ip: String
        var host: String
    }

    static func mappings(fromFrame frame: [UInt8], linkType: Int32) -> [Mapping] {
        guard let ip = ipPayload(of: frame, linkType: linkType) else { return [] }
        guard let udp = udpPayload(of: ip.bytes, offset: ip.offset, version: ip.version) else { return [] }
        return parseDNS(frame, range: udp)
    }

    // MARK: - Link layer

    private static func ipPayload(of frame: [UInt8], linkType: Int32) -> (bytes: [UInt8], offset: Int, version: Int)? {
        var offset: Int
        switch linkType {
        case dltEN10MB:
            guard frame.count >= 14 else { return nil }
            var etherType = (UInt16(frame[12]) << 8) | UInt16(frame[13])
            offset = 14
            // Skip up to two 802.1Q VLAN tags.
            var guardCount = 0
            while etherType == 0x8100, frame.count >= offset + 4, guardCount < 2 {
                etherType = (UInt16(frame[offset + 2]) << 8) | UInt16(frame[offset + 3])
                offset += 4
                guardCount += 1
            }
            switch etherType {
            case 0x0800: return version(of: frame, at: offset, expect: 4)
            case 0x86DD: return version(of: frame, at: offset, expect: 6)
            default: return nil
            }
        case dltRaw:
            return version(of: frame, at: 0, expect: nil)
        case dltNull, dltLoop:
            // 4-byte protocol family header (host byte order for NULL).
            guard frame.count >= 4 else { return nil }
            let family = linkType == dltNull
                ? UInt32(frame[0]) | (UInt32(frame[1]) << 8) | (UInt32(frame[2]) << 16) | (UInt32(frame[3]) << 24)
                : (UInt32(frame[0]) << 24) | (UInt32(frame[1]) << 16) | (UInt32(frame[2]) << 8) | UInt32(frame[3])
            switch family {
            case UInt32(AF_INET): return version(of: frame, at: 4, expect: 4)
            case 30, 28: return version(of: frame, at: 4, expect: 6) // AF_INET6 varies across BSDs
            default: return nil
            }
        default:
            return nil
        }
    }

    private static func version(of frame: [UInt8], at offset: Int, expect: Int?) -> (bytes: [UInt8], offset: Int, version: Int)? {
        guard frame.count > offset else { return nil }
        let ver = Int(frame[offset] >> 4)
        guard ver == 4 || ver == 6 else { return nil }
        if let expect, expect != ver { return nil }
        return (frame, offset, ver)
    }

    // MARK: - IP + UDP

    /// Returns the byte range of the UDP payload within `bytes`.
    private static func udpPayload(of bytes: [UInt8], offset: Int, version: Int) -> Range<Int>? {
        if version == 4 {
            guard bytes.count >= offset + 20 else { return nil }
            let ihl = Int(bytes[offset] & 0x0F) * 4
            guard ihl >= 20, bytes.count >= offset + ihl + 8 else { return nil }
            guard bytes[offset + 9] == 17 else { return nil } // UDP
            let udpStart = offset + ihl
            return udpDataRange(bytes, udpStart: udpStart)
        } else {
            guard bytes.count >= offset + 40 else { return nil }
            guard bytes[offset + 6] == 17 else { return nil } // next header = UDP (no ext headers)
            let udpStart = offset + 40
            guard bytes.count >= udpStart + 8 else { return nil }
            return udpDataRange(bytes, udpStart: udpStart)
        }
    }

    private static func udpDataRange(_ bytes: [UInt8], udpStart: Int) -> Range<Int>? {
        let length = Int(bytes[udpStart + 4]) << 8 | Int(bytes[udpStart + 5])
        let dataStart = udpStart + 8
        // UDP length includes the 8-byte header; clamp to what we captured.
        let declaredEnd = udpStart + max(length, 8)
        let end = min(declaredEnd, bytes.count)
        guard dataStart <= end else { return nil }
        return dataStart..<end
    }

    // MARK: - DNS

    private static func parseDNS(_ bytes: [UInt8], range: Range<Int>) -> [Mapping] {
        let base = range.lowerBound
        let msg = bytes // index relative to `base`; compression offsets are from `base`
        func u16(_ i: Int) -> Int { Int(msg[i]) << 8 | Int(msg[i + 1]) }

        guard range.count >= 12 else { return [] }
        let flags = u16(base + 2)
        guard flags & 0x8000 != 0 else { return [] }     // responses only (QR=1)
        guard flags & 0x000F == 0 else { return [] }      // RCODE 0 (NoError)
        let qdCount = u16(base + 4)
        let anCount = u16(base + 6)
        guard qdCount >= 1, anCount >= 1 else { return [] }

        var cursor = base + 12

        // First question name = the hostname the app asked for.
        guard let (qname, afterName) = readName(msg, at: cursor, messageStart: base, end: range.upperBound) else { return [] }
        cursor = afterName + 4 // QTYPE + QCLASS
        guard !qname.isEmpty else { return [] }

        // Remaining questions (rare) — skip past them.
        for _ in 1..<max(qdCount, 1) {
            guard qdCount > 1, let (_, after) = readName(msg, at: cursor, messageStart: base, end: range.upperBound) else { break }
            cursor = after + 4
        }

        var results: [Mapping] = []
        for _ in 0..<anCount {
            guard let (_, afterRecordName) = readName(msg, at: cursor, messageStart: base, end: range.upperBound) else { break }
            var i = afterRecordName
            guard i + 10 <= range.upperBound else { break }
            let type = u16(i)
            let rdLength = u16(i + 8)
            i += 10
            guard i + rdLength <= range.upperBound else { break }
            switch type {
            case 1 where rdLength == 4:
                let ip = "\(msg[i]).\(msg[i + 1]).\(msg[i + 2]).\(msg[i + 3])"
                results.append(Mapping(ip: ip, host: qname))
            case 28 where rdLength == 16:
                if let ip = formatIPv6(Array(msg[i..<i + 16])) {
                    results.append(Mapping(ip: ip, host: qname))
                }
            default:
                break
            }
            i += rdLength
            cursor = i
        }
        return results
    }

    /// Reads a (possibly compressed) DNS name. Returns the decoded name and
    /// the index immediately after the name in the record stream (for a
    /// compressed name, after the 2-byte pointer).
    private static func readName(_ msg: [UInt8], at start: Int, messageStart: Int, end: Int) -> (name: String, next: Int)? {
        var labels: [String] = []
        var i = start
        var next = -1
        var hops = 0
        while i < end {
            let length = Int(msg[i])
            if length == 0 {
                if next < 0 { next = i + 1 }
                break
            }
            if length & 0xC0 == 0xC0 {
                // Compression pointer: 14-bit offset from message start.
                guard i + 1 < end else { return nil }
                if next < 0 { next = i + 2 }
                let pointer = (length & 0x3F) << 8 | Int(msg[i + 1])
                i = messageStart + pointer
                hops += 1
                guard hops < 128, i >= messageStart, i < end else { return nil }
                continue
            }
            let labelStart = i + 1
            guard labelStart + length <= end else { return nil }
            if let label = String(bytes: msg[labelStart..<labelStart + length], encoding: .utf8) {
                labels.append(label)
            } else {
                return nil
            }
            i = labelStart + length
        }
        if next < 0 { next = i + 1 }
        return (labels.joined(separator: "."), next)
    }

    private static func formatIPv6(_ bytes: [UInt8]) -> String? {
        guard bytes.count == 16 else { return nil }
        var addr = in6_addr()
        withUnsafeMutableBytes(of: &addr) { raw in
            for index in 0..<16 { raw[index] = bytes[index] }
        }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &addr, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return String(cString: buffer)
    }
}
