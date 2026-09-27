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

    func testRedirectsAlwaysAllowStableCallbacksAndOnlyAValidCustomOne() {
        let stable = [AssistantConnectorCommands.claudeCallback, AssistantConnectorCommands.chatGPTCallback]
        XCTAssertEqual(AssistantConnectorCommands.redirectURIs(chatGPTCallback: ""), stable)
        XCTAssertEqual(AssistantConnectorCommands.redirectURIs(chatGPTCallback: "not a url"), stable)
        XCTAssertEqual(AssistantConnectorCommands.redirectURIs(chatGPTCallback: AssistantConnectorCommands.chatGPTCallback), stable)
        XCTAssertEqual(
            AssistantConnectorCommands.redirectURIs(chatGPTCallback: " https://chatgpt.com/cb "),
            stable + ["https://chatgpt.com/cb"]
        )
    }

    func testRelayCommandLinksAndConnectsWithoutATunnel() throws {
        let relay = try AssistantServerAddress.parse("relay.example.com/mcp").get()
        let command = AssistantConnectorCommands.relayConnectCommand(
            cli: URL(filePath: "/Users/o'neil/Library/Application Support/Scribe/cli.mjs"),
            relay: relay
        )
        XCTAssertTrue(command.contains("SCRIBE_CLI='/Users/o'\\''neil/Library/Application Support/Scribe/cli.mjs'"))
        XCTAssertTrue(command.hasSuffix("node \"$SCRIBE_CLI\" connect 'https://relay.example.com'"))
        XCTAssertFalse(command.contains("owner-key"))
        XCTAssertFalse(command.contains(" http"))
    }

    func testRelayStepsUseLinkCodesAndSelfHostedStepsUseTheOwnerKey() {
        for client in [AssistantClient.chatGPT, .claude] {
            XCTAssertTrue(client.steps(mode: .relay).contains { $0.contains("link code") }, client.name)
            XCTAssertFalse(client.steps(mode: .relay).contains { $0.contains("tunnel") || $0.contains("owner key") }, client.name)
            XCTAssertTrue(client.steps(mode: .selfHosted).contains { $0.contains("owner key") }, client.name)
        }
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
        XCTAssertTrue(command.contains("SCRIBE_OAUTH_REDIRECT_URIS='[\"https://claude.ai/api/mcp/auth_callback\",\"https://chatgpt.com/connector_platform_oauth_redirect\"]'"))
        XCTAssertTrue(command.hasSuffix("node \"$SCRIBE_CLI\" http"))
    }

    func testEveryClientHasInstructionsAndWebClientsHaveASetupPage() {
        for client in AssistantClient.allCases {
            XCTAssertFalse(client.steps().isEmpty, client.name)
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

    /// A fake app bundle whose connector is the given Node script.
    private func bundle(cli: String, connector: String? = nil, in root: URL) throws -> AssistantConnectorPackage {
        let marketplace = root.appending(path: "Fake.bundle/Contents/Resources/AssistantConnector/claude")
        try FileManager.default.createDirectory(at: marketplace.appending(path: ".claude-plugin"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: marketplace.appending(path: ".claude-plugin/marketplace.json"))
        try FileManager.default.createDirectory(at: marketplace.appending(path: "plugins/scribe/dist"), withIntermediateDirectories: true)
        try Data(cli.utf8).write(to: marketplace.appending(path: "plugins/scribe/dist/cli.mjs"))
        if let connector {
            try Data(connector.utf8).write(to: marketplace.appending(path: "plugins/scribe/connector.json"))
        }
        let bundle = try XCTUnwrap(Bundle(url: root.appending(path: "Fake.bundle")))
        return AssistantConnectorPackage(bundle: bundle, stagedMarketplace: root.appending(path: "Support/claude"))
    }

    private func waitFor(_ agent: AssistantRelayAgent, timeout: Duration = .seconds(10), _ matches: (AssistantRelayAgent.State) -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !matches(agent.state) {
            guard ContinuousClock.now < deadline else { return XCTFail("state is \(agent.state)") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    func testPackagedRelayComesFromConnectorJSON() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "AssistantConnectionTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try bundle(cli: "", connector: #"{"connector_url":"https://relay.example/mcp"}"#, in: root)
        XCTAssertEqual(package.packagedRelay?.origin, "https://relay.example")
        let plain = try bundle(cli: "", in: root.appending(path: "plain"))
        XCTAssertNil(plain.packagedRelay)
    }

    func testRelayAgentRunsTheConnectorAndRemembersTheChoice() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "AssistantConnectionTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let arguments = root.appending(path: "arguments.txt")
        // Stays connected until Scribe's pipe closes, like `connect`.
        let package = try bundle(cli: """
        import { writeFileSync } from 'node:fs';
        writeFileSync(\(String(reflecting: arguments.path)), process.argv.slice(2).join(' ') + ' ' + process.env.SCRIBE_EXIT_WITH_PARENT);
        process.stdin.on('end', () => process.exit(0)); process.stdin.resume();
        """, in: root)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AssistantRelayAgentTests-\(UUID().uuidString)"))
        let agent = AssistantRelayAgent(defaults: defaults)
        agent.start(package: package, relay: try AssistantServerAddress.parse("relay.example").get())
        XCTAssertTrue(agent.isEnabled)
        try await waitFor(agent) { $0 == .connected }
        XCTAssertEqual(try String(contentsOf: arguments, encoding: .utf8), "connect https://relay.example 1")
        agent.stop()
        XCTAssertEqual(agent.state, .stopped)
        XCTAssertFalse(agent.isEnabled)
    }

    func testRelayAgentStopsRetryingOnceTheRelayForgotThisMac() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "AssistantConnectionTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try bundle(cli: """
        console.error('Scribe MCP: The relay no longer recognizes this Mac. It was unlinked; link it again from Scribe.'); process.exit(1);
        """, in: root)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AssistantRelayAgentTests-\(UUID().uuidString)"))
        let agent = AssistantRelayAgent(defaults: defaults)
        agent.start(package: package, relay: try AssistantServerAddress.parse("relay.example").get())
        try await waitFor(agent) { if case .failed = $0 { true } else { false } }
        XCTAssertEqual(agent.state, .failed("The relay no longer recognizes this Mac. It was unlinked; link it again from Scribe."))
        XCTAssertFalse(agent.isEnabled, "an unlinked Mac is not reconnected at launch")
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
