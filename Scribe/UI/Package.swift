// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScribeUI",
    platforms: [.macOS(.v15)],
    products: [.library(name: "ScribeUI", targets: ["ScribeUI"])],
    dependencies: [.package(path: "../Platform")],
    targets: [
        .target(name: "ScribeUI", dependencies: ["Platform"]),
        .testTarget(name: "ScribeUITests", dependencies: ["ScribeUI", "Platform"])
    ]
)
