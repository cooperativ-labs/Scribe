// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Speakers",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Speakers", targets: ["Speakers"]),
    ],
    dependencies: [.package(path: "../../Scribe/Platform")],
    targets: [
        .target(name: "Speakers", dependencies: [.product(name: "Platform", package: "Platform")]),
        .testTarget(
            name: "SpeakersTests",
            dependencies: ["Speakers"]
        ),
    ]
)
