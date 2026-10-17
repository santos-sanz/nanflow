// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "nanflow",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "nanflow", targets: ["nanflow"]),
        .executable(name: "nanflow-cli", targets: ["nanflow-cli"]),
        .library(name: "NanflowCore", targets: ["NanflowCore"]),
    ],
    targets: [
        .target(name: "NanflowCore"),
        .executableTarget(name: "nanflow", dependencies: ["NanflowCore"]),
        .executableTarget(name: "nanflow-cli", dependencies: ["NanflowCore"]),
        .testTarget(name: "NanflowCoreTests", dependencies: ["NanflowCore"]),
    ]
)
