import Foundation

/// One coding agent a transcript can be handed to.
///
/// The window never learns how an agent is started. It shows what the host
/// found on this machine and names the one a person picked; building a command
/// out of that is the host's business.
public struct TranscriptAgent: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    /// The command that will run, shown so the choice is not a black box.
    public let commandLabel: String

    public init(id: String, displayName: String, commandLabel: String) {
        self.id = id
        self.displayName = displayName
        self.commandLabel = commandLabel
    }
}

/// A folder a person has connected for agent work. The agent's session opens here.
public struct TranscriptAgentFolder: Identifiable, Equatable, Sendable {
    public let id: String
    public let url: URL
    /// False once the folder has been moved or removed. Such a folder is still
    /// listed, so a person can recognize and drop it, but cannot be sent to.
    public let isReachable: Bool

    public init(id: String? = nil, url: URL, isReachable: Bool = true) {
        self.id = id ?? url.standardizedFileURL.path
        self.url = url
        self.isReachable = isReachable
    }

    public var displayName: String { url.lastPathComponent }

    /// The full location, with the home directory abbreviated the way Finder
    /// and a shell both write it.
    public var pathDescription: String {
        let path = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}

/// What the host offers the send sheet: the agents it found and the folders the
/// person has connected, or the single reason there is nothing to offer.
public struct TranscriptAgentEnvironment: Equatable, Sendable {
    public let agents: [TranscriptAgent]
    public let folders: [TranscriptAgentFolder]
    /// Why nothing can be sent right now — Latch missing, no agent installed —
    /// or nil when the sheet is usable.
    public let unavailableReason: String?

    public init(agents: [TranscriptAgent] = [], folders: [TranscriptAgentFolder] = [], unavailableReason: String? = nil) {
        self.agents = agents
        self.folders = folders
        self.unavailableReason = unavailableReason
    }
}

/// One transcript, on its way to one agent in one folder.
public struct TranscriptAgentRequest: Equatable, Sendable {
    /// What an agent is asked to do when the person wrote nothing of their own.
    public static let defaultInstruction = "Read this meeting transcript and summarize the decisions made and the work it commits us to."

    public let transcript: CanonicalTranscript
    public let agent: TranscriptAgent
    public let folder: TranscriptAgentFolder
    /// The person's own words, never empty: the default stands in for silence.
    public let instruction: String

    public init(transcript: CanonicalTranscript, agent: TranscriptAgent, folder: TranscriptAgentFolder, instruction: String) {
        self.transcript = transcript
        self.agent = agent
        self.folder = folder
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        self.instruction = trimmed.isEmpty ? Self.defaultInstruction : trimmed
    }
}

/// What starting the agent produced.
public struct TranscriptAgentOutcome: Equatable, Sendable {
    /// The session Latch created, as it names it.
    public let sessionName: String?
    public let agentName: String
    public let folderName: String
    public let errorMessage: String?

    public init(sessionName: String?, agentName: String, folderName: String, errorMessage: String? = nil) {
        self.sessionName = sessionName
        self.agentName = agentName
        self.folderName = folderName
        self.errorMessage = errorMessage
    }

    public var succeeded: Bool { errorMessage == nil }

    /// One line for the window: where the transcript went, or why it did not go.
    public var summary: String {
        if let errorMessage { return errorMessage }
        let session = sessionName.map { " as \u{201C}\($0)\u{201D}" } ?? ""
        return "Sent to \(agentName) in \(folderName)\(session). Open Latch to watch it work."
    }
}

/// Hands a finished transcript to an agent working in a folder.
///
/// The review window knows a transcript, a chosen agent, a chosen folder, and
/// what the person wants done. Everything after that — writing the transcript
/// somewhere the agent can read it, building a launch manifest, starting the
/// session, bringing Latch forward — belongs to the host, the way exporting,
/// deleting, and importing already do. A fixture-backed window with no
/// dispatcher attached simply does not offer the action.
public protocol TranscriptAgentDispatching: Sendable {
    /// The agents and folders available now. Called each time the sheet opens,
    /// because an agent can be installed and a folder moved between openings.
    func environment() async -> TranscriptAgentEnvironment
    /// Asks the person for another folder and returns the refreshed environment.
    /// Cancelling returns the environment unchanged.
    func connectFolder() async -> TranscriptAgentEnvironment
    /// Drops a folder from the connected list. The folder itself is untouched.
    func disconnectFolder(id: TranscriptAgentFolder.ID) async -> TranscriptAgentEnvironment
    /// Starts the agent on this transcript.
    func send(_ request: TranscriptAgentRequest) async -> TranscriptAgentOutcome
}
