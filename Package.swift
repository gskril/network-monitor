// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NetworkMonitor",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CDNSSniff"),
        .executableTarget(
            name: "NetworkMonitor",
            dependencies: ["CDNSSniff"],
            path: "Sources/NetworkMonitor",
            linkerSettings: [.linkedLibrary("pcap")]
        ),
        .testTarget(
            name: "NetworkMonitorTests",
            dependencies: ["NetworkMonitor"]
        )
    ]
)
