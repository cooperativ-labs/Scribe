// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FLACBridge",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FLACBridge", targets: ["FLACBridge"]),
        .executable(name: "FLACProbe", targets: ["FLACProbe"]),
    ],
    targets: [
        .target(name: "FLACBridge"),
        .executableTarget(name: "FLACProbe"),
        .testTarget(name: "FLACBridgeTests", dependencies: ["FLACBridge"]),
    ]
)
