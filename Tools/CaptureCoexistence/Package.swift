// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CaptureCoexistence",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "capture-coexistence", targets: ["CaptureCoexistence"])],
    dependencies: [
        .package(path: "../../Scribe/App"),
        .package(path: "../../Scribe/Processing"),
        .package(path: "../../Scribe/Storage"),
        .package(path: "../../Modules/Transcription")
    ],
    targets: [
        // The measuring instruments, in a library so the publication path they
        // share with the recorder can be tested without a two-hour run.
        .target(
            name: "CaptureCoexistenceCore",
            dependencies: [
                .product(name: "ScribeAppCore", package: "app"),
                .product(name: "Storage", package: "storage"),
                .product(name: "Transcription", package: "transcription")
            ]
        ),
        .executableTarget(
            name: "CaptureCoexistence",
            dependencies: [
                "CaptureCoexistenceCore",
                .product(name: "Processing", package: "processing"),
                .product(name: "ScribeAppCore", package: "app"),
                .product(name: "Storage", package: "storage"),
                .product(name: "Transcription", package: "transcription")
            ]
        ),
        .testTarget(
            name: "CaptureCoexistenceCoreTests",
            dependencies: [
                "CaptureCoexistenceCore",
                .product(name: "Processing", package: "processing"),
                .product(name: "ScribeAppCore", package: "app"),
                .product(name: "Storage", package: "storage"),
                .product(name: "Transcription", package: "transcription")
            ]
        )
    ]
)
