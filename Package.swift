// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "odin-mac",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "OdinCore"),
        .executableTarget(name: "odin-mac", dependencies: ["OdinCore"]),
        .testTarget(name: "OdinCoreTests", dependencies: ["OdinCore"]),
    ]
)
