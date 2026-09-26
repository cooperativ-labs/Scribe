// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FLACBridge",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FLACBridge", targets: ["FLACBridge"]),
    ],
    targets: [
        .target(name: "FLACBridge"),
        .testTarget(name: "FLACBridgeTests", dependencies: ["FLACBridge"]),
    ]
)
