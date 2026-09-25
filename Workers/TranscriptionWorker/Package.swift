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
        // Deliberately exact rather than `from:`: token timing and diarization
        // behaviour are part of the worker protocol's compatibility surface.
        //
        // Keep the release exact: ASR token timing, long-file merge behavior,
        // and offline diarization are part of the worker protocol's
        // compatibility surface. v0.15.7 fixes speaker ceilings and structured
        // cancellation while preserving the v0.15.6 embedding representation.
        // Models remain staged locally; runtime downloads stay disabled.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.7"),
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
