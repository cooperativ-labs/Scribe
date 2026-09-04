// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScribeProcess",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ScribeProcessSupport", targets: ["ScribeProcessSupport"]),
        .executable(name: "scribe-process", targets: ["ScribeProcess"]),
    ],
    dependencies: [
        .package(path: "../../Scribe/Processing"),
    ],
    targets: [
        .target(
            name: "ScribeProcessSupport",
            dependencies: [.product(name: "Processing", package: "processing")]
        ),
        .executableTarget(name: "ScribeProcess", dependencies: ["ScribeProcessSupport"]),
    ]
)
