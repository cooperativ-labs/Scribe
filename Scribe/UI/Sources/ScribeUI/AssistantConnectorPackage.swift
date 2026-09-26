import Foundation

/// The connector package that ships inside Scribe.app, and installing it.
///
/// The build copies Integrations/scribe's packaged Claude marketplace into the
/// app's resources. It is staged into Application Support before use rather
/// than referenced in place: Claude Code loads a directory plugin from where
/// it lies, and an app bundle moves on update, translocation, or a drag to the
/// Trash. The same staged copy provides `cli.mjs` for the HTTP server that
/// ChatGPT and Claude reach through a tunnel.
@MainActor
public final class AssistantConnectorPackage: ObservableObject {
    public enum InstallState: Equatable, Sendable {
        case idle
        case installing
        case installed(note: String?)
        case failed(String)
    }

    @Published public private(set) var installState: InstallState = .idle

    /// Absent in a build that did not bundle the package (a bare Xcode build).
    public let bundledMarketplace: URL?
    public let stagedMarketplace: URL

    public nonisolated static let defaultStagedMarketplace = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Scribe/Integrations/claude", directoryHint: .isDirectory)

    public init(bundle: Bundle = .main, stagedMarketplace: URL = AssistantConnectorPackage.defaultStagedMarketplace) {
        let candidate = bundle.resourceURL?.appending(path: "AssistantConnector/claude", directoryHint: .isDirectory)
        self.bundledMarketplace = candidate.map(Self.isMarketplace) == true ? candidate : nil
        self.stagedMarketplace = stagedMarketplace
    }

    public var isAvailable: Bool { bundledMarketplace != nil }

    /// The server entry point inside the staged plugin.
    public var stagedCLI: URL {
        stagedMarketplace.appending(path: "plugins/scribe/dist/cli.mjs")
    }

    /// Replaces the staged copy with the one in this build of the app.
    @discardableResult
    public func stage() throws -> URL {
        guard let bundledMarketplace else { throw PackageError.notBundled }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: stagedMarketplace.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Copy beside the destination first, so a failed copy never leaves
        // Claude Code pointing at half a plugin.
        let incoming = stagedMarketplace.deletingLastPathComponent()
            .appending(path: ".claude-incoming-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.copyItem(at: bundledMarketplace, to: incoming)
        if fileManager.fileExists(atPath: stagedMarketplace.path) {
            _ = try fileManager.replaceItemAt(stagedMarketplace, withItemAt: incoming)
        } else {
            try fileManager.moveItem(at: incoming, to: stagedMarketplace)
        }
        return stagedMarketplace
    }

    /// Stages the package and registers it with the `claude` command.
    ///
    /// Both CLI steps are idempotent: adding the marketplace again repoints it
    /// at the staged copy, and installing an installed plugin is a no-op.
    public func installInClaudeCode() async {
        guard installState != .installing else { return }
        installState = .installing
        let marketplace: URL
        do {
            marketplace = try stage()
        } catch {
            installState = .failed(error.localizedDescription)
            return
        }
        let result = await Self.runInstall(marketplace: marketplace)
        installState = result
    }

    enum PackageError: LocalizedError {
        case notBundled

        var errorDescription: String? {
            "This build of Scribe does not include the connector package. Build it with Scripts/build-app.sh, or install it from Integrations/scribe."
        }
    }

    private nonisolated static func isMarketplace(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appending(path: ".claude-plugin/marketplace.json").path)
    }

    /// Runs in a login shell because an app launched from the Dock does not
    /// inherit the PATH a terminal has, which is where `claude` and `node` live.
    private nonisolated static func runInstall(marketplace: URL) async -> InstallState {
        let script = """
        export PATH="$HOME/.local/bin:$HOME/.claude/local:/opt/homebrew/bin:/usr/local/bin:$PATH"
        if ! command -v claude >/dev/null 2>&1; then
          echo "The claude command was not found. Install Claude Code, then try again." >&2
          exit 127
        fi
        claude plugin marketplace add "$1" || exit $?
        claude plugin install \(AssistantConnectorCommands.pluginID) || exit $?
        command -v node >/dev/null 2>&1 || echo "NODE_MISSING"
        """
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(filePath: "/bin/zsh")
            process.arguments = ["-lc", script, "zsh", marketplace.path]
            process.standardInput = FileHandle.nullDevice
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            do {
                try process.run()
            } catch {
                return .failed(error.localizedDescription)
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            guard process.terminationStatus == 0 else {
                let lastLine = text.split(whereSeparator: \.isNewline).last.map(String.init)
                return .failed(lastLine ?? "Claude Code could not install the plugin (exit \(process.terminationStatus)).")
            }
            return .installed(note: text.contains("NODE_MISSING")
                ? "Node.js was not found. Install Node.js 22 or newer so Claude Code can start the Scribe server."
                : nil)
        }.value
    }
}
