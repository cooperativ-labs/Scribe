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
        .executable(name: "SpeakerEnrollmentCalibration", targets: ["SpeakerEnrollmentCalibration"]),
    ],
    dependencies: [
        // Deliberately exact rather than `from:`: token timing and diarization
        // behaviour are part of the worker protocol's compatibility surface.
        //
        // Keep the release exact: ASR token timing, long-file merge behavior,
        // and offline diarization are part of the worker protocol's
        // compatibility surface. v0.15.6 retains the staged Parakeet v3 and
        // offline diarizer model filenames while adding upstream seam-gap,
        // final-window, and pyannote-parity clustering fixes. The worker uses
        // the explicit local-model APIs and does not enable runtime downloads.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.6"),
        .package(path: "../../Modules/Speakers"),
    ],
    targets: [
        .target(
            name: "TranscriptionWorkerSupport",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .executableTarget(name: "TranscriptionWorker", dependencies: ["TranscriptionWorkerSupport"]),
        .executableTarget(name: "ASRBenchmark", dependencies: ["TranscriptionWorkerSupport"]),
        .executableTarget(name: "DiarizationBenchmark", dependencies: ["TranscriptionWorkerSupport"]),
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
