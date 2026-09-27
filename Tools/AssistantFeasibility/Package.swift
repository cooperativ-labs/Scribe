// swift-tools-version: 6.0
import PackageDescription

// Throwaway feasibility and QA harness for docs/proposals/assistant.md section 12.
// Not part of the Xcode project. Results are written up in
// docs/feasibility/chatgpt-signin.md, docs/feasibility/assistant-window-text.md
// and docs/feasibility/assistant-qa-matrix.md.
let package = Package(
    name: "AssistantFeasibility",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "chatgpt-signin", targets: ["ChatGPTSignIn"]),
        .executable(name: "window-text-probe", targets: ["WindowTextProbe"]),
        .executable(name: "assistant-qa", targets: ["AssistantQA"]),
    ],
    dependencies: [
        .package(path: "../../Modules/Dictation"),
        .package(path: "../../Modules/Assist"),
    ],
    targets: [
        .executableTarget(name: "ChatGPTSignIn"),
        .executableTarget(name: "WindowTextProbe"),
        .executableTarget(
            name: "AssistantQA",
            dependencies: [
                .product(name: "Dictation", package: "Dictation"),
                .product(name: "Assist", package: "Assist"),
            ]
        ),
    ]
)
