// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Platform",
    platforms: [.macOS(.v15)],
    products: [.library(name: "Platform", targets: ["Platform"])],
    targets: [
        .target(name: "Platform"),
        .testTarget(name: "PlatformTests", dependencies: ["Platform"])
    ]
)
