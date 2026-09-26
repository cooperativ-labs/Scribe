// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "ScribeDesign", platforms: [.macOS(.v15), .iOS("26.0")],
    products: [.library(name: "ScribeDesign", targets: ["ScribeDesign"])],
    targets: [.target(name: "ScribeDesign")])
