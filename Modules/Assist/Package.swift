// swift-tools-version: 6.0
import PackageDescription

// The voice assistant's model call: the provider protocol, the prompt, one
// streaming Responses client, the Keychain, and the two accounts (a ChatGPT
// sign-in and an OpenAI API key). Foundation and Security only, so it can be
// tested without the app and knows nothing about triggers or insertion.
let package = Package(
    name: "Assist",
    platforms: [.macOS(.v15)],
    products: [.library(name: "Assist", targets: ["Assist"])],
    targets: [
        .target(name: "Assist"),
        .testTarget(name: "AssistTests", dependencies: ["Assist"], resources: [.copy("Fixtures")]),
    ]
)
