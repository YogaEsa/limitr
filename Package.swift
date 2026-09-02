// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Limitr",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LimitrCore", targets: ["LimitrCore"]),
        .executable(name: "limitr", targets: ["LimitrCLI"]),
        .executable(name: "LimitrApp", targets: ["LimitrApp"])
    ],
    targets: [
        .target(name: "LimitrCore"),
        .executableTarget(name: "LimitrCLI", dependencies: ["LimitrCore"]),
        .executableTarget(name: "LimitrApp", dependencies: ["LimitrCore"]),
        .testTarget(name: "LimitrCoreTests", dependencies: ["LimitrCore"])
    ]
)
