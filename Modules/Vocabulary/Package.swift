// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Vocabulary",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Vocabulary", targets: ["Vocabulary"]),
    ],
    targets: [
        .target(name: "Vocabulary"),
        .testTarget(
            name: "VocabularyTests",
            dependencies: ["Vocabulary"]
        ),
    ]
)
