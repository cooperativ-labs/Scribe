import XCTest
@testable import ScribeUI

final class AssistantPluginInstallerTests: XCTestCase {
    private var root: URL!
    private var marketplace: URL!
    private var home: URL!
    private var support: URL!
    private var commands: CommandLog!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "AssistantPluginInstallerTests-\(UUID().uuidString)")
        marketplace = root.appending(path: "Scribe.app/Contents/Resources/AssistantConnector/claude")
        home = root.appending(path: "home")
        support = home.appending(path: "Library/Application Support")
        commands = CommandLog()
        try writeBundle(version: "0.1.0", skill: "Find meetings.")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    /// Records every command an installer runs and answers with `result`.
    final class CommandLog: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [(script: String, arguments: [String])] = []
        var result = AssistantPluginEnvironment.CommandResult(status: 0, output: "")

        func record(_ script: String, _ arguments: [String]) -> AssistantPluginEnvironment.CommandResult {
            lock.withLock {
                calls.append((script, arguments))
                return result
            }
        }

        var all: [(script: String, arguments: [String])] { lock.withLock { calls } }
    }

    private func writeBundle(version: String, skill: String, extraFile: Bool = false, obsoleteFile: Bool = true) throws {
        try? FileManager.default.removeItem(at: marketplace)
        let plugin = marketplace.appending(path: "plugins/scribe")
        try write(#"{"name":"scribe-local","plugins":[{"name":"scribe","source":"./plugins/scribe"}]}"#, to: marketplace.appending(path: ".claude-plugin/marketplace.json"))
        try write(#"{"name":"scribe","version":"\#(version)"}"#, to: plugin.appending(path: ".claude-plugin/plugin.json"))
        try write(#"{"name":"scribe","mcpServers":"./mcp.json"}"#, to: plugin.appending(path: ".codex-plugin/plugin.json"))
        try write(#"{"mcpServers":{"scribe":{"command":"${CLAUDE_PLUGIN_ROOT}/scribe-mcp-launcher"}}}"#, to: plugin.appending(path: ".mcp.json"))
        if obsoleteFile {
            try write(#"{"mcpServers":{"scribe":{"command":"./scribe-mcp-launcher","cwd":"./"}}}"#, to: plugin.appending(path: "mcp.json"))
        }
        if extraFile {
            try write("<html></html>", to: plugin.appending(path: "ui/transcripts.html"))
        }
        try write(skill, to: plugin.appending(path: "skills/scribe-transcripts/SKILL.md"))
        let launcher = plugin.appending(path: "scribe-mcp-launcher")
        try write("#!/bin/sh\nexit 0\n", to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        try write("// relay", to: marketplace.appending(path: "relay/dist/cli.mjs"))
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func installer(_ harness: AssistantHarness, apps: Set<String> = []) -> AssistantPluginInstaller {
        let commands = commands!
        return AssistantPluginInstaller(
            harness: harness,
            bundledMarketplace: marketplace,
            environment: AssistantPluginEnvironment(
                home: home,
                applicationSupport: support,
                isAppInstalled: { apps.contains($0) },
                run: { commands.record($0, $1) }
            )
        )
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func state(_ harness: AssistantHarness) throws -> [String: Any] {
        try json(support.appending(path: "Scribe/Integrations/state/\(harness.rawValue).json"))
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - ChatGPT and Codex

    func testChatGPTInstallUpsertsTheMarketplaceKeepingEveryOtherEntry() async throws {
        let marketplaceJSON = home.appending(path: ".agents/plugins/marketplace.json")
        try write("""
        {
          "name": "overlord-local",
          "interface": { "displayName": "Overlord Local Plugins" },
          "owner": { "name": "Someone" },
          "plugins": [
            { "name": "overlord", "source": { "source": "local", "path": "./.codex/plugins/overlord" }, "category": "Productivity" },
            { "name": "scribe", "source": { "source": "local", "path": "./old/scribe" } }
          ]
        }
        """, to: marketplaceJSON)

        let codex = installer(.chatGPT)
        XCTAssertEqual(codex.status(), .notInstalled)
        let report = try await codex.install()
        XCTAssertEqual(report.warnings, [])

        let destination = home.appending(path: ".codex/plugins/scribe")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: destination.appending(path: "scribe-mcp-launcher").path))
        XCTAssertTrue(exists(destination.appending(path: ".codex-plugin/plugin.json")))
        XCTAssertFalse(exists(destination.appending(path: "relay")))

        let object = try json(marketplaceJSON)
        XCTAssertEqual(object["name"] as? String, "overlord-local", "the marketplace keeps its own name")
        XCTAssertEqual((object["owner"] as? [String: Any])?["name"] as? String, "Someone")
        let plugins = try XCTUnwrap(object["plugins"] as? [[String: Any]])
        XCTAssertEqual(plugins.map { $0["name"] as? String }, ["overlord", "scribe"])
        XCTAssertEqual((plugins[0]["source"] as? [String: Any])?["path"] as? String, "./.codex/plugins/overlord")
        let scribe = plugins[1]
        XCTAssertEqual(scribe["source"] as? [String: String], ["source": "local", "path": "./.codex/plugins/scribe"])
        XCTAssertEqual(scribe["policy"] as? [String: String], ["installation": "AVAILABLE", "authentication": "ON_INSTALL"])
        XCTAssertEqual(scribe["category"] as? String, "Productivity")

        // Registered under the marketplace's name, which Codex keys plugins by.
        XCTAssertEqual(commands.all.last?.arguments, ["scribe@overlord-local"])
        XCTAssertTrue(commands.all.last?.script.contains("codex plugin add") == true)

        let record = try state(.chatGPT)
        XCTAssertEqual(record["version"] as? String, "0.1.0")
        XCTAssertEqual(record["marketplace"] as? String, "overlord-local")
        XCTAssertEqual(record["destination"] as? String, destination.path)
        let files = try XCTUnwrap(record["files"] as? [String: String])
        XCTAssertEqual(Set(files.keys), [
            ".claude-plugin/plugin.json", ".codex-plugin/plugin.json", ".mcp.json", "mcp.json",
            "scribe-mcp-launcher", "skills/scribe-transcripts/SKILL.md",
        ])
        XCTAssertEqual(files["skills/scribe-transcripts/SKILL.md"], try AssistantPluginInstaller.sha256(of: destination.appending(path: "skills/scribe-transcripts/SKILL.md")))
        XCTAssertEqual(codex.status(), .installed(version: "0.1.0"))

        // A second run changes nothing.
        let stateData = try Data(contentsOf: support.appending(path: "Scribe/Integrations/state/codex.json"))
        let marketplaceData = try Data(contentsOf: marketplaceJSON)
        _ = try await codex.install()
        XCTAssertEqual(try Data(contentsOf: support.appending(path: "Scribe/Integrations/state/codex.json")), stateData)
        XCTAssertEqual(try Data(contentsOf: marketplaceJSON), marketplaceData)

        // Remove takes out only Scribe's entry.
        _ = try await codex.remove()
        XCTAssertEqual(commands.all.last?.arguments, ["scribe@overlord-local"])
        XCTAssertTrue(commands.all.last?.script.contains("codex plugin remove") == true)
        XCTAssertEqual(try XCTUnwrap(json(marketplaceJSON)["plugins"] as? [[String: Any]]).map { $0["name"] as? String }, ["overlord"])
        XCTAssertFalse(exists(destination))
        XCTAssertEqual(codex.status(), .notInstalled)
    }

    func testChatGPTCreatesScribeLocalWhenNoMarketplaceExistsAndRemoveDeletesIt() async throws {
        let marketplaceJSON = home.appending(path: ".agents/plugins/marketplace.json")
        let codex = installer(.chatGPT)
        _ = try await codex.install()
        let object = try json(marketplaceJSON)
        XCTAssertEqual(object["name"] as? String, "scribe-local")
        XCTAssertEqual(commands.all.last?.arguments, ["scribe@scribe-local"])
        _ = try await codex.remove()
        XCTAssertFalse(exists(marketplaceJSON))
    }

    func testChatGPTTreatsAlreadyInstalledAsSuccessAndAMissingCLIAsAWarning() async throws {
        commands.result = .init(status: 1, output: "Error: plugin scribe@scribe-local is already installed")
        let codex = installer(.chatGPT)
        let report = try await codex.install()
        XCTAssertEqual(report.warnings, [])

        commands.result = .init(status: 127, output: "")
        let missing = try await codex.install()
        XCTAssertEqual(missing.warnings.count, 1)
        XCTAssertTrue(missing.warnings[0].contains("codex plugin add scribe@scribe-local"))

        commands.result = .init(status: 2, output: "boom\nmarketplace is broken")
        do {
            _ = try await codex.install()
            XCTFail("a failed codex command is reported")
        } catch {
            XCTAssertEqual(error.localizedDescription, "marketplace is broken")
        }
    }

    func testAMarketplaceThatIsNotJSONIsNeverOverwritten() async throws {
        let marketplaceJSON = home.appending(path: ".agents/plugins/marketplace.json")
        try write("not json", to: marketplaceJSON)
        do {
            _ = try await installer(.chatGPT).install()
            XCTFail("an unreadable marketplace stops the install")
        } catch {}
        XCTAssertEqual(try String(contentsOf: marketplaceJSON, encoding: .utf8), "not json")
    }

    // MARK: - Claude

    func testClaudeInstallMergesClaudeDesktopConfigKeepingOtherServers() async throws {
        let config = support.appending(path: "Claude/claude_desktop_config.json")
        try write("""
        { "globalShortcut": "Cmd+Space", "mcpServers": { "other": { "command": "/usr/bin/other", "args": ["--x"] } } }
        """, to: config)
        let claude = installer(.claude, apps: ["com.anthropic.claudefordesktop"])
        _ = try await claude.install()

        let managed = support.appending(path: "Scribe/Integrations/local-plugins/claude")
        let launcher = managed.appending(path: "plugins/scribe/scribe-mcp-launcher")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: launcher.path))
        XCTAssertTrue(exists(managed.appending(path: ".claude-plugin/marketplace.json")))
        XCTAssertFalse(exists(managed.appending(path: "relay")), "the relay CLI is not part of the plugin")

        let object = try json(config)
        XCTAssertEqual(object["globalShortcut"] as? String, "Cmd+Space")
        let servers = try XCTUnwrap(object["mcpServers"] as? [String: [String: Any]])
        XCTAssertEqual(servers["other"]?["command"] as? String, "/usr/bin/other")
        XCTAssertEqual(servers["other"]?["args"] as? [String], ["--x"])
        XCTAssertEqual(servers["scribe"]?["command"] as? String, launcher.path)

        // Claude Code gets the managed marketplace.
        XCTAssertEqual(commands.all.last?.arguments, [managed.path])
        XCTAssertTrue(commands.all.last?.script.contains("claude plugin install scribe@scribe-local") == true)
        XCTAssertEqual(try state(.claude)["claudeDesktopLauncher"] as? String, launcher.path)

        _ = try await claude.remove()
        XCTAssertTrue(commands.all.last?.script.contains("claude plugin uninstall scribe@scribe-local") == true)
        XCTAssertTrue(commands.all.last?.script.contains("claude plugin marketplace remove scribe-local") == true)
        let after = try json(config)
        XCTAssertEqual(after["globalShortcut"] as? String, "Cmd+Space")
        XCTAssertEqual((after["mcpServers"] as? [String: Any]).map { Set($0.keys) }, ["other"])
        XCTAssertFalse(exists(managed))
        XCTAssertEqual(claude.status(), .notInstalled)
    }

    func testClaudeInstallIsIsolatedFromAnOlderScribeRelayStagingPath() async throws {
        let old = support.appending(path: "Scribe/Integrations/claude")
        try write("// old relay", to: old.appending(path: "plugins/scribe/dist/cli.mjs"))
        _ = try await installer(.claude).install()
        XCTAssertTrue(exists(old.appending(path: "plugins/scribe/dist/cli.mjs")))
        XCTAssertTrue(exists(support.appending(path: "Scribe/Integrations/local-plugins/claude/plugins/scribe/scribe-mcp-launcher")))
    }

    func testClaudeMigratesPreviousMarketplaceWithoutRemovingOldRelayFiles() async throws {
        let claude = installer(.claude, apps: ["com.anthropic.claudefordesktop"])
        _ = try await claude.install()
        let current = support.appending(path: "Scribe/Integrations/local-plugins/claude")
        let old = support.appending(path: "Scribe/Integrations/claude")
        try FileManager.default.moveItem(at: current, to: old)
        let stateURL = support.appending(path: "Scribe/Integrations/state/claude.json")
        var record = try state(.claude)
        record["destination"] = old.path
        record["claudeDesktopLauncher"] = old.appending(path: "plugins/scribe/scribe-mcp-launcher").path
        try AssistantPluginInstaller.writeJSONObject(record, to: stateURL)
        let config = support.appending(path: "Claude/claude_desktop_config.json")
        try AssistantPluginInstaller.writeJSONObject(["mcpServers": ["scribe": ["command": old.appending(path: "plugins/scribe/scribe-mcp-launcher").path]]], to: config)

        XCTAssertEqual(claude.status(), .updateAvailable(installed: "0.1.0"))
        _ = try await claude.install()
        XCTAssertTrue(exists(old.appending(path: "plugins/scribe/scribe-mcp-launcher")))
        XCTAssertTrue(exists(current.appending(path: "plugins/scribe/scribe-mcp-launcher")))
        XCTAssertEqual(try state(.claude)["destination"] as? String, current.path)
        let servers = try XCTUnwrap(json(config)["mcpServers"] as? [String: [String: Any]])
        XCTAssertEqual(servers["scribe"]?["command"] as? String, current.appending(path: "plugins/scribe/scribe-mcp-launcher").path)
        XCTAssertTrue(commands.all.contains { $0.script.contains("claude plugin marketplace remove scribe-local") })
        XCTAssertEqual(commands.all.last?.arguments, [current.path])
    }

    func testClaudeWithoutClaudeDesktopLeavesItsConfigAlone() async throws {
        _ = try await installer(.claude).install()
        XCTAssertFalse(exists(support.appending(path: "Claude/claude_desktop_config.json")))
        XCTAssertNil(try state(.claude)["claudeDesktopLauncher"])
    }

    func testClaudeFailsWhenNeitherClaudeCodeNorClaudeDesktopIsInstalled() async throws {
        commands.result = .init(status: 127, output: "")
        do {
            _ = try await installer(.claude).install()
            XCTFail("nothing to install into")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Neither Claude Code nor Claude Desktop"))
        }
        let desktopOnly = try await installer(.claude, apps: ["com.anthropic.claudefordesktop"]).install()
        XCTAssertEqual(desktopOnly.warnings, ["The claude command was not found, so Scribe was added to Claude Desktop only."])
    }

    func testClaudeDesktopEntryThePersonChangedIsKeptOnRemove() async throws {
        let config = support.appending(path: "Claude/claude_desktop_config.json")
        let claude = installer(.claude, apps: ["com.anthropic.claudefordesktop"])
        _ = try await claude.install()
        try write(#"{"mcpServers":{"scribe":{"command":"/elsewhere/scribe"}}}"#, to: config)
        let report = try await claude.remove()
        XCTAssertEqual(report.warnings.count, 1)
        XCTAssertEqual(((try json(config)["mcpServers"] as? [String: [String: Any]])?["scribe"]?["command"]) as? String, "/elsewhere/scribe")
    }

    // MARK: - Cursor

    func testCursorCopiesThePluginDirectoryWithoutRegistering() async throws {
        let cursor = installer(.cursor)
        _ = try await cursor.install()
        let destination = home.appending(path: ".cursor/plugins/local/scribe")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: destination.appending(path: "scribe-mcp-launcher").path))
        XCTAssertEqual(
            try String(contentsOf: destination.appending(path: "skills/scribe-transcripts/SKILL.md"), encoding: .utf8),
            "Find meetings."
        )
        XCTAssertTrue(commands.all.isEmpty)
        XCTAssertEqual(try state(.cursor)["version"] as? String, "0.1.0")
        XCTAssertEqual(cursor.status(), .installed(version: "0.1.0"))

        _ = try await cursor.remove()
        XCTAssertFalse(exists(destination))
        XCTAssertTrue(exists(home.appending(path: ".cursor/plugins/local")), "only Scribe's folder is removed")
        XCTAssertFalse(exists(support.appending(path: "Scribe/Integrations/state/cursor.json")))
    }

    // MARK: - Updates

    func testUpdateAfterAVersionBumpRemovesObsoleteFilesAndKeepsEditedOnes() async throws {
        let cursor = installer(.cursor)
        _ = try await cursor.install()
        let destination = home.appending(path: ".cursor/plugins/local/scribe")
        // The person edits one managed file.
        try write("My own notes.", to: destination.appending(path: "skills/scribe-transcripts/SKILL.md"))

        try writeBundle(version: "0.2.0", skill: "Find and search meetings.", extraFile: true, obsoleteFile: false)
        XCTAssertEqual(cursor.status(), .updateAvailable(installed: "0.1.0"))

        let report = try await cursor.install()
        XCTAssertEqual(report.warnings, ["Kept skills/scribe-transcripts/SKILL.md, which was changed after Scribe installed it."])
        XCTAssertEqual(try String(contentsOf: destination.appending(path: "skills/scribe-transcripts/SKILL.md"), encoding: .utf8), "My own notes.")
        XCTAssertFalse(exists(destination.appending(path: "mcp.json")), "a file the package no longer ships is removed")
        XCTAssertTrue(exists(destination.appending(path: "ui/transcripts.html")))
        XCTAssertEqual(try state(.cursor)["version"] as? String, "0.2.0")
        XCTAssertEqual(cursor.status(), .installed(version: "0.2.0"))

        // Removing keeps the edited file too.
        let removal = try await cursor.remove()
        XCTAssertEqual(removal.warnings.count, 1)
        XCTAssertTrue(exists(destination.appending(path: "skills/scribe-transcripts/SKILL.md")))
        XCTAssertFalse(exists(destination.appending(path: "scribe-mcp-launcher")))
    }

    func testAChangedManifestWithTheSameVersionOrAMissingFileOffersAnUpdate() async throws {
        let cursor = installer(.cursor)
        _ = try await cursor.install()
        try FileManager.default.removeItem(at: home.appending(path: ".cursor/plugins/local/scribe/.mcp.json"))
        XCTAssertEqual(cursor.status(), .updateAvailable(installed: "0.1.0"))
        _ = try await cursor.install()
        XCTAssertEqual(cursor.status(), .installed(version: "0.1.0"))
        try writeBundle(version: "0.1.0", skill: "Changed skill.")
        XCTAssertEqual(cursor.status(), .updateAvailable(installed: "0.1.0"))
    }

    func testVersionComparison() {
        XCTAssertTrue(AssistantPluginInstaller.isVersion("0.2.0", newerThan: "0.1.9"))
        XCTAssertTrue(AssistantPluginInstaller.isVersion("0.10.0", newerThan: "0.9"))
        XCTAssertFalse(AssistantPluginInstaller.isVersion("0.1.0", newerThan: "0.1.0"))
        XCTAssertFalse(AssistantPluginInstaller.isVersion("0.1", newerThan: "0.1.0"))
    }

    func testDetectionUsesTheAppOrTheHomeFolder() throws {
        XCTAssertFalse(installer(.cursor).isDetected)
        XCTAssertTrue(installer(.cursor, apps: ["com.todesktop.230313mzl4w4u92"]).isDetected)
        try FileManager.default.createDirectory(at: home.appending(path: ".codex"), withIntermediateDirectories: true)
        XCTAssertTrue(installer(.chatGPT).isDetected)
    }
}
