// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Capture",
    platforms: [.macOS(.v15)],
    products: [.library(name: "Capture", targets: ["Capture"])],
    dependencies: [
        .package(path: "../App"),
        .package(path: "../Platform"),
        .package(path: "../Storage")
    ],
    targets: [
        .target(
            name: "Capture",
            dependencies: [
                .product(name: "ScribeAppCore", package: "app"),
                .product(name: "Platform", package: "platform"),
                .product(name: "Storage", package: "storage")
            ]
        ),
        .testTarget(
            name: "CaptureTests",
            dependencies: [
                "Capture",
                .product(name: "ScribeAppCore", package: "app"),
                .product(name: "Platform", package: "platform"),
                .product(name: "Storage", package: "storage")
            ]
        )
    ]
)
