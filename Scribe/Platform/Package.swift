// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Platform",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Platform", targets: ["Platform"]),
        .library(name: "PlatformTestSupport", targets: ["PlatformTestSupport"]),
    ],
    targets: [
        .target(name: "Platform"),
        .target(name: "PlatformTestSupport", dependencies: ["Platform"], path: "Tests/Support"),
        .testTarget(name: "PlatformTests", dependencies: ["Platform", "PlatformTestSupport"])
    ]
)
