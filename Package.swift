// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NetworkMonitor",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NetworkMonitor",
            path: "Sources/NetworkMonitor"
        )
    ]
)
