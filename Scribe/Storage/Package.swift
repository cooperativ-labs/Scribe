// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Storage",
    platforms: [.macOS(.v15)],
    products: [.library(name: "Storage", targets: ["Storage"])],
    dependencies: [.package(path: "../App")],
    targets: [
        .target(name: "Storage", dependencies: [.product(name: "ScribeAppCore", package: "app")]),
        .testTarget(name: "StorageTests", dependencies: ["Storage", .product(name: "ScribeAppCore", package: "app")])
    ]
)
