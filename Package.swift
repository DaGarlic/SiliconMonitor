// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SiliconMonitor",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CSMC", linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(name: "SiliconMonitor", dependencies: ["CSMC"]),
        .testTarget(name: "SiliconMonitorTests", dependencies: ["SiliconMonitor"]),
    ]
)
