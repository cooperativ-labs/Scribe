// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Speakers",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Speakers", targets: ["Speakers"]),
    ],
    targets: [
        .target(name: "Speakers"),
        .testTarget(
            name: "SpeakersTests",
            dependencies: ["Speakers"]
        ),
    ]
)
