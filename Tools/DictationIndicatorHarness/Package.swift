// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DictationIndicatorHarness",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../Scribe/UI"),
        .package(path: "../../Modules/Dictation"),
    ],
    targets: [
        .executableTarget(name: "DictationIndicatorHarness", dependencies: [
            .product(name: "ScribeUI", package: "UI"),
            .product(name: "Dictation", package: "Dictation"),
        ]),
    ]
)
