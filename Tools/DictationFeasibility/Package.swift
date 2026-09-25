// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DictationFeasibility",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../Workers/TranscriptionWorker"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.7"),
    ],
    targets: [
        .executableTarget(name: "DictationLatencyProbe", dependencies: [
            .product(name: "TranscriptionWorkerSupport", package: "TranscriptionWorker"),
            .product(name: "FluidAudio", package: "FluidAudio"),
        ]),
    ]
)
