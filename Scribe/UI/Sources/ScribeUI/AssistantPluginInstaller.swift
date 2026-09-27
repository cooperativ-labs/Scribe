import AppKit
import CryptoKit
import Foundation

/// The desktop assistants Scribe installs its local plugin into.
///
/// Every harness gets the same plugin tree from the app's connector package;
/// the tree runs Scribe.app's `scribe-mcp-launcher`, which finds the app at
/// every start, so an app update needs no plugin update. Only a change to the
/// manifests or skills does.
public enum AssistantHarness: String, CaseIterable, Identifiable, Sendable {
    /// ChatGPT desktop and the Codex CLI share `~/.codex` and the personal
    /// Agent Plugins marketplace.
    case chatGPT = "codex"
    /// Claude Code through its plugin marketplace, and Claude Desktop through
    /// `claude_desktop_config.json`.
    case claude
    case cursor

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .chatGPT: "ChatGPT"
        case .claude: "Claude"
        case .cursor: "Cursor"
        }
    }

    /// Which apps the one plugin reaches.
    public var covers: String? {
        switch self {
        case .chatGPT: "ChatGPT desktop and Codex"
        case .claude: "Claude Code and Claude Desktop"
        case .cursor: nil
        }
    }

    /// The apps whose presence means the harness is on this Mac.
    var bundleIdentifiers: [String] {
        switch self {
        case .chatGPT: ["com.openai.chat", "com.openai.codex"]
        case .claude: ["com.anthropic.claudefordesktop"]
        case .cursor: ["com.todesktop.230313mzl4w4u92"]
        }
    }

    /// A folder the harness creates in the home directory, which also covers
    /// a CLI installed without an app.
    var homeFolder: String {
        switch self {
        case .chatGPT: ".codex"
        case .claude: ".claude"
        case .cursor: ".cursor"
        }
    }
}

/// Where an installer reads and writes, and how it runs commands, so tests
/// can point it at a temporary home.
public struct AssistantPluginEnvironment: Sendable {
    public struct CommandResult: Sendable {
        public var status: Int32
        public var output: String

        public init(status: Int32, output: String) {
            self.status = status
            self.output = output
        }
    }

    public var home: URL
    /// `~/Library/Application Support`.
    public var applicationSupport: URL
    public var isAppInstalled: @Sendable (_ bundleIdentifier: String) -> Bool
    /// Runs a zsh script with positional arguments in a login shell.
    public var run: @Sendable (_ script: String, _ arguments: [String]) async -> CommandResult

    public init(
        home: URL,
        applicationSupport: URL,
        isAppInstalled: @escaping @Sendable (String) -> Bool,
        run: @escaping @Sendable (String, [String]) async -> CommandResult
    ) {
        self.home = home
        self.applicationSupport = applicationSupport
        self.isAppInstalled = isAppInstalled
        self.run = run
    }

    public static let live = AssistantPluginEnvironment(
        home: FileManager.default.homeDirectoryForCurrentUser,
        applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
        isAppInstalled: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil },
        run: { await runInLoginShell($0, $1) }
    )

    /// A login shell, because an app launched from the Dock does not inherit
    /// the PATH a terminal has, which is where `codex` and `claude` live.
    private static func runInLoginShell(_ script: String, _ arguments: [String]) async -> CommandResult {
        let prefixed = """
        export PATH="$HOME/.local/bin:$HOME/.claude/local:/opt/homebrew/bin:/usr/local/bin:$PATH"
        \(script)
        """
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(filePath: "/bin/zsh")
            process.arguments = ["-lc", prefixed, "zsh"] + arguments
            process.standardInput = FileHandle.nullDevice
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            do {
                try process.run()
            } catch {
                return CommandResult(status: -1, output: error.localizedDescription)
            }
            // A CLI waiting on a prompt would otherwise hold the button forever.
            let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: watchdog)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            watchdog.cancel()
            return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
        }.value
    }
}

/// Installs, updates, and removes the local plugin for one harness.
///
/// The shared part copies the managed files and records them, with the
/// package version and each file's SHA-256, in
/// `Application Support/Scribe/Integrations/state/<harness>.json`. That record
/// makes a re-run idempotent, lets an update delete files the package no
/// longer ships, and tells a file the person edited (left alone, with a
/// warning) from one Scribe wrote. Each harness adds only its destination and
/// its registration: a marketplace entry, a config entry, or a CLI command.
public struct AssistantPluginInstaller: Sendable {
    public enum Status: Equatable, Sendable {
        case notInstalled
        /// The app carries a newer or different plugin than the installed one.
        case updateAvailable(installed: String)
        case installed(version: String)
    }

    /// What an install or removal did that the person should know.
    public struct Report: Equatable, Sendable {
        public var warnings: [String] = []
    }

    public struct Failure: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    struct Record: Codable, Equatable {
        var version: String
        var destination: String
        /// Relative path → SHA-256 (hex) of each file Scribe wrote.
        var files: [String: String]
        /// Codex: the marketplace the entry was added to, whose name the
        /// plugin is registered under.
        var marketplace: String?
        /// Codex: Scribe created the marketplace file, so it may delete it.
        var createdMarketplace: Bool?
        /// Claude: the launcher path written to Claude Desktop's config.
        var claudeDesktopLauncher: String?
    }

    public static let pluginName = "scribe"
    static let defaultCodexMarketplace = "scribe-local"
    static let claudeMarketplace = AssistantConnectorCommands.marketplaceName

    public let harness: AssistantHarness
    /// The app's packaged Claude marketplace, whose `plugins/scribe` is the plugin.
    let bundledMarketplace: URL
    let environment: AssistantPluginEnvironment

    public init(harness: AssistantHarness, bundledMarketplace: URL, environment: AssistantPluginEnvironment = .live) {
        self.harness = harness
        self.bundledMarketplace = bundledMarketplace
        self.environment = environment
    }

    // MARK: - Paths

    var integrations: URL {
        environment.applicationSupport.appending(path: "Scribe/Integrations", directoryHint: .isDirectory)
    }

    var stateURL: URL {
        integrations.appending(path: "state/\(harness.rawValue).json")
    }

    /// The directory Scribe manages for this harness.
    var destination: URL {
        switch harness {
        case .chatGPT: environment.home.appending(path: ".codex/plugins/scribe", directoryHint: .isDirectory)
        // Older Scribe releases stage the Node relay in Integrations/claude
        // whenever they launch. Keep the native plugin in its own directory so
        // an older installed app cannot replace its launcher after an update.
        case .claude: integrations.appending(path: "local-plugins/claude", directoryHint: .isDirectory)
        case .cursor: environment.home.appending(path: ".cursor/plugins/local/scribe", directoryHint: .isDirectory)
        }
    }

    /// What is copied to `destination`.
    var source: URL {
        harness == .claude ? bundledMarketplace : bundledPlugin
    }

    var bundledPlugin: URL {
        bundledMarketplace.appending(path: "plugins/scribe", directoryHint: .isDirectory)
    }

    var codexMarketplaceURL: URL {
        environment.home.appending(path: ".agents/plugins/marketplace.json")
    }

    var claudeDesktopConfigURL: URL {
        environment.applicationSupport.appending(path: "Claude/claude_desktop_config.json")
    }

    /// The launcher Claude Desktop runs: the one in the managed marketplace.
    var claudeDesktopLauncher: URL {
        destination.appending(path: "plugins/scribe/scribe-mcp-launcher")
    }

    var isClaudeDesktopInstalled: Bool {
        environment.isAppInstalled("com.anthropic.claudefordesktop")
            || FileManager.default.fileExists(atPath: claudeDesktopConfigURL.deletingLastPathComponent().path)
    }

    // MARK: - Status

    /// The harness's app or its home folder is on this Mac.
    public var isDetected: Bool {
        harness.bundleIdentifiers.contains(where: environment.isAppInstalled)
            || FileManager.default.fileExists(atPath: environment.home.appending(path: harness.homeFolder).path)
    }

    public var bundledVersion: String {
        guard let data = try? Data(contentsOf: bundledPlugin.appending(path: ".claude-plugin/plugin.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? String else { return "0" }
        return version
    }

    public func status() -> Status {
        guard let record = loadRecord() else { return .notInstalled }
        let missing = record.files.keys.contains {
            !FileManager.default.fileExists(atPath: destination.appending(path: $0).path)
        }
        if missing || record.destination != destination.path
            || Self.isVersion(bundledVersion, newerThan: record.version)
            || (try? bundledFiles()) != record.files {
            return .updateAvailable(installed: record.version)
        }
        return .installed(version: record.version)
    }

    // MARK: - Install and remove

    /// Installs or updates the plugin. Running it again changes nothing.
    public func install() async throws -> Report {
        var report = Report()
        let previous = loadRecord()
        var record = try copyManagedFiles(previous: previous, report: &report)
        do {
            try await register(record: &record, previous: previous, report: &report)
        } catch {
            // Keep what was written, so Remove can still take it away.
            try saveRecord(record)
            throw error
        }
        try saveRecord(record)
        return report
    }

    /// Reverses `install`: the registration, then the files Scribe wrote.
    public func remove() async throws -> Report {
        var report = Report()
        guard let record = loadRecord() else { return report }
        try await unregister(record: record, report: &report)
        for (path, hash) in record.files.sorted(by: { $0.key < $1.key }) {
            removeManaged(path, recordedHash: hash, report: &report)
        }
        removeIfEmpty(destination)
        try FileManager.default.removeItem(at: stateURL)
        return report
    }

    // MARK: - Managed files

    func loadRecord() -> Record? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    func saveRecord(_ record: Record) throws {
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(record).write(to: stateURL, options: .atomic)
    }

    /// Relative path → hash of every file the package ships for this harness.
    /// The relay CLI beside the Claude marketplace is not part of any plugin.
    func bundledFiles() throws -> [String: String] {
        guard let paths = FileManager.default.subpaths(atPath: source.path) else {
            throw Failure(message: "The connector package is missing from this build of Scribe.")
        }
        var files: [String: String] = [:]
        for path in paths where !path.hasPrefix("relay/") && path != "relay" && !path.hasSuffix(".DS_Store") {
            let url = source.appending(path: path)
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            files[path] = try Self.sha256(of: url)
        }
        return files
    }

    private func copyManagedFiles(previous: Record?, report: inout Report) throws -> Record {
        let fileManager = FileManager.default
        let incoming = try bundledFiles()
        let recorded = previous?.files ?? [:]
        for (path, hash) in incoming.sorted(by: { $0.key < $1.key }) {
            let target = destination.appending(path: path)
            if let current = try? Self.sha256(of: target) {
                if current == hash { continue }
                // A file Scribe wrote and the person changed since is theirs.
                if let written = recorded[path], written != current {
                    report.warnings.append("Kept \(path), which was changed after Scribe installed it.")
                    continue
                }
                try fileManager.removeItem(at: target)
            }
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: source.appending(path: path), to: target)
        }
        for (path, hash) in recorded where incoming[path] == nil {
            removeManaged(path, recordedHash: hash, report: &report)
        }
        var record = previous ?? Record(version: bundledVersion, destination: destination.path, files: [:])
        record.version = bundledVersion
        record.destination = destination.path
        record.files = incoming
        return record
    }

    /// Deletes a file Scribe wrote, unless the person changed it since.
    private func removeManaged(_ path: String, recordedHash: String, report: inout Report) {
        let target = destination.appending(path: path)
        guard let current = try? Self.sha256(of: target) else { return }
        guard current == recordedHash else {
            report.warnings.append("Kept \(path), which was changed after Scribe installed it.")
            return
        }
        try? FileManager.default.removeItem(at: target)
        var parent = target.deletingLastPathComponent()
        while parent.path.hasPrefix(destination.path + "/") {
            removeIfEmpty(parent)
            parent = parent.deletingLastPathComponent()
        }
    }

    private func removeIfEmpty(_ directory: URL) {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? ["?"]
        if contents.allSatisfy({ $0 == ".DS_Store" }) { try? FileManager.default.removeItem(at: directory) }
    }

    static func sha256(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    static func isVersion(_ candidate: String, newerThan installed: String) -> Bool {
        let parts = { (text: String) in text.split(separator: ".").map { Int($0) ?? 0 } }
        let a = parts(candidate), b = parts(installed)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Registration

    private func register(record: inout Record, previous: Record?, report: inout Report) async throws {
        switch harness {
        case .chatGPT:
            let (name, created) = try upsertCodexMarketplace()
            record.marketplace = name
            if created { record.createdMarketplace = true }
            let plugin = "\(Self.pluginName)@\(name)"
            let result = await environment.run("""
            command -v codex >/dev/null 2>&1 || exit 127
            codex plugin add "$1"
            """, [plugin])
            if result.status == 127 {
                report.warnings.append("The codex command was not found, so only ChatGPT desktop will see Scribe. To use it in Codex, run: codex plugin add \(plugin)")
            } else if result.status != 0, !result.output.localizedCaseInsensitiveContains("already") {
                throw Failure(message: Self.lastLine(result.output) ?? "Codex could not add the plugin (exit \(result.status)).")
            }

        case .claude:
            let desktop = isClaudeDesktopInstalled
            if desktop {
                try mergeClaudeDesktopConfig()
                record.claudeDesktopLauncher = claudeDesktopLauncher.path
            }
            // A previous Scribe used Integrations/claude for this marketplace.
            // Claude Code must forget that source before adding the isolated
            // one; marketplace update only refreshes the old source in place.
            if previous?.destination == integrations.appending(path: "claude").path {
                _ = await environment.run("""
                command -v claude >/dev/null 2>&1 || exit 0
                claude plugin uninstall \(AssistantConnectorCommands.pluginID) >/dev/null 2>&1 || true
                claude plugin marketplace remove \(Self.claudeMarketplace) >/dev/null 2>&1 || true
                """, [])
            }
            let marketplace = Self.claudeMarketplace, plugin = AssistantConnectorCommands.pluginID
            let result = await environment.run("""
            command -v claude >/dev/null 2>&1 || exit 127
            claude plugin marketplace add "$1" || claude plugin marketplace update \(marketplace) || exit $?
            claude plugin install \(plugin) || exit $?
            claude plugin update \(plugin) >/dev/null 2>&1 || true
            """, [destination.path])
            if result.status == 127 {
                guard desktop else {
                    throw Failure(message: "Neither Claude Code nor Claude Desktop was found. Install one, then try again.")
                }
                report.warnings.append("The claude command was not found, so Scribe was added to Claude Desktop only.")
            } else if result.status != 0 {
                throw Failure(message: Self.lastLine(result.output) ?? "Claude Code could not install the plugin (exit \(result.status)).")
            }

        case .cursor:
            break
        }
    }

    private func unregister(record: Record, report: inout Report) async throws {
        switch harness {
        case .chatGPT:
            let name = record.marketplace ?? Self.defaultCodexMarketplace
            _ = await environment.run("""
            command -v codex >/dev/null 2>&1 || exit 0
            codex plugin remove "$1"
            """, ["\(Self.pluginName)@\(name)"])
            try removeCodexMarketplaceEntry(deleteFileIfEmpty: record.createdMarketplace == true)

        case .claude:
            _ = await environment.run("""
            command -v claude >/dev/null 2>&1 || exit 0
            claude plugin uninstall \(AssistantConnectorCommands.pluginID)
            claude plugin marketplace remove \(Self.claudeMarketplace)
            exit 0
            """, [])
            if let launcher = record.claudeDesktopLauncher {
                try removeClaudeDesktopEntry(launcher: launcher, report: &report)
            }

        case .cursor:
            break
        }
    }

    /// Adds or replaces the `scribe` entry in the personal Agent Plugins
    /// marketplace, keeping every other entry and the file's own name, which
    /// is the marketplace Codex registers the plugin under.
    func upsertCodexMarketplace() throws -> (name: String, created: Bool) {
        let url = codexMarketplaceURL
        let created = !FileManager.default.fileExists(atPath: url.path)
        var object = created
            ? ["name": Self.defaultCodexMarketplace, "interface": ["displayName": "Scribe Local Plugins"]]
            : try Self.readJSONObject(url)
        let name = object["name"] as? String ?? Self.defaultCodexMarketplace
        object["name"] = name
        var plugins = object["plugins"] as? [Any] ?? []
        let entry: [String: Any] = [
            "name": Self.pluginName,
            "source": ["source": "local", "path": "./.codex/plugins/scribe"],
            "policy": ["installation": "AVAILABLE", "authentication": "ON_INSTALL"],
            "category": "Productivity",
        ]
        if let index = plugins.firstIndex(where: { ($0 as? [String: Any])?["name"] as? String == Self.pluginName }) {
            plugins[index] = entry
        } else {
            plugins.append(entry)
        }
        object["plugins"] = plugins
        try Self.writeJSONObject(object, to: url)
        return (name, created)
    }

    func removeCodexMarketplaceEntry(deleteFileIfEmpty: Bool) throws {
        let url = codexMarketplaceURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var object = try Self.readJSONObject(url)
        let plugins = (object["plugins"] as? [Any] ?? []).filter {
            ($0 as? [String: Any])?["name"] as? String != Self.pluginName
        }
        if plugins.isEmpty, deleteFileIfEmpty {
            try FileManager.default.removeItem(at: url)
            return
        }
        object["plugins"] = plugins
        try Self.writeJSONObject(object, to: url)
    }

    /// Points Claude Desktop's `scribe` server at the managed launcher,
    /// keeping every other server and setting.
    func mergeClaudeDesktopConfig() throws {
        let url = claudeDesktopConfigURL
        var object = FileManager.default.fileExists(atPath: url.path) ? try Self.readJSONObject(url) : [:]
        var servers = object["mcpServers"] as? [String: Any] ?? [:]
        servers[Self.pluginName] = ["command": claudeDesktopLauncher.path]
        object["mcpServers"] = servers
        try Self.writeJSONObject(object, to: url)
    }

    func removeClaudeDesktopEntry(launcher: String, report: inout Report) throws {
        let url = claudeDesktopConfigURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var object = try Self.readJSONObject(url)
        guard var servers = object["mcpServers"] as? [String: Any],
              let entry = servers[Self.pluginName] as? [String: Any] else { return }
        guard entry["command"] as? String == launcher else {
            report.warnings.append("Kept the scribe server in Claude Desktop’s settings, which was changed after Scribe added it.")
            return
        }
        servers[Self.pluginName] = nil
        object["mcpServers"] = servers
        try Self.writeJSONObject(object, to: url)
    }

    /// Refuses to rewrite a file it cannot read, rather than replace it.
    static func readJSONObject(_ url: URL) throws -> [String: Any] {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] else {
            throw Failure(message: "\(url.path) is not a JSON object. Fix or move it, then try again.")
        }
        return object
    }

    static func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
    }

    private static func lastLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).last.map(String.init)
    }
}
