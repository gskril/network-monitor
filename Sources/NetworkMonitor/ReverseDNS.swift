import Darwin
import Foundation

/// Best-effort reverse-DNS lookups with a cache. getnameinfo blocks, so
/// lookups run off the actor; results (including failures) are cached.
actor ReverseDNS {
    static let shared = ReverseDNS()

    private var cache: [String: String?] = [:]

    func resolve(_ endpoint: Endpoint) async -> String? {
        let ip = endpoint.ip
        guard shouldResolve(ip) else { return nil }
        if let cached = cache[ip] { return cached }

        let result = await Task.detached(priority: .utility) {
            Self.lookup(endpoint)
        }.value
        cache[ip] = result
        return result
    }

    private func shouldResolve(_ ip: String) -> Bool {
        if ip.isEmpty || ip == "0.0.0.0" || ip == "::" { return false }
        if ip.hasPrefix("127.") || ip == "::1" { return false }
        if ip.hasPrefix("169.254.") || ip.lowercased().hasPrefix("fe80") { return false }
        // Multicast
        if ip.lowercased().hasPrefix("ff") && ip.contains(":") { return false }
        if let firstOctet = ip.split(separator: ".").first, let value = UInt8(firstOctet), (224...239).contains(value) { return false }
        return true
    }

    private static func lookup(_ endpoint: Endpoint) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result: Int32
        if endpoint.family == AF_INET {
            var sa = sockaddr_in()
            sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            sa.sin_family = sa_family_t(AF_INET)
            guard inet_pton(AF_INET, endpoint.ip, &sa.sin_addr) == 1 else { return nil }
            result = withUnsafePointer(to: &sa) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
                }
            }
        } else if endpoint.family == AF_INET6 {
            var sa = sockaddr_in6()
            sa.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            sa.sin6_family = sa_family_t(AF_INET6)
            guard inet_pton(AF_INET6, endpoint.ip, &sa.sin6_addr) == 1 else { return nil }
            result = withUnsafePointer(to: &sa) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in6>.size), &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
                }
            }
        } else {
            return nil
        }
        guard result == 0 else { return nil }
        let name = String(cString: host)
        return name.isEmpty ? nil : name
    }
}
