// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScribeAudioFixtures",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "generate-audio-fixtures", targets: ["FixtureGenerator"]),
    ],
    targets: [
        .executableTarget(name: "FixtureGenerator"),
    ]
)
