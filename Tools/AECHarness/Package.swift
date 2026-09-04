// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AECHarness",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AECHarnessCore", targets: ["AECHarnessCore"]),
        .executable(name: "aec-harness", targets: ["AECHarness"]),
    ],
    dependencies: [
        .package(path: "../../Native/WebRTCBridge"),
    ],
    targets: [
        .target(
            name: "AECHarnessCore",
            dependencies: [.product(name: "WebRTCBridge", package: "WebRTCBridge")]
        ),
        .executableTarget(name: "AECHarness", dependencies: ["AECHarnessCore"]),
        .testTarget(name: "AECHarnessCoreTests", dependencies: ["AECHarnessCore"]),
    ]
)
