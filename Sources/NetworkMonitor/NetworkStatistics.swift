// Bindings for the private NetworkStatistics.framework (the same API that
// powers nettop and Activity Monitor's network view). Loaded via dlopen so
// there is no link-time dependency on a private framework.
//
// Verified against macOS 26.3: NStatManagerCreate delivers one callback per
// flow ("source"), each source answers description queries with a dictionary
// containing processName/processID/provider/addresses/byte counts.

import Darwin
import Foundation

enum NStat {
    typealias SourceCallback = @convention(block) (UnsafeMutableRawPointer?) -> Void
    typealias DescriptionCallback = @convention(block) (CFDictionary?) -> Void
    typealias VoidCallback = @convention(block) () -> Void

    private typealias ManagerCreateFn = @convention(c) (CFAllocator?, DispatchQueue, @escaping SourceCallback) -> UnsafeMutableRawPointer?
    private typealias ManagerArgFn = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    private typealias ManagerDestroyFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias ManagerQueryAllFn = @convention(c) (UnsafeMutableRawPointer?, @escaping VoidCallback) -> Void
    private typealias SourceSetDescriptionFn = @convention(c) (UnsafeMutableRawPointer?, @escaping DescriptionCallback) -> Void
    private typealias SourceSetRemovedFn = @convention(c) (UnsafeMutableRawPointer?, @escaping VoidCallback) -> Void
    private typealias SourceQueryFn = @convention(c) (UnsafeMutableRawPointer?) -> Void

    private static let handle: UnsafeMutableRawPointer = {
        let path = "/System/Library/PrivateFrameworks/NetworkStatistics.framework/NetworkStatistics"
        guard let handle = dlopen(path, RTLD_NOW) else {
            fatalError("Failed to load NetworkStatistics.framework: \(String(cString: dlerror()))")
        }
        return handle
    }()

    private static func symbol<T>(_ name: String, as type: T.Type) -> T {
        guard let pointer = dlsym(handle, name) else {
            fatalError("NetworkStatistics.framework is missing symbol \(name)")
        }
        return unsafeBitCast(pointer, to: type)
    }

    private static let managerCreate = symbol("NStatManagerCreate", as: ManagerCreateFn.self)
    private static let managerAddAllTCP = symbol("NStatManagerAddAllTCP", as: ManagerArgFn.self)
    private static let managerAddAllUDP = symbol("NStatManagerAddAllUDP", as: ManagerArgFn.self)
    private static let managerDestroy = symbol("NStatManagerDestroy", as: ManagerDestroyFn.self)
    private static let managerQueryAllDescriptions = symbol("NStatManagerQueryAllSourcesDescriptions", as: ManagerQueryAllFn.self)
    private static let sourceSetDescriptionBlock = symbol("NStatSourceSetDescriptionBlock", as: SourceSetDescriptionFn.self)
    private static let sourceSetRemovedBlock = symbol("NStatSourceSetRemovedBlock", as: SourceSetRemovedFn.self)
    private static let sourceQueryDescription = symbol("NStatSourceQueryDescription", as: SourceQueryFn.self)

    static func createManager(queue: DispatchQueue, onSource: @escaping SourceCallback) -> UnsafeMutableRawPointer? {
        managerCreate(kCFAllocatorDefault, queue, onSource)
    }

    static func addAllTCP(_ manager: UnsafeMutableRawPointer) -> Bool { managerAddAllTCP(manager) != 0 }
    static func addAllUDP(_ manager: UnsafeMutableRawPointer) -> Bool { managerAddAllUDP(manager) != 0 }
    static func destroy(_ manager: UnsafeMutableRawPointer) { managerDestroy(manager) }

    static func queryAllDescriptions(_ manager: UnsafeMutableRawPointer, completion: @escaping VoidCallback = {}) {
        managerQueryAllDescriptions(manager, completion)
    }

    static func setDescriptionBlock(_ source: UnsafeMutableRawPointer, _ block: @escaping DescriptionCallback) {
        sourceSetDescriptionBlock(source, block)
    }

    static func setRemovedBlock(_ source: UnsafeMutableRawPointer, _ block: @escaping VoidCallback) {
        sourceSetRemovedBlock(source, block)
    }

    static func queryDescription(_ source: UnsafeMutableRawPointer) {
        sourceQueryDescription(source)
    }
}
