import AppKit
import Foundation
import Platform
import ScribeAppCore
import Transcription

/// The host's side of handing a transcript to a coding agent.
///
/// Scribe does not manage the agent's life. It writes the transcript somewhere
/// readable, asks Latch for a persistent session running the agent — in the
/// folder the person chose, when they chose one — and steps out of the way: Latch owns the PTY,
/// the agent owns the conversation. That boundary is Latch's documented
/// integration shape, and it is why nothing here reads `~/.latch`, parses
/// terminal output, or tries to follow the session afterwards.
@MainActor
final class AgentHandoffService {
    /// Where transcripts handed to an agent are written, outside any folder a
    /// person connected: a connected folder is usually a repository, and Scribe
    /// has no business leaving files in one.
    static let defaultHandoffDirectoryURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Scribe/Agent Handoffs", isDirectory: true)

    private let settings: ScribeSettings
    private let handoffDirectoryURL: URL
    private let toolLocator: AgentToolLocator

    init(
        settings: ScribeSettings,
        handoffDirectoryURL: URL = AgentHandoffService.defaultHandoffDirectoryURL,
        toolLocator: AgentToolLocator = AgentToolLocator()
    ) {
        self.settings = settings
        self.handoffDirectoryURL = handoffDirectoryURL
        self.toolLocator = toolLocator
    }

    /// The agents installed here and the folders the person has connected.
    func environment() async -> TranscriptAgentEnvironment {
        let tools = await toolLocator.locate()
        let folders = connectedFolders()
        return TranscriptAgentEnvironment(
            agents: tools.agents.map(\.agent),
            folders: folders,
            unavailableReason: unavailableReason(tools: tools)
        )
    }

    /// Asks for a folder and remembers it. Cancelling changes nothing.
    func connectFolder() async -> TranscriptAgentEnvironment {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Connect"
        panel.message = "Choose the folder the agent should work in."
        // Asked from the floating notes panel, Scribe is usually not the
        // active app and the person may be on a full-screen meeting's Space:
        // the dialog opens on the Space they are on, over that meeting, and
        // Scribe is activated so it takes the keyboard.
        panel.collectionBehavior.formUnion([.moveToActiveSpace, .fullScreenAuxiliary])
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        if panel.runModal() == .OK, let url = panel.url {
            settings.connectAgentFolder(url)
        }
        return await environment()
    }

    func disconnectFolder(id: TranscriptAgentFolder.ID) async -> TranscriptAgentEnvironment {
        if let folder = connectedFolders().first(where: { $0.id == id }) {
            settings.disconnectAgentFolder(folder.url)
        }
        return await environment()
    }

    /// Writes the transcript (and long notes), creates the Latch session, and
    /// brings Latch forward. A failure at any step is reported as one sentence
    /// a person can act on. What the agent is told, and every file written for
    /// it, is `AgentHandoffPayload`'s: handoff files are owner-only, named
    /// after the send, and deleted after `AgentHandoffPayload.retention`.
    func send(_ request: TranscriptAgentRequest) async -> TranscriptAgentOutcome {
        func failure(_ message: String, definite: Bool = true) -> TranscriptAgentOutcome {
            TranscriptAgentOutcome(
                sessionName: nil,
                agentName: request.agent.displayName,
                folderName: request.folder?.displayName,
                errorMessage: message,
                failureIsDefinite: definite
            )
        }

        let tools = await toolLocator.locate()
        guard let latchURL = tools.latchURL else {
            return failure(Self.latchMissingMessage)
        }
        // The operation ID goes to Latch as its request ID whenever Latch
        // accepts one, so a repeat of this send can never start a second
        // agent. A send that fires with nobody watching requires it.
        let supportsRequestID = await LatchCommand.supportsRequestID(latchURL: latchURL)
        if request.delivery == .background, !supportsRequestID {
            return failure("This version of Latch can\u{2019}t guarantee a queued send starts only one agent, so nothing was sent. Update Latch, then send it yourself.")
        }
        guard let executableURL = tools.agents.first(where: { $0.agent.id == request.agent.id })?.executableURL else {
            return failure("\(request.agent.displayName) is no longer installed on this Mac.")
        }
        if let folder = request.folder {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return failure("\(folder.displayName) is no longer where it was. Connect the folder again.")
            }
        }

        // Old handoffs go first: what is written next must not be pruned.
        AgentHandoffPayload.pruneFiles(in: handoffDirectoryURL)
        let files: AgentHandoffPayload.Files
        do {
            files = try AgentHandoffPayload.writeFiles(for: request, in: handoffDirectoryURL)
        } catch {
            return failure("The transcript could not be written for the agent: \(error.localizedDescription)")
        }

        let manifest = AgentHandoffPayload.manifest(for: request, executableURL: executableURL, files: files)
        let report: LatchCreateReport
        do {
            report = try await LatchCommand.create(
                manifest: manifest,
                latchURL: latchURL,
                requestID: supportsRequestID ? request.operationID : nil
            )
        } catch let error as LatchCommandError {
            return failure("Latch could not start \(request.agent.displayName): \(Self.describe(error))", definite: error.startedNothing)
        } catch {
            return failure("Latch could not start \(request.agent.displayName): \(Self.describe(error))")
        }

        // A send nobody is watching never takes the screen; its notification
        // offers to open the session instead.
        if request.delivery == .manual {
            await Self.bringLatchForward(sessionID: report.session.id, latchURL: latchURL)
        }
        return TranscriptAgentOutcome(
            sessionName: report.session.name,
            sessionID: report.session.id,
            agentName: request.agent.displayName,
            folderName: request.folder?.displayName
        )
    }

    /// Puts a session that already exists in front of the person again.
    func openSession(id: String) async -> String? {
        let tools = await toolLocator.locate()
        guard let latchURL = tools.latchURL else { return Self.latchMissingMessage }
        await Self.bringLatchForward(sessionID: id, latchURL: latchURL)
        return nil
    }

    // MARK: - Folders

    private func connectedFolders() -> [TranscriptAgentFolder] {
        settings.agentFolderURLs.map { url in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            return TranscriptAgentFolder(url: url, isReachable: exists && isDirectory.boolValue)
        }
    }

    private func unavailableReason(tools: AgentToolLocator.Tools) -> String? {
        if tools.latchURL == nil { return Self.latchMissingMessage }
        if tools.agents.isEmpty {
            return "No coding agent was found on this Mac. Install Claude Code, Codex, Gemini CLI, or Cursor Agent, then open this sheet again."
        }
        return nil
    }

    private static let latchMissingMessage = "Latch was not found on this Mac. Install the `latch` command line tool, then open this sheet again."

    // MARK: - Showing the session

    /// Puts the new session in front of the person. Latch Desktop already lists
    /// every session, so activating it is enough; without it, Latch's own iTerm
    /// viewer is asked for. Neither is allowed to turn a created session into a
    /// reported failure — the agent is already working either way.
    private static func bringLatchForward(sessionID: String, latchURL: URL) async {
        if let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "co.cooperativ.latch.desktop") {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try? await NSWorkspace.shared.openApplication(at: application, configuration: configuration)
            return
        }
        try? await LatchCommand.openViewer(sessionID: sessionID, latchURL: latchURL)
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? LocalizedError, let description = error.errorDescription { return description }
        return error.localizedDescription
    }
}

// MARK: - Running the Latch CLI

enum LatchCommandError: LocalizedError {
    case failed(command: String, status: Int32, message: String)
    case unreadableReport(String)
    /// `latch create --request-id` refused or failed and said why: nothing
    /// was started.
    case createRefused(code: String, message: String)
    /// `latch` did not finish normally (killed, or it exited without saying
    /// what happened), so whether it started a session is unknown.
    case outcomeUnknown(String)

    var errorDescription: String? {
        switch self {
        case let .failed(command, status, message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "`\(command)` exited with status \(status)." : detail
        case .unreadableReport(let detail):
            return "Latch reported something Scribe could not read: \(detail)"
        case let .createRefused(code, message):
            switch code {
            case "request_id_conflict":
                return "Latch already has a different send under this ID, so nothing was started. (\(message))"
            case "request_id_session_removed":
                return "Latch already started this send, but that session has since been removed."
            default:
                return message
            }
        case .outcomeUnknown(let detail):
            return detail
        }
    }

    /// True when Latch certainly started nothing. An unreadable report or
    /// an interrupted `latch` may hide a session that did start.
    var startedNothing: Bool {
        switch self {
        case .createRefused: true
        case .failed: true
        case .unreadableReport, .outcomeUnknown: false
        }
    }
}

/// The two Latch commands Scribe uses, run as documented: the manifest goes in
/// over standard input, and the JSON report comes back out.
enum LatchCommand {
    /// `latch create`. With a request ID (an operation ID), Latch starts at
    /// most one session for it: a repeat returns the first session. A
    /// refusal is reported on standard output as a JSON error with a code;
    /// anything Scribe cannot read after a request ID was sent is an unknown
    /// outcome, never "nothing started".
    static func create(manifest: LatchLaunchManifest, latchURL: URL, requestID: UUID? = nil) async throws -> LatchCreateReport {
        let payload = try manifest.encoded()
        var arguments = ["create", "--manifest-file", "-", "--json"]
        if let requestID { arguments += ["--request-id", requestID.uuidString.lowercased()] }
        let result = try await execute(latchURL, arguments: arguments, standardInput: payload)
        if result.exitedNormally, result.status == 0 {
            do {
                return try LatchCreateReport.decode(result.output)
            } catch {
                throw LatchCommandError.unreadableReport(error.localizedDescription)
            }
        }
        guard requestID != nil else {
            throw LatchCommandError.failed(command: "latch create", status: result.status, message: result.errorText)
        }
        if result.exitedNormally, let refusal = try? LatchCreateErrorReport.decode(result.output) {
            throw LatchCommandError.createRefused(code: refusal.error.code, message: refusal.error.message)
        }
        throw LatchCommandError.outcomeUnknown(
            result.exitedNormally
                ? (result.errorText.isEmpty ? "`latch create` exited with status \(result.status) without saying whether it started the session." : result.errorText)
                : "`latch create` was stopped before it said whether it started the session."
        )
    }

    /// Whether this `latch` takes `--request-id` on `create`
    /// (`create-request-id` in `latch capabilities --json`). Asked once per
    /// executable; an older Latch is asked again next time, in case it was
    /// updated meanwhile.
    static func supportsRequestID(latchURL: URL) async -> Bool {
        if await RequestIDSupport.shared.isKnownSupported(latchURL) { return true }
        guard let result = try? await execute(latchURL, arguments: ["capabilities", "--json"], standardInput: nil),
              result.exitedNormally, result.status == 0,
              let capabilities = try? LatchCapabilitiesReport.decode(result.output) else { return false }
        let supported = capabilities.capabilities.extensions.contains(LatchCapabilitiesReport.createRequestIDExtension)
        if supported { await RequestIDSupport.shared.markSupported(latchURL) }
        return supported
    }

    private actor RequestIDSupport {
        static let shared = RequestIDSupport()
        private var supported: Set<URL> = []
        func isKnownSupported(_ url: URL) -> Bool { supported.contains(url) }
        func markSupported(_ url: URL) { supported.insert(url) }
    }

    static func openViewer(sessionID: String, latchURL: URL) async throws {
        _ = try await run(latchURL, arguments: ["open", sessionID, "--with", "iterm", "--as", "window", "--json"], standardInput: nil)
    }

    /// Latch refuses to create a session from inside one of its own panes, so a
    /// Scribe started from a Latch shell would inherit this marker and have
    /// every send refused as nesting. Scribe is not that pane — it is asking for
    /// a detached session — so the marker is dropped from the child.
    private static let nestingMarker = "LATCH_SESSION_ID"

    /// Runs one short command off the main actor and collects both streams.
    /// Standard error is kept for the failure message: `latch` explains a
    /// rejected manifest there, and that explanation is the useful half.
    private static func run(_ executableURL: URL, arguments: [String], standardInput: Data?) async throws -> Data {
        let result = try await execute(executableURL, arguments: arguments, standardInput: standardInput)
        guard result.exitedNormally, result.status == 0 else {
            throw LatchCommandError.failed(
                command: "latch " + arguments.joined(separator: " "),
                status: result.status,
                message: result.errorText
            )
        }
        return result.output
    }

    struct Result: Sendable {
        let status: Int32
        /// False when the process was killed by a signal.
        let exitedNormally: Bool
        let output: Data
        let errorOutput: Data

        var errorText: String {
            String(decoding: errorOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func execute(_ executableURL: URL, arguments: [String], standardInput: Data?) async throws -> Result {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment.removeValue(forKey: nestingMarker)
            process.environment = environment
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            let inputPipe = Pipe()
            process.standardInput = standardInput == nil ? FileHandle.nullDevice : inputPipe

            try process.run()
            if let standardInput {
                try? inputPipe.fileHandleForWriting.write(contentsOf: standardInput)
                try? inputPipe.fileHandleForWriting.close()
            }
            // Both pipes are drained before waiting: a command that fills one
            // while Scribe waits on exit would deadlock.
            let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return Result(
                status: process.terminationStatus,
                exitedNormally: process.terminationReason == .exit,
                output: output,
                errorOutput: errorOutput
            )
        }.value
    }
}

// MARK: - Finding the tools

/// Finds `latch` and the coding agents on this Mac.
///
/// An application launched from Finder has a short, system `PATH`, and every
/// agent worth offering installs somewhere else: a version manager, a user bin
/// directory, Homebrew. Well-known locations are checked first because that
/// costs nothing; only when something is still missing is the person's login
/// shell asked, which is the one place that knows where their tools live.
struct AgentToolLocator: Sendable {
    struct InstalledAgent: Sendable {
        let agent: TranscriptAgent
        let executableURL: URL
    }

    struct Tools: Sendable {
        let latchURL: URL?
        let agents: [InstalledAgent]
    }

    /// The agents Scribe offers, in the order the sheet lists them. Each takes
    /// its prompt as a positional argument and stays interactive afterwards,
    /// which is what makes one `argv` shape serve all of them.
    static let catalog: [TranscriptAgent] = [
        TranscriptAgent(id: "claude", displayName: "Claude Code", commandLabel: "claude", supportsEffort: true),
        TranscriptAgent(id: "codex", displayName: "Codex", commandLabel: "codex", supportsEffort: true),
        TranscriptAgent(id: "gemini", displayName: "Gemini CLI", commandLabel: "gemini"),
        TranscriptAgent(id: "cursor-agent", displayName: "Cursor Agent", commandLabel: "cursor-agent"),
    ]

    /// Checked before the login shell, most specific first.
    static let searchDirectories = [
        "~/.local/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "~/.bun/bin",
        "~/.cargo/bin",
        "/usr/bin",
    ]

    func locate() async -> Tools {
        await Task.detached(priority: .userInitiated) {
            var found: [String: URL] = [:]
            let wanted = ["latch"] + Self.catalog.map(\.commandLabel)
            for command in wanted {
                if let url = Self.wellKnownURL(for: command) { found[command] = url }
            }
            let missing = wanted.filter { found[$0] == nil }
            if !missing.isEmpty {
                for (command, url) in Self.loginShellURLs(for: missing) { found[command] = url }
            }
            return Tools(
                latchURL: found["latch"],
                agents: Self.catalog.compactMap { agent in
                    found[agent.commandLabel].map { InstalledAgent(agent: agent, executableURL: $0) }
                }
            )
        }.value
    }

    private static func wellKnownURL(for command: String) -> URL? {
        for directory in searchDirectories {
            let url = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    /// Asks a login shell where the remaining commands are. One shell answers
    /// for all of them, and a shell that hangs or answers with something that
    /// is not an executable file simply contributes nothing.
    private static func loginShellURLs(for commands: [String]) -> [String: URL] {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let script = commands
            .map { "printf '%s\\t%s\\n' \($0) \"$(command -v \($0) 2>/dev/null)\"" }
            .joined(separator: "; ")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return [:]
        }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        var resolved: [String: URL] = [:]
        for line in String(decoding: output, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[1].isEmpty else { continue }
            let path = String(parts[1]).trimmingCharacters(in: .whitespaces)
            guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { continue }
            resolved[String(parts[0])] = URL(fileURLWithPath: path)
        }
        return resolved
    }
}

// MARK: - The window's side

/// The review window's side of sending: a thin hop onto the main actor, where
/// the handoff service lives. Held weakly so the view model never keeps the
/// host alive on its own, the way dropped-file importing already does.
struct LatchTranscriptAgentDispatcher: TranscriptAgentDispatching {
    private let service: WeakService

    init(service: AgentHandoffService) {
        self.service = WeakService(service)
    }

    func environment() async -> TranscriptAgentEnvironment {
        guard let service = await resolve() else { return Self.gone }
        return await service.environment()
    }

    func connectFolder() async -> TranscriptAgentEnvironment {
        guard let service = await resolve() else { return Self.gone }
        return await service.connectFolder()
    }

    func disconnectFolder(id: TranscriptAgentFolder.ID) async -> TranscriptAgentEnvironment {
        guard let service = await resolve() else { return Self.gone }
        return await service.disconnectFolder(id: id)
    }

    func send(_ request: TranscriptAgentRequest) async -> TranscriptAgentOutcome {
        guard let service = await resolve() else {
            return TranscriptAgentOutcome(
                sessionName: nil,
                agentName: request.agent.displayName,
                folderName: request.folder?.displayName,
                errorMessage: Self.goneReason
            )
        }
        return await service.send(request)
    }

    func openSession(id: String) async -> String? {
        guard let service = await resolve() else { return Self.goneReason }
        return await service.openSession(id: id)
    }

    private func resolve() async -> AgentHandoffService? {
        await MainActor.run { service.value }
    }

    private static let goneReason = "Sending to an agent is not available right now."
    private static let gone = TranscriptAgentEnvironment(unavailableReason: goneReason)

    /// The service is main-actor bound; the reference is only ever read there.
    private final class WeakService: @unchecked Sendable {
        weak var value: AgentHandoffService?
        init(_ value: AgentHandoffService) { self.value = value }
    }
}
