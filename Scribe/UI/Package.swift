// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScribeUI",
    platforms: [.macOS(.v15)],
    products: [.library(name: "ScribeUI", targets: ["ScribeUI"])],
    dependencies: [
        .package(path: "../Platform"),
        // The vocabulary is an independent module with its own store and
        // editor, the way the speaker library is; Settings only hosts it.
        .package(path: "../../Modules/Vocabulary"),
        .package(path: "../../Modules/Dictation"),
        .package(path: "../../Modules/Assist"),
        .package(path: "../../Workers/ScribeMCP"),
    ],
    targets: [
        .target(
            name: "ScribeUI",
            dependencies: ["Platform", .product(name: "ScribeMCPCore", package: "ScribeMCP"), .product(name: "Vocabulary", package: "Vocabulary"), .product(name: "Dictation", package: "Dictation"), .product(name: "Assist", package: "Assist")]
        ),
        .testTarget(name: "ScribeUITests", dependencies: [
            "ScribeUI", "Platform",
            .product(name: "Assist", package: "Assist"),
            .product(name: "PlatformTestSupport", package: "Platform"),
        ])
    ]
)
