// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "ScribeDesign", platforms: [.macOS(.v15)],
    products: [.library(name: "ScribeDesign", targets: ["ScribeDesign"])],
    targets: [.target(name: "ScribeDesign")])
