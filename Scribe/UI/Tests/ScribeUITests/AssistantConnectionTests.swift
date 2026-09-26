import XCTest
@testable import ScribeUI

@MainActor
final class AssistantConnectionTests: XCTestCase {
    func testAddressAcceptsHostOriginOrEndpoint() throws {
        for text in ["scribe.example.com", "https://Scribe.Example.com/", " https://scribe.example.com/mcp "] {
            let address = try AssistantServerAddress.parse(text).get()
            XCTAssertEqual(address.origin, "https://scribe.example.com", text)
            XCTAssertEqual(address.endpoint, "https://scribe.example.com/mcp", text)
        }
        XCTAssertEqual(try AssistantServerAddress.parse("https://host.test:8443").get().endpoint, "https://host.test:8443/mcp")
    }

    func testAddressRejectsWhatRemoteClientsCannotUse() {
        XCTAssertEqual(AssistantServerAddress.parse("  ").failure, .empty)
        XCTAssertEqual(AssistantServerAddress.parse("http://scribe.example.com").failure, .notHTTPS)
        XCTAssertEqual(AssistantServerAddress.parse("https://scribe.example.com/other").failure, .invalid)
        XCTAssertEqual(AssistantServerAddress.parse("https://user:pw@scribe.example.com").failure, .invalid)
        XCTAssertEqual(AssistantServerAddress.parse("https://scribe.example.com/mcp?x=1").failure, .invalid)
    }

    func testRedirectsAlwaysAllowClaudeAndOnlyAValidChatGPTCallback() {
        XCTAssertEqual(AssistantConnectorCommands.redirectURIs(chatGPTCallback: ""), [AssistantConnectorCommands.claudeCallback])
        XCTAssertEqual(AssistantConnectorCommands.redirectURIs(chatGPTCallback: "not a url"), [AssistantConnectorCommands.claudeCallback])
        XCTAssertEqual(
            AssistantConnectorCommands.redirectURIs(chatGPTCallback: " https://chatgpt.com/cb "),
            [AssistantConnectorCommands.claudeCallback, "https://chatgpt.com/cb"]
        )
    }

    func testServerCommandQuotesPathsAndConfiguresTheBridge() throws {
        let address = try AssistantServerAddress.parse("scribe.example.com").get()
        let command = AssistantConnectorCommands.serverCommand(
            cli: URL(filePath: "/Users/o'neil/Library/Application Support/Scribe/cli.mjs"),
            address: address,
            chatGPTCallback: ""
        )
        XCTAssertTrue(command.contains("SCRIBE_CLI='/Users/o'\\''neil/Library/Application Support/Scribe/cli.mjs'"))
        XCTAssertTrue(command.contains("node \"$SCRIBE_CLI\" init"))
        XCTAssertTrue(command.contains("SCRIBE_PUBLIC_URL='https://scribe.example.com'"))
        XCTAssertTrue(command.contains("SCRIBE_OAUTH_REDIRECT_URIS='[\"https://claude.ai/api/mcp/auth_callback\"]'"))
        XCTAssertTrue(command.hasSuffix("node \"$SCRIBE_CLI\" http"))
    }

    func testEveryClientHasInstructionsAndWebClientsHaveASetupPage() {
        for client in AssistantClient.allCases {
            XCTAssertFalse(client.steps.isEmpty, client.name)
        }
        XCTAssertEqual(AssistantClient.chatGPT.setupPage?.host, "chatgpt.com")
        XCTAssertEqual(AssistantClient.claude.setupPage?.host, "claude.ai")
        XCTAssertNil(AssistantClient.claudeCode.setupPage)
    }

    func testPackageStagesTheBundledMarketplaceAndReplacesAnOlderCopy() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "AssistantConnectionTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appending(path: "Fake.bundle")
        let marketplace = bundleURL.appending(path: "Contents/Resources/AssistantConnector/claude")
        try FileManager.default.createDirectory(at: marketplace.appending(path: ".claude-plugin"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: marketplace.appending(path: ".claude-plugin/marketplace.json"))
        try FileManager.default.createDirectory(at: marketplace.appending(path: "plugins/scribe/dist"), withIntermediateDirectories: true)
        try Data("new".utf8).write(to: marketplace.appending(path: "plugins/scribe/dist/cli.mjs"))
        let bundle = try XCTUnwrap(Bundle(url: bundleURL))

        let staged = root.appending(path: "Support/Integrations/claude")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: staged.appending(path: "stale.txt"))

        let package = AssistantConnectorPackage(bundle: bundle, stagedMarketplace: staged)
        XCTAssertTrue(package.isAvailable)
        try package.stage()

        XCTAssertEqual(try String(contentsOf: package.stagedCLI, encoding: .utf8), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.appending(path: "stale.txt").path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: staged.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["claude"])
    }

    func testPackageWithoutABundledMarketplaceIsUnavailable() {
        let package = AssistantConnectorPackage(
            bundle: Bundle(for: Self.self),
            stagedMarketplace: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        )
        XCTAssertFalse(package.isAvailable)
        XCTAssertThrowsError(try package.stage())
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let failure) = self { failure } else { nil }
    }
}
