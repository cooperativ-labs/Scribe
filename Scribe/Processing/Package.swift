// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Processing",
    platforms: [.macOS(.v15)],
    products: [.library(name: "Processing", targets: ["Processing"])],
    dependencies: [
        .package(path: "../App"),
        .package(path: "../../Native/FLACBridge"),
        .package(path: "../../Native/WebRTCBridge"),
        .package(path: "../../Tools/AudioMetrics"),
    ],
    targets: [
        .target(
            name: "Processing",
            dependencies: [
                .product(name: "ScribeAppCore", package: "app"),
                .product(name: "FLACBridge", package: "FLACBridge"),
                .product(name: "WebRTCBridge", package: "WebRTCBridge"),
            ]
        ),
        .testTarget(
            name: "ProcessingTests",
            dependencies: [
                "Processing",
                .product(name: "AudioMetricsCore", package: "AudioMetrics"),
                .product(name: "ScribeAppCore", package: "app"),
                .product(name: "FLACBridge", package: "FLACBridge"),
                .product(name: "WebRTCBridge", package: "WebRTCBridge"),
            ]
        ),
    ]
)
