// swift-tools-version: 6.0
import PackageDescription

// The voice assistant's model call: the provider protocol, the prompt, the
// streaming clients (OpenAI Responses, Chat Completions, Anthropic Messages),
// the Keychain, and the accounts (a ChatGPT sign-in, an API key with one of
// several providers, and Apple's on-device model). Foundation, Security and,
// where the SDK has it, FoundationModels only, so it can be tested without
// the app and knows nothing about triggers or insertion.
let package = Package(
    name: "Assist",
    platforms: [.macOS(.v15)],
    products: [.library(name: "Assist", targets: ["Assist"])],
    targets: [
        .target(name: "Assist"),
        .testTarget(name: "AssistTests", dependencies: ["Assist"], resources: [.copy("Fixtures")]),
    ]
)
