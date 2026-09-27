import Foundation
import ScribeMCPCore

/// The connector package that ships inside Scribe.app, and installing it.
///
/// The build copies Integrations/scribe's packaged Claude marketplace into the
/// app's resources. Its `plugins/scribe` is the one local plugin every desktop
/// harness installs (see `AssistantPluginInstaller`); it runs Scribe.app's
/// `scribe-mcp-launcher`. The relay URL in relay/connector.json is metadata only.
@MainActor
public final class AssistantConnectorPackage: ObservableObject {
    /// One harness's install button: what is installed, and the last outcome.
    public struct PluginState: Equatable, Sendable {
        public var status: AssistantPluginInstaller.Status = .notInstalled
        public var isDetected = false
        public var isWorking = false
        /// Warnings from the last install or removal, or why it failed.
        public var message: String?
        public var failed = false
    }

    @Published public private(set) var plugins: [AssistantHarness: PluginState] = [:]

    /// Absent in a build that did not bundle the package (a bare Xcode build).
    public let bundledMarketplace: URL?
    private let environment: AssistantPluginEnvironment

    public init(
        bundle: Bundle = .main,
        environment: AssistantPluginEnvironment = .live
    ) {
        let candidate = bundle.resourceURL?.appending(path: "AssistantConnector/claude", directoryHint: .isDirectory)
        self.bundledMarketplace = candidate.map(Self.isMarketplace) == true ? candidate : nil
        self.environment = environment
    }

    public var isAvailable: Bool { bundledMarketplace != nil }

    /// The relay this build's ChatGPT plugin names, from the packaged
    /// `connector.json`; absent when the build was packaged without one.
    public var packagedRelay: AssistantServerAddress? {
        guard let bundledMarketplace,
              let data = try? Data(contentsOf: bundledMarketplace.appending(path: "relay/connector.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = object["connector_url"] as? String else { return nil }
        return try? AssistantServerAddress.parse(url).get()
    }

    // MARK: - Local plugins

    public func installer(for harness: AssistantHarness) -> AssistantPluginInstaller? {
        bundledMarketplace.map { AssistantPluginInstaller(harness: harness, bundledMarketplace: $0, environment: environment) }
    }

    public func plugin(_ harness: AssistantHarness) -> PluginState {
        plugins[harness] ?? PluginState()
    }

    /// Reads each harness's install record and whether it is on this Mac.
    public func refreshPlugins() {
        for harness in AssistantHarness.allCases {
            var state = plugin(harness)
            if let installer = installer(for: harness) {
                state.status = installer.status()
                state.isDetected = installer.isDetected
            }
            plugins[harness] = state
        }
    }

    /// Installs or updates the plugin for one harness.
    public func install(_ harness: AssistantHarness) async {
        await perform(harness) { try await $0.install() }
    }

    /// Removes the plugin and its marketplace or config entries.
    public func remove(_ harness: AssistantHarness) async {
        await perform(harness) { try await $0.remove() }
    }

    private func perform(
        _ harness: AssistantHarness,
        _ action: @escaping @Sendable (AssistantPluginInstaller) async throws -> AssistantPluginInstaller.Report
    ) async {
        guard let installer = installer(for: harness), !plugin(harness).isWorking else { return }
        plugins[harness, default: PluginState()].isWorking = true
        var state = plugin(harness)
        do {
            let report = try await Task.detached { try await action(installer) }.value
            state.message = report.warnings.isEmpty ? nil : report.warnings.joined(separator: "\n")
            state.failed = false
        } catch {
            state.message = error.localizedDescription
            state.failed = true
        }
        state.isWorking = false
        state.status = installer.status()
        state.isDetected = installer.isDetected
        plugins[harness] = state
    }

    // MARK: - Relay

    public func relayClient() -> RelayClient {
        let directory = ProcessInfo.processInfo.environment["SCRIBE_TRANSCRIPTS_DIR"].map { URL(filePath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Meeting Transcripts")
        return RelayClient(credentials: RelayCredentialsStore(file: AssistantRelayAgent.linkURL),
                           transcriptDirectory: directory)
    }

    /// Settings actions on this Mac's relay account.
    public func runRelayCommand(_ arguments: [String]) async throws -> String {
        let client = relayClient()
        switch arguments {
        case ["code"]: return try await client.linkCode()
        case ["grants"]: return try await client.grants()
        case ["revoke", "--all"]: try await client.revoke(); return ""
        case ["unlink"]: try await client.unlink(); return ""
        default: throw CommandError(message: "Unknown relay action.")
        }
    }

    struct CommandError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private nonisolated static func isMarketplace(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appending(path: ".claude-plugin/marketplace.json").path)
    }
}
