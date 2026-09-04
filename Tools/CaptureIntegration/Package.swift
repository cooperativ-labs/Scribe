// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CaptureIntegration",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "capture-integration", targets: ["CaptureIntegration"])],
    dependencies: [
        .package(path: "../../Scribe/App"),
        .package(path: "../../Scribe/Capture"),
        .package(path: "../../Scribe/Platform"),
        .package(path: "../../Scribe/Processing"),
        .package(path: "../../Scribe/Storage")
    ],
    targets: [
        .executableTarget(
            name: "CaptureIntegration",
            dependencies: [
                .product(name: "Capture", package: "capture"),
                .product(name: "Platform", package: "platform"),
                .product(name: "Processing", package: "processing"),
                .product(name: "ScribeAppCore", package: "app"),
                .product(name: "Storage", package: "storage")
            ]
        )
    ]
)
