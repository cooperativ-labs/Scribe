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
    ],
    targets: [
        .target(
            name: "ScribeUI",
            dependencies: ["Platform", .product(name: "Vocabulary", package: "Vocabulary"), .product(name: "Dictation", package: "Dictation")]
        ),
        .testTarget(name: "ScribeUITests", dependencies: ["ScribeUI", "Platform"])
    ]
)
