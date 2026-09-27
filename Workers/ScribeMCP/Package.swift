// swift-tools-version: 6.1
import PackageDescription

// The local MCP server Scribe.app ships at Contents/Helpers/scribe-mcp, and the
// launcher plugin manifests run to find it. Built by Scripts/build-app.sh and
// Scripts/package-app.sh with `swift build`, like the transcription helper, so
// the app's Xcode project never resolves the MCP SDK.
let package = Package(
    name: "ScribeMCP",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ScribeMCPCore", targets: ["ScribeMCPCore"]),
        .executable(name: "scribe-mcp", targets: ["ScribeMCP"]),
        .executable(name: "scribe-mcp-launcher", targets: ["ScribeMCPLauncher"]),
        .executable(name: "scribe-relay-test-client", targets: ["ScribeRelayTestClient"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(path: "../../Modules/Transcription"),
    ],
    targets: [
        .target(
            name: "ScribeMCPCore",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Transcription", package: "Transcription"),
            ],
            // Embedded rather than bundled: the helper is a single file inside
            // Scribe.app. transcripts.html and icon.png link to the copies in
            // Integrations/scribe, so there is one of each.
            resources: [
                .embedInCode("Resources/tools.json"),
                .embedInCode("Resources/transcripts.html"),
                .embedInCode("Resources/icon.png"),
            ]
        ),
        .executableTarget(name: "ScribeMCP", dependencies: ["ScribeMCPCore"]),
        // No dependencies: it only finds Scribe.app and execs the helper.
        .executableTarget(name: "ScribeMCPLauncher"),
        .executableTarget(name: "ScribeRelayTestClient", dependencies: ["ScribeMCPCore"]),
        .testTarget(
            name: "ScribeMCPCoreTests",
            dependencies: [
                "ScribeMCPCore",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Transcription", package: "Transcription"),
            ]
        ),
    ]
)
