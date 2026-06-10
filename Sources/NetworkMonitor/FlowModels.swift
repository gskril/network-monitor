import Darwin
import Foundation
import SwiftUI

struct Endpoint: Equatable {
    var ip: String
    var port: UInt16
    var family: Int32

    var isUnspecified: Bool {
        ip == "0.0.0.0" || ip == "::" || ip.isEmpty
    }

    var isLoopback: Bool {
        ip == "::1" || ip.hasPrefix("127.")
    }

    /// Parses a sockaddr stored in a CFData value from a flow description.
    static func from(sockaddrData data: Data) -> Endpoint? {
        guard data.count >= 2 else { return nil }
        let family = Int32(data[data.startIndex + 1])
        if family == AF_INET, data.count >= MemoryLayout<sockaddr_in>.size {
            return data.withUnsafeBytes { raw in
                var sa = raw.load(as: sockaddr_in.self)
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &sa.sin_addr, &buf, socklen_t(buf.count))
                return Endpoint(ip: String(cString: buf), port: UInt16(bigEndian: sa.sin_port), family: AF_INET)
            }
        }
        if family == AF_INET6, data.count >= MemoryLayout<sockaddr_in6>.size {
            return data.withUnsafeBytes { raw in
                var sa = raw.load(as: sockaddr_in6.self)
                var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                inet_ntop(AF_INET6, &sa.sin6_addr, &buf, socklen_t(buf.count))
                return Endpoint(ip: String(cString: buf), port: UInt16(bigEndian: sa.sin6_port), family: AF_INET6)
            }
        }
        return nil
    }
}

/// One snapshot of a flow's state, parsed from an NStat description dictionary.
struct FlowDescription {
    var processName: String?
    var pid: Int32?
    var provider: String?
    var tcpState: String?
    var local: Endpoint?
    var remote: Endpoint?
    var interfaceIndex: UInt32?
    var rxBytes: UInt64?
    var txBytes: UInt64?
    var startMachTime: UInt64?

    var rxPackets: UInt64?
    var txPackets: UInt64?
    var retransmittedBytes: UInt64?
    var rxDuplicateBytes: UInt64?
    var rxOutOfOrderBytes: UInt64?
    var rttAverage: Double?
    var rttMinimum: Double?
    var rttVariation: Double?
    var congestionAlgorithm: String?
    var interfaceKind: String?
    var isExpensiveInterface: Bool = false

    init(dictionary: [String: Any]) {
        processName = dictionary["processName"] as? String
        pid = (dictionary["processID"] as? NSNumber)?.int32Value
        provider = dictionary["provider"] as? String
        tcpState = dictionary["TCPState"] as? String
        if let data = dictionary["localAddress"] as? Data {
            local = Endpoint.from(sockaddrData: data)
        }
        if let data = dictionary["remoteAddress"] as? Data {
            remote = Endpoint.from(sockaddrData: data)
        }
        interfaceIndex = (dictionary["interface"] as? NSNumber)?.uint32Value
        rxBytes = (dictionary["rxBytes"] as? NSNumber)?.uint64Value
        txBytes = (dictionary["txBytes"] as? NSNumber)?.uint64Value
        startMachTime = (dictionary["startAbsoluteTime"] as? NSNumber)?.uint64Value

        rxPackets = (dictionary["rxPackets"] as? NSNumber)?.uint64Value
        txPackets = (dictionary["txPackets"] as? NSNumber)?.uint64Value
        retransmittedBytes = (dictionary["txRetransmittedBytes"] as? NSNumber)?.uint64Value
        rxDuplicateBytes = (dictionary["rxDuplicateBytes"] as? NSNumber)?.uint64Value
        rxOutOfOrderBytes = (dictionary["rxOutOfOrderBytes"] as? NSNumber)?.uint64Value

        // RTT values are reported as floating-point seconds; 0 means unmeasured.
        func seconds(_ key: String) -> Double? {
            guard let value = (dictionary[key] as? NSNumber)?.doubleValue, value > 0 else { return nil }
            return value
        }
        rttAverage = seconds("rttAverage")
        rttMinimum = seconds("rttMinimum")
        rttVariation = seconds("rttVariation")
        congestionAlgorithm = dictionary["congestionAlgorithm"] as? String

        func flag(_ key: String) -> Bool {
            (dictionary[key] as? NSNumber)?.boolValue ?? false
        }
        if flag("ifWiFi") { interfaceKind = "Wi-Fi" }
        else if flag("ifWired") || flag("ifEthernet") { interfaceKind = "Wired" }
        else if flag("ifCellular") { interfaceKind = "Cellular" }
        else if flag("ifLoopback") { interfaceKind = "Loopback" }
        else if flag("ifAWDL") { interfaceKind = "AWDL" }
        isExpensiveInterface = flag("ifExpensive")
    }
}

enum FlowKind: String {
    case https = "HTTPS"
    case quic = "QUIC"
    case http = "HTTP"
    case dns = "DNS"
    case dnsCrypt = "DNS/TLS"
    case mdns = "mDNS"
    case ntp = "NTP"
    case ssh = "SSH"
    case smtp = "SMTP"
    case imap = "IMAPS"
    case apns = "APNs"
    case dhcp = "DHCP"
    case ssdp = "SSDP"
    case stun = "STUN"
    case vpn = "VPN"
    case listen = "Listen"
    case tcp = "TCP"
    case udp = "UDP"

    var color: Color {
        switch self {
        case .https: .blue
        case .quic: .teal
        case .http: .orange
        case .dns, .dnsCrypt: .purple
        case .mdns: .indigo
        case .ntp: .brown
        case .ssh: .green
        case .smtp, .imap: .cyan
        case .apns: .red
        case .dhcp, .ssdp, .stun: .mint
        case .vpn: .yellow
        case .listen: .gray
        case .tcp: .secondary
        case .udp: .secondary
        }
    }

    static func classify(provider: String?, tcpState: String?, remote: Endpoint?, local: Endpoint?) -> FlowKind {
        let isTCP = provider == "TCP"
        if isTCP, tcpState == "Listen" { return .listen }

        // Classify by the well-known port: remote if connected, else local
        // (e.g. mDNSResponder's unconnected UDP socket bound to 5353).
        let port: UInt16? = {
            if let remote, !remote.isUnspecified, remote.port != 0 { return remote.port }
            if let local, local.port != 0 { return local.port }
            return nil
        }()

        switch port {
        case 443: return isTCP ? .https : .quic
        case 80: return isTCP ? .http : .udp
        case 53: return .dns
        case 853: return .dnsCrypt
        case 5353: return .mdns
        case 123: return .ntp
        case 22: return .ssh
        case 25, 465, 587: return .smtp
        case 993: return .imap
        case 5223: return .apns
        case 67, 68, 546, 547: return .dhcp
        case 1900: return .ssdp
        case 3478: return .stun
        case 500, 4500, 51820: return .vpn
        default: return isTCP ? .tcp : .udp
        }
    }
}

/// Identity used to coalesce repeated flows (e.g. a burst of UDP probes from
/// one process to the same destination) into a single row with a counter.
struct FlowKey: Hashable {
    var pid: Int32
    var processName: String
    var remoteIP: String
    var remotePort: UInt16
    var provider: String
}

/// Connection-quality details shown in the inspector. Counters accumulate
/// across coalesced flows; quality readings reflect the latest report.
struct FlowStats {
    var rxPackets: UInt64 = 0
    var txPackets: UInt64 = 0
    var retransmittedBytes: UInt64 = 0
    var rxDuplicateBytes: UInt64 = 0
    var rxOutOfOrderBytes: UInt64 = 0
    var rttAverage: Double?
    var rttMinimum: Double?
    var rttVariation: Double?
    var congestionAlgorithm: String?
    var interfaceKind: String?
    var isExpensiveInterface = false

    mutating func updateQuality(from description: FlowDescription) {
        if let rtt = description.rttAverage { rttAverage = rtt }
        if let rtt = description.rttMinimum { rttMinimum = rtt }
        if let rtt = description.rttVariation { rttVariation = rtt }
        if let algorithm = description.congestionAlgorithm { congestionAlgorithm = algorithm }
        if let kind = description.interfaceKind { interfaceKind = kind }
        if description.isExpensiveInterface { isExpensiveInterface = true }
    }

    mutating func absorbCounters(of other: FlowStats) {
        rxPackets += other.rxPackets
        txPackets += other.txPackets
        retransmittedBytes += other.retransmittedBytes
        rxDuplicateBytes += other.rxDuplicateBytes
        rxOutOfOrderBytes += other.rxOutOfOrderBytes
        if rttAverage == nil { rttAverage = other.rttAverage }
        if rttMinimum == nil { rttMinimum = other.rttMinimum }
        if rttVariation == nil { rttVariation = other.rttVariation }
        if congestionAlgorithm == nil { congestionAlgorithm = other.congestionAlgorithm }
        if interfaceKind == nil { interfaceKind = other.interfaceKind }
        isExpensiveInterface = isExpensiveInterface || other.isExpensiveInterface
    }
}

/// A row in the UI: one flow (or a group of coalesced identical flows),
/// updated in place as its state evolves.
struct FlowRow: Identifiable {
    let id: UInt64
    var startedAt: Date
    var lastSeenAt: Date
    var count: Int
    var openCount: Int
    var members: [UInt64]
    var key: FlowKey?
    var preexisting: Bool
    var processPath: String?
    var stats = FlowStats()
    var processName: String
    var pid: Int32
    var provider: String
    var tcpState: String?
    var local: Endpoint?
    var remote: Endpoint?
    var remoteHost: String?
    var interfaceName: String?
    var rxBytes: UInt64
    var txBytes: UInt64
    var isClosed: Bool
    var kind: FlowKind

    var hasRemote: Bool {
        guard let remote else { return false }
        return !remote.isUnspecified && remote.port != 0
    }

    var isLoopback: Bool {
        (remote?.isLoopback ?? false) || (local?.isLoopback ?? false) || interfaceName == "lo0"
    }

    var remoteDisplay: String {
        guard let remote, !remote.isUnspecified else { return "—" }
        return remoteHost ?? remote.ip
    }

    var stateDisplay: String {
        if isClosed { return "Closed" }
        if let tcpState { return tcpState }
        return "—"
    }
}

enum MachTime {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Converts a kernel mach_absolute_time stamp to a wall-clock Date.
    static func toDate(_ machTime: UInt64) -> Date {
        let now = mach_absolute_time()
        guard machTime > 0, machTime <= now else { return Date() }
        let elapsedNs = Double(now - machTime) * Double(timebase.numer) / Double(timebase.denom)
        return Date(timeIntervalSinceNow: -elapsedNs / 1_000_000_000)
    }
}

func processPath(forPID pid: Int32) -> String? {
    guard pid > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return String(cString: buffer)
}

func interfaceName(forIndex index: UInt32) -> String? {
    guard index > 0 else { return nil }
    var buf = [CChar](repeating: 0, count: Int(IFNAMSIZ) + 1)
    guard if_indextoname(index, &buf) != nil else { return nil }
    return String(cString: buf)
}
