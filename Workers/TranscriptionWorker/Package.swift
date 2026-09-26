// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TranscriptionWorker",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TranscriptionWorkerSupport", targets: ["TranscriptionWorkerSupport"]),
        .executable(name: "TranscriptionWorker", targets: ["TranscriptionWorker"]),
        .executable(name: "ASRBenchmark", targets: ["ASRBenchmark"]),
        .executable(name: "DiarizationBenchmark", targets: ["DiarizationBenchmark"]),
        .executable(name: "ShortTurnBenchmark", targets: ["ShortTurnBenchmark"]),
        .executable(name: "SpeakerEnrollmentCalibration", targets: ["SpeakerEnrollmentCalibration"]),
    ],
    dependencies: [
        // Keep the release exact: ASR token timing, long-file merge behavior,
        // and offline diarization are part of the worker protocol contract.
        // v0.17.4 retains the VBx backend; Nemotron is not enabled by this pin.
        // Models remain staged locally; runtime downloads stay disabled.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.4"),
        .package(path: "../../Modules/Speakers"),
    ],
    targets: [
        .target(
            name: "TranscriptionWorkerSupport",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            resources: [.copy("Resources/silero-vad-unified-256ms-v6.2.1.mlmodelc")]
        ),
        .executableTarget(name: "TranscriptionWorker", dependencies: ["TranscriptionWorkerSupport"]),
        .executableTarget(name: "ASRBenchmark", dependencies: ["TranscriptionWorkerSupport"]),
        .executableTarget(name: "DiarizationBenchmark", dependencies: ["TranscriptionWorkerSupport"]),
        .executableTarget(name: "ShortTurnBenchmark", dependencies: ["TranscriptionWorkerSupport"]),
        .executableTarget(
            name: "SpeakerEnrollmentCalibration",
            dependencies: [
                "TranscriptionWorkerSupport",
                .product(name: "Speakers", package: "Speakers"),
            ]
        ),
        .testTarget(
            name: "TranscriptionWorkerSupportTests",
            dependencies: [
                "TranscriptionWorkerSupport",
                "TranscriptionWorker",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
    ]
)
