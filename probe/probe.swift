// Probe for the private NetworkStatistics.framework API.
// Verifies that NStatManager delivers per-flow callbacks with usable
// description dictionaries on this macOS version before the app is built on it.

import Foundation

let frameworkPath = "/System/Library/PrivateFrameworks/NetworkStatistics.framework/NetworkStatistics"

guard let handle = dlopen(frameworkPath, RTLD_NOW) else {
    fatalError("dlopen failed: \(String(cString: dlerror()))")
}

func sym(_ name: String) -> UnsafeMutableRawPointer {
    guard let p = dlsym(handle, name) else {
        fatalError("missing symbol: \(name)")
    }
    return p
}

typealias SourceCallback = @convention(block) (UnsafeMutableRawPointer?) -> Void
typealias DescriptionCallback = @convention(block) (CFDictionary?) -> Void
typealias RemovedCallback = @convention(block) () -> Void

typealias NStatManagerCreateFn = @convention(c) (CFAllocator?, DispatchQueue, @escaping SourceCallback) -> UnsafeMutableRawPointer?
typealias NStatManagerAddAllFn = @convention(c) (UnsafeMutableRawPointer?) -> Int32
typealias NStatSourceSetDescriptionBlockFn = @convention(c) (UnsafeMutableRawPointer?, @escaping DescriptionCallback) -> Void
typealias NStatSourceSetRemovedBlockFn = @convention(c) (UnsafeMutableRawPointer?, @escaping RemovedCallback) -> Void
typealias NStatSourceQueryDescriptionFn = @convention(c) (UnsafeMutableRawPointer?) -> Void

let NStatManagerCreate = unsafeBitCast(sym("NStatManagerCreate"), to: NStatManagerCreateFn.self)
let NStatManagerAddAllTCP = unsafeBitCast(sym("NStatManagerAddAllTCP"), to: NStatManagerAddAllFn.self)
let NStatManagerAddAllUDP = unsafeBitCast(sym("NStatManagerAddAllUDP"), to: NStatManagerAddAllFn.self)
let NStatSourceSetDescriptionBlock = unsafeBitCast(sym("NStatSourceSetDescriptionBlock"), to: NStatSourceSetDescriptionBlockFn.self)
let NStatSourceSetRemovedBlock = unsafeBitCast(sym("NStatSourceSetRemovedBlock"), to: NStatSourceSetRemovedBlockFn.self)
let NStatSourceQueryDescription = unsafeBitCast(sym("NStatSourceQueryDescription"), to: NStatSourceQueryDescriptionFn.self)

func describeValue(_ value: Any) -> String {
    if let data = value as? Data {
        // Likely a sockaddr; show family + parsed address if possible
        var out = "<data \(data.count)B"
        if data.count >= 2 {
            let family = data[1]
            if family == UInt8(AF_INET), data.count >= MemoryLayout<sockaddr_in>.size {
                data.withUnsafeBytes { raw in
                    var sa = raw.load(as: sockaddr_in.self)
                    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    inet_ntop(AF_INET, &sa.sin_addr, &buf, socklen_t(buf.count))
                    out += " v4 \(String(cString: buf)):\(UInt16(bigEndian: sa.sin_port))"
                }
            } else if family == UInt8(AF_INET6), data.count >= MemoryLayout<sockaddr_in6>.size {
                data.withUnsafeBytes { raw in
                    var sa = raw.load(as: sockaddr_in6.self)
                    var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    inet_ntop(AF_INET6, &sa.sin6_addr, &buf, socklen_t(buf.count))
                    out += " v6 [\(String(cString: buf))]:\(UInt16(bigEndian: sa.sin6_port))"
                }
            } else {
                out += " family=\(family)"
            }
        }
        return out + ">"
    }
    return "\(value)"
}

let queue = DispatchQueue(label: "probe.nstat")
var sourceCount = 0

guard let manager = NStatManagerCreate(kCFAllocatorDefault, queue, { source in
    guard let source else { return }
    sourceCount += 1
    let index = sourceCount
    NStatSourceSetDescriptionBlock(source) { description in
        guard let dict = description as? [String: Any] else {
            print("[\(index)] description not a dict")
            return
        }
        let pairs = dict.keys.sorted().map { "\($0)=\(describeValue(dict[$0]!))" }
        print("[\(index)] \(pairs.joined(separator: " | "))")
    }
    NStatSourceSetRemovedBlock(source) {
        print("[\(index)] REMOVED")
    }
    NStatSourceQueryDescription(source)
}) else {
    fatalError("NStatManagerCreate returned nil")
}

let tcpResult = NStatManagerAddAllTCP(manager)
let udpResult = NStatManagerAddAllUDP(manager)
print("AddAllTCP=\(tcpResult) AddAllUDP=\(udpResult)")

// Run briefly; new flows created while running should appear as new sources.
// Re-query all descriptions a few times so fields that populate with traffic
// (remote address, rtt, byte counts) show real values.
typealias QueryAllFn = @convention(c) (UnsafeMutableRawPointer?, @escaping RemovedCallback) -> Void
let NStatManagerQueryAllSourcesDescriptions = unsafeBitCast(sym("NStatManagerQueryAllSourcesDescriptions"), to: QueryAllFn.self)
for _ in 0..<3 {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 2))
    NStatManagerQueryAllSourcesDescriptions(manager) {}
}
RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
print("done, total sources seen: \(sourceCount)")
