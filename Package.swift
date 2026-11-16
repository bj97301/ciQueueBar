// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CIQueueBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "CIQueueBar", path: "Sources/CIQueueBar")
    ]
)
