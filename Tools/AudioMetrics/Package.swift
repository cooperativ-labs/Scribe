// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioMetrics",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AudioMetricsCore", targets: ["AudioMetricsCore"]),
        .executable(name: "audio-metrics", targets: ["AudioMetrics"]),
    ],
    targets: [
        .target(name: "AudioMetricsCore"),
        .executableTarget(name: "AudioMetrics", dependencies: ["AudioMetricsCore"]),
        .testTarget(name: "AudioMetricsCoreTests", dependencies: ["AudioMetricsCore"]),
    ]
)
