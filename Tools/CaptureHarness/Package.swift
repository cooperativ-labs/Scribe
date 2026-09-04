// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CaptureHarness",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "capture-harness", targets: ["CaptureHarness"])
    ],
    targets: [
        .executableTarget(name: "CaptureHarness"),
        .testTarget(name: "CaptureHarnessTests", dependencies: ["CaptureHarness"])
    ]
)
