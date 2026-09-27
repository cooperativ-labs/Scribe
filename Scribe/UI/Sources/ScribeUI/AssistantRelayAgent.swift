import Foundation

/// Keeps this Mac connected to the Scribe relay while Scribe runs, so ChatGPT
/// and Claude can reach the library without a Terminal window.
///
/// It runs the bundled connector's `connect` command, which links the Mac on
/// first use and then only makes outbound HTTPS requests. The child process
/// watches a pipe Scribe holds open and exits when Scribe quits or crashes.
/// Whether to connect is remembered, so Scribe reconnects at launch.
@MainActor
public final class AssistantRelayAgent: ObservableObject {
    public enum State: Equatable, Sendable {
        case stopped
        case connecting
        case connected
        /// Waiting to retry after the connector exited unexpectedly.
        case retrying(String)
        /// Stopped for a reason retrying cannot fix, such as an unlink.
        case failed(String)
    }

    public static let shared = AssistantRelayAgent()

    /// Whether this Mac should stay connected; read at launch.
    public static let enabledKey = "scribe.settings.assistantRelayConnected"
    public static let relayAddressKey = "scribe.settings.assistantRelayAddress"
    /// Scribe's own relay, used when neither the person nor the build names another.
    public static let defaultRelayOrigin = "https://scribe.ovld.ai"

    /// Where the connector keeps this Mac's relay link (owner ID and agent secret).
    public static let linkURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Scribe/MCP/relay.json")

    /// Whether this Mac has linked to a relay, whether or not it is connected now.
    public static var isLinked: Bool { FileManager.default.fileExists(atPath: linkURL.path) }

    @Published public private(set) var state: State = .stopped

    private var process: Process?
    private var keepAlive: Pipe?
    private var retry: Task<Void, Never>?
    private var failures = 0
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    /// Reconnects at launch when the person left this Mac connected.
    public func resumeIfEnabled(package: AssistantConnectorPackage) {
        let text = defaults.string(forKey: Self.relayAddressKey) ?? package.packagedRelay?.origin ?? Self.defaultRelayOrigin
        guard isEnabled, state == .stopped,
              let relay = try? AssistantServerAddress.parse(text).get() else { return }
        start(package: package, relay: relay)
    }

    public func start(package: AssistantConnectorPackage, relay: AssistantServerAddress) {
        defaults.set(true, forKey: Self.enabledKey)
        retry?.cancel()
        failures = 0
        launch(package: package, relay: relay)
    }

    /// Stops serving and forgets the choice, so Scribe does not reconnect at launch.
    public func stop() {
        defaults.set(false, forKey: Self.enabledKey)
        halt()
        state = .stopped
    }

    /// Ends the connection for this run only, as when Scribe quits.
    public func halt() {
        retry?.cancel()
        retry = nil
        let running = process
        process = nil
        keepAlive = nil
        running?.terminate()
    }

    private func launch(package: AssistantConnectorPackage, relay: AssistantServerAddress) {
        halt()
        let cli: URL
        do {
            cli = try package.stage().appending(path: "plugins/scribe/dist/cli.mjs")
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        let child = Process()
        child.executableURL = URL(filePath: "/bin/zsh")
        child.arguments = ["-lc", Self.script, "zsh", cli.path, relay.origin]
        var environment = ProcessInfo.processInfo.environment
        environment["SCRIBE_EXIT_WITH_PARENT"] = "1"
        child.environment = environment
        let keepAlive = Pipe(), errors = Pipe()
        child.standardInput = keepAlive
        child.standardOutput = FileHandle.nullDevice
        child.standardError = errors
        let lines = Self.lastLines(of: errors)
        child.terminationHandler = { [weak self] ended in
            let status = ended.terminationStatus
            Task { @MainActor in
                // Let the last stderr lines arrive before reading why it stopped.
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, self.process === ended else { return }
                self.exited(status: status, message: lines.reason, package: package, relay: relay)
            }
        }
        do {
            try child.run()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        process = child
        self.keepAlive = keepAlive
        state = .connecting
        // The connector reports only failures; one that is still running after
        // a few seconds has linked and is polling the relay.
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, self.process === child, child.isRunning else { return }
            self.state = .connected
            self.failures = 0
        }
    }

    private func exited(status: Int32, message: String?, package: AssistantConnectorPackage, relay: AssistantServerAddress) {
        process = nil
        keepAlive = nil
        let reason = message?.replacingOccurrences(of: "Scribe MCP: ", with: "")
            ?? "The Scribe connector stopped (exit \(status))."
        // An unlinked Mac or a missing Node cannot recover by retrying.
        if status == 127 || reason.contains("unlinked") || reason.contains("Already linked") {
            defaults.set(false, forKey: Self.enabledKey)
            state = .failed(reason)
            return
        }
        let delay = [5, 15, 30, 60][min(failures, 3)]
        failures += 1
        state = .retrying(reason)
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.isEnabled else { return }
            self.launch(package: package, relay: relay)
        }
    }

    /// Runs in a login shell because an app launched from the Dock does not
    /// inherit the PATH where `node` lives.
    static let script = """
    export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
    if ! command -v node >/dev/null 2>&1; then
      echo "Node.js was not found. Install Node.js 22 or newer." >&2
      exit 127
    fi
    exec node "$1" connect "$2"
    """

    /// Collects the child's stderr lines, keeping the last few for status text.
    private nonisolated static func lastLines(of pipe: Pipe) -> LineBuffer {
        let buffer = LineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            buffer.append(String(decoding: data, as: UTF8.self))
        }
        return buffer
    }
}

/// Thread-safe tail of a child process's stderr.
final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ text: String) {
        lock.withLock {
            lines.append(contentsOf: text.split(whereSeparator: \.isNewline).map(String.init))
            lines = Array(lines.suffix(20))
        }
    }

    /// The connector's own last message, else the last line (a crash ends with Node's version).
    var reason: String? {
        lock.withLock { lines.last { $0.hasPrefix("Scribe MCP: ") } ?? lines.last }
    }
}
