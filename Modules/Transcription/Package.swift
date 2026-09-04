// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Transcription",
    platforms: [.macOS(.v15)],
    products: [.library(name: "Transcription", targets: ["Transcription"])],
    dependencies: [
        // The speaker library is an independent service contract; review shares its
        // person IDs rather than defining a second identity type.
        .package(path: "../Speakers"),
        // The recorder-session manifest and producer handoff types are host
        // integration-layer contracts (plan section 12); the importer consumes
        // them rather than keeping a second copy that can drift.
        .package(path: "../../Scribe/App"),
    ],
    targets: [
        .target(
            name: "Transcription",
            dependencies: [
                .product(name: "Speakers", package: "Speakers"),
                .product(name: "ScribeAppCore", package: "app"),
            ],
            resources: [.process("Transcript/CanonicalTranscript.schema.json")]
        ),
        .testTarget(
            name: "TranscriptionTests",
            dependencies: [
                "Transcription",
                .product(name: "Speakers", package: "Speakers"),
                .product(name: "ScribeAppCore", package: "app"),
            ],
            path: "Tests",
            resources: [.process("Fixtures")]
        ),
    ]
)
