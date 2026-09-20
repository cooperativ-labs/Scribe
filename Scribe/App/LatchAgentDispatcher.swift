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

    /// Writes the transcript, creates the Latch session, and brings Latch
    /// forward. A failure at any step is reported as one sentence a person can
    /// act on; nothing half-done is left behind that they have to clean up.
    func send(_ request: TranscriptAgentRequest) async -> TranscriptAgentOutcome {
        func failure(_ message: String) -> TranscriptAgentOutcome {
            TranscriptAgentOutcome(
                sessionName: nil,
                agentName: request.agent.displayName,
                folderName: request.folder?.displayName,
                errorMessage: message
            )
        }

        let tools = await toolLocator.locate()
        guard let latchURL = tools.latchURL else {
            return failure(Self.latchMissingMessage)
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

        let transcriptFileURL: URL
        do {
            transcriptFileURL = try writeHandoffFile(for: request.transcript)
        } catch {
            return failure("The transcript could not be written for the agent: \(error.localizedDescription)")
        }

        let manifest = Self.manifest(
            for: request,
            executableURL: executableURL,
            transcriptFileURL: transcriptFileURL
        )
        let report: LatchCreateReport
        do {
            report = try await LatchCommand.create(manifest: manifest, latchURL: latchURL)
        } catch {
            return failure("Latch could not start \(request.agent.displayName): \(Self.describe(error))")
        }

        await Self.bringLatchForward(sessionID: report.session.id, latchURL: latchURL)
        return TranscriptAgentOutcome(
            sessionName: report.session.name,
            agentName: request.agent.displayName,
            folderName: request.folder?.displayName
        )
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

    // MARK: - The transcript the agent reads

    /// Writes the document the agent is pointed at: the same Knowledgebase
    /// export the window saves and copies, byte for byte, so what an agent
    /// files in the Knowledgebase is what Scribe itself would have uploaded.
    /// Handing over a file rather than a very long command keeps the
    /// transcript out of every process listing on the machine, and lets the
    /// agent re-read it as it works.
    private func writeHandoffFile(for transcript: CanonicalTranscript) throws -> URL {
        try FileManager.default.createDirectory(at: handoffDirectoryURL, withIntermediateDirectories: true)
        let document = try TranscriptExporter.export(transcript, as: .knowledgebase)
        let name = FileTranscriptExportWriter.basename(for: transcript)
        let stamp = Self.fileStampFormatter.string(from: Date())
        let destination = handoffDirectoryURL
            .appendingPathComponent("\(Self.fileSafe(name))-\(stamp)")
            .appendingPathExtension(TranscriptExportFormat.knowledgebase.fileExtension)
        try document.write(to: destination, options: .atomic)
        return destination
    }

    /// Keeps a transcript's name usable as one path component without changing
    /// what it says: separators and dots out, everything else left alone.
    private static func fileSafe(_ name: String) -> String {
        let cleaned = name.map { character -> Character in
            character == "/" || character == ":" || character == "." ? "-" : character
        }
        let trimmed = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "transcript" : String(trimmed.prefix(60))
    }

    private static let fileStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    // MARK: - The manifest

    /// Builds the launch manifest for one send.
    ///
    /// `argv` is the resolved agent binary, the options naming the model and
    /// effort, and the prompt, which every agent Scribe offers accepts as a
    /// positional argument that starts an interactive session. The absolute
    /// path matters: the session inherits
    /// whatever environment Latch runs with, and an agent installed under a
    /// version manager is not reliably on that `PATH`.
    ///
    /// Without a folder the session opens where the transcript was written: a
    /// place that is Scribe's own, where the agent can read the file and has
    /// no repository to wander into.
    static func manifest(
        for request: TranscriptAgentRequest,
        executableURL: URL,
        transcriptFileURL: URL
    ) -> LatchLaunchManifest {
        let workingDirectory = request.folder?.url.standardizedFileURL
            ?? transcriptFileURL.deletingLastPathComponent().standardizedFileURL
        let prompt = prompt(for: request, transcriptFileURL: transcriptFileURL)
        let title = request.transcript.title ?? request.transcript.source.filename
        return LatchLaunchManifest(
            launch: .init(
                argv: [executableURL.path] + runOptions(for: request) + [prompt],
                cwd: workingDirectory.path,
                // The transcript's location, so a person or the agent can reach
                // the file again from the session's own shell.
                env: ["SCRIBE_TRANSCRIPT_FILE": transcriptFileURL.path]
            ),
            display: .init(
                name: "scribe-\(fileSafe(title).lowercased().replacingOccurrences(of: " ", with: "-"))",
                title: title,
                commandLabel: request.agent.commandLabel,
                source: .init(kind: "scribe", externalRunID: request.transcript.transcriptID)
            )
        )
    }

    /// The person's instruction, then only what they could not have written
    /// themselves: where the transcript is, the MCP server they named, and
    /// whether a report belongs on disk. A report is saved only into a folder
    /// the person chose; otherwise the agent answers in its session.
    static func prompt(for request: TranscriptAgentRequest, transcriptFileURL: URL) -> String {
        var paragraphs = [
            request.instruction,
            "The transcript is at \(transcriptFileURL.path). Read that file first: it is Scribe's Knowledgebase transcript export (\(KnowledgebaseTranscriptExporter.schema) JSON), with the speakers, timestamps, and every segment.",
        ]
        if let mcpURL = request.mcpURL {
            paragraphs.append("Related information can be found at this MCP URL: \(mcpURL)")
        }
        if let folder = request.folder {
            paragraphs.append("Save your report as a Markdown file in \(folder.url.standardizedFileURL.path), the folder this session opened in.")
        } else {
            paragraphs.append("Print your summary here in this session. Do not save it to a file unless the instruction above asks for one.")
        }
        return paragraphs.joined(separator: "\n\n")
    }

    /// How each agent's command line names a model and an effort, as each
    /// documents it: `claude --model … --effort …`, `codex -m … -c
    /// model_reasoning_effort="…"` (a TOML value, hence the quotes),
    /// `gemini -m …`, `cursor-agent --model …`. The last two take no effort.
    static func runOptions(for request: TranscriptAgentRequest) -> [String] {
        var options: [String] = []
        switch request.agent.id {
        case "claude":
            if let model = request.model { options += ["--model", model] }
            if let effort = request.effort { options += ["--effort", effort.rawValue] }
        case "codex":
            if let model = request.model { options += ["-m", model] }
            if let effort = request.effort { options += ["-c", "model_reasoning_effort=\"\(effort.rawValue)\""] }
        case "gemini":
            if let model = request.model { options += ["-m", model] }
        default:
            if let model = request.model { options += ["--model", model] }
        }
        return options
    }

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

    var errorDescription: String? {
        switch self {
        case let .failed(command, status, message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "`\(command)` exited with status \(status)." : detail
        case .unreadableReport(let detail):
            return "Latch reported something Scribe could not read: \(detail)"
        }
    }
}

/// The two Latch commands Scribe uses, run as documented: the manifest goes in
/// over standard input, and the JSON report comes back out.
enum LatchCommand {
    static func create(manifest: LatchLaunchManifest, latchURL: URL) async throws -> LatchCreateReport {
        let payload = try manifest.encoded()
        let output = try await run(latchURL, arguments: ["create", "--manifest-file", "-", "--json"], standardInput: payload)
        do {
            return try LatchCreateReport.decode(output)
        } catch {
            throw LatchCommandError.unreadableReport(error.localizedDescription)
        }
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

            guard process.terminationStatus == 0 else {
                throw LatchCommandError.failed(
                    command: "latch " + arguments.joined(separator: " "),
                    status: process.terminationStatus,
                    message: String(decoding: errorOutput, as: UTF8.self)
                )
            }
            return output
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
