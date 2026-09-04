// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TimelineHarness",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TimelineHarnessSupport", targets: ["TimelineHarnessSupport"]),
        .executable(name: "timeline-harness", targets: ["TimelineHarness"]),
    ],
    dependencies: [.package(path: "../../Scribe/Processing"), .package(path: "../../Scribe/App")],
    targets: [
        .target(name: "TimelineHarnessSupport", dependencies: [.product(name: "Processing", package: "processing"), .product(name: "ScribeAppCore", package: "app")]),
        .executableTarget(name: "TimelineHarness", dependencies: ["TimelineHarnessSupport", .product(name: "Processing", package: "processing")]),
    ]
)
