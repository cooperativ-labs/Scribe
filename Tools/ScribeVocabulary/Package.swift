// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScribeVocabulary",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ScribeVocabularyCLI", targets: ["ScribeVocabularyCLI"]),
        .executable(name: "scribe-vocab", targets: ["ScribeVocabulary"]),
    ],
    dependencies: [
        .package(path: "../../Modules/Vocabulary"),
    ],
    targets: [
        .target(
            name: "ScribeVocabularyCLI",
            dependencies: [.product(name: "Vocabulary", package: "Vocabulary")]
        ),
        .executableTarget(name: "ScribeVocabulary", dependencies: ["ScribeVocabularyCLI"]),
        .testTarget(name: "ScribeVocabularyCLITests", dependencies: ["ScribeVocabularyCLI"]),
    ]
)
