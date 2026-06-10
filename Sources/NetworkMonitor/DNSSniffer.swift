import CDNSSniff
import Darwin
import Foundation
import SystemConfiguration

/// Thread-safe IP→hostname store populated by the DNS sniffer. Authoritative:
/// these names come from the app's own DNS lookups, not reverse-DNS guesses.
final class DNSCache: @unchecked Sendable {
    static let shared = DNSCache()

    private let lock = NSLock()
    private var map: [String: String] = [:]

    func record(ip: String, host: String) {
        lock.lock(); defer { lock.unlock() }
        map[ip] = host
    }

    func host(for ip: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return map[ip]
    }
}

/// Captures DNS responses via libpcap and records IP→hostname mappings.
/// Requires BPF access (the install-bpf-helper.sh helper, or running as root);
/// if it can't open the device it disables itself and the app falls back to
/// reverse DNS.
final class DNSSniffer: @unchecked Sendable {
    enum Status: Equatable {
        case inactive
        case active(interface: String)
        case denied
        case unavailable(String)
    }

    private let onLearn: (DNSParser.Mapping) -> Void
    private let onStatus: (Status) -> Void
    private var handle: OpaquePointer?
    private var thread: Thread?
    private var stopping = false

    init(onLearn: @escaping (DNSParser.Mapping) -> Void, onStatus: @escaping (Status) -> Void) {
        self.onLearn = onLearn
        self.onStatus = onStatus
    }

    func start() {
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "com.greg.networkmonitor.dns"
        thread.stackSize = 1 << 20
        self.thread = thread
        thread.start()
    }

    func stop() {
        stopping = true
        if let handle { cdns_breakloop(handle) }
    }

    private func run() {
        guard let iface = Self.primaryInterface() else {
            onStatus(.unavailable("no primary network interface"))
            return
        }

        var errbuf = [CChar](repeating: 0, count: 256)
        // Capture both unicast DNS (53) and multicast DNS (5353).
        guard let handle = "udp port 53 or udp port 5353".withCString({ filter in
            iface.withCString { ifname in
                cdns_open(ifname, filter, &errbuf, Int32(errbuf.count))
            }
        }) else {
            let message = String(cString: errbuf)
            // pcap reports permission problems with varied wording.
            if message.localizedCaseInsensitiveContains("permission")
                || message.localizedCaseInsensitiveContains("denied")
                || message.localizedCaseInsensitiveContains("operation not permitted") {
                onStatus(.denied)
            } else {
                onStatus(.unavailable(message))
            }
            return
        }
        self.handle = handle
        defer {
            cdns_close(handle)
            self.handle = nil
        }

        let linkType = cdns_datalink(handle)
        onStatus(.active(interface: iface))

        while !stopping {
            var data: UnsafePointer<UInt8>? = nil
            var length: UInt32 = 0
            let rc = cdns_next(handle, &data, &length)
            if rc == 1, let data, length > 0 {
                let frame = Array(UnsafeBufferPointer(start: data, count: Int(length)))
                for mapping in DNSParser.mappings(fromFrame: frame, linkType: linkType) {
                    DNSCache.shared.record(ip: mapping.ip, host: mapping.host)
                    onLearn(mapping)
                }
            } else if rc < 0 {
                break
            }
        }
        if !stopping {
            onStatus(.unavailable("capture ended"))
        }
    }

    /// The interface carrying the default route — where DNS queries go.
    static func primaryInterface() -> String? {
        let key = "State:/Network/Global/IPv4" as CFString
        guard let store = SCDynamicStoreCreate(nil, "NetworkMonitor" as CFString, nil, nil),
              let info = SCDynamicStoreCopyValue(store, key) as? [String: Any],
              let iface = info["PrimaryInterface"] as? String else {
            return nil
        }
        return iface
    }
}
