// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Dictation",
    platforms: [.macOS(.v15)],
    products: [.library(name: "Dictation", targets: ["Dictation"])],
    dependencies: [.package(path: "../Transcription"), .package(path: "../../Scribe/Platform")],
    targets: [
        .target(name: "Dictation", dependencies: [.product(name: "Transcription", package: "Transcription"), .product(name: "Platform", package: "Platform")]),
        .testTarget(name: "DictationTests", dependencies: ["Dictation"]),
    ]
)
