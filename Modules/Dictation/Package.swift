// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Dictation",
    platforms: [.macOS(.v15)],
    products: [.library(name: "Dictation", targets: ["Dictation"])],
    dependencies: [.package(path: "../Transcription"), .package(path: "../../Scribe/Platform"), .package(path: "../Assist")],
    targets: [
        .target(name: "Dictation", dependencies: [.product(name: "Transcription", package: "Transcription"), .product(name: "Platform", package: "Platform"), .product(name: "Assist", package: "Assist")]),
        .testTarget(name: "DictationTests", dependencies: ["Dictation"]),
    ]
)
