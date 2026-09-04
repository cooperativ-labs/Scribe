// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScribeAppCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "ScribeAppCore", targets: ["ScribeAppCore"])],
    targets: [
        .target(
            name: "ScribeAppCore",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "ScribeAppCoreTests",
            dependencies: ["ScribeAppCore"],
            resources: [.process("Fixtures")]
        )
    ]
)
