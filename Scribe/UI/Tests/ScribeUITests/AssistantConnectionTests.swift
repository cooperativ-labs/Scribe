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

    func testWebClientsUseLinkCodesAndHaveASetupPage() {
        for client in AssistantClient.allCases {
            XCTAssertTrue(client.steps.contains { $0.contains("link code") }, client.name)
            XCTAssertFalse(client.steps.contains { $0.contains("tunnel") || $0.contains("owner key") }, client.name)
        }
        XCTAssertEqual(AssistantClient.chatGPT.setupPage.host, "chatgpt.com")
        XCTAssertEqual(AssistantClient.claude.setupPage.host, "claude.ai")
    }

    func testPackagedRelayComesFromConnectorJSON() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "AssistantConnectionTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let marketplace = root.appending(path: "Fake.bundle/Contents/Resources/AssistantConnector/claude")
        try FileManager.default.createDirectory(at: marketplace.appending(path: ".claude-plugin"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: marketplace.appending(path: ".claude-plugin/marketplace.json"))
        try FileManager.default.createDirectory(at: marketplace.appending(path: "relay"), withIntermediateDirectories: true)
        try Data(#"{"connector_url":"https://relay.example/mcp"}"#.utf8).write(to: marketplace.appending(path: "relay/connector.json"))
        let bundle = try XCTUnwrap(Bundle(url: root.appending(path: "Fake.bundle")))
        let package = AssistantConnectorPackage(bundle: bundle)
        XCTAssertTrue(package.isAvailable)
        XCTAssertEqual(package.packagedRelay?.origin, "https://relay.example")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marketplace.appending(path: "relay/dist/cli.mjs").path))
    }

    func testPackageWithoutABundledMarketplaceIsUnavailable() {
        XCTAssertFalse(AssistantConnectorPackage(bundle: Bundle(for: Self.self)).isAvailable)
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let failure) = self { failure } else { nil }
    }
}
