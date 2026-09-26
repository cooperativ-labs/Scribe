// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "ScribeMobile", platforms: [.iOS("26.0"), .macOS(.v15)],
    products: [.library(name: "ScribeMobile", targets: ["ScribeMobile"])],
    dependencies: [.package(path: "../../Workers/TranscriptionWorker")],
    targets: [
        .target(name: "ScribeMobile", dependencies: [.product(name: "ScribeInference", package: "TranscriptionWorker")]),
        .testTarget(name: "ScribeMobileTests", dependencies: ["ScribeMobile"])
    ])
