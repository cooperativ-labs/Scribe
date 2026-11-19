import Foundation

/// One note written during a meeting: a paragraph of text and, when it was
/// written while audio was being captured, where in the recording it was made.
public struct MeetingNote: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var text: String
    /// Recording time, not wall time. Nil for a note written while capture was
    /// paused, stopping or stopped.
    public var recordingOffsetMilliseconds: Int?

    public init(id: UUID = UUID(), text: String, recordingOffsetMilliseconds: Int? = nil) {
        self.id = id
        self.text = text
        self.recordingOffsetMilliseconds = recordingOffsetMilliseconds
    }
}

/// Where a handoff runs. `unset` means the person has not chosen and the
/// default applies; `none` is the explicit "No folder" choice.
public enum MeetingHandoffFolder: Codable, Sendable, Equatable {
    case unset
    case none
    case folder(String)
}

/// Where the prompt text came from, so changing the folder can swap in that
/// folder's last prompt without overwriting words the person typed.
public enum MeetingPromptOrigin: String, Codable, Sendable, Equatable {
    case `default`
    case folderHistory
    case edited
}

/// The agent handoff a meeting will be sent with. Private to the draft record:
/// never exported, relayed or logged.
public struct MeetingHandoffSettings: Codable, Sendable, Equatable {
    public var agentID: String?
    public var model: String
    public var effort: String?
    public var folder: MeetingHandoffFolder
    public var mcpURL: String
    public var prompt: String
    public var promptOrigin: MeetingPromptOrigin

    public init(
        agentID: String? = nil,
        model: String = "",
        effort: String? = nil,
        folder: MeetingHandoffFolder = .unset,
        mcpURL: String = "",
        prompt: String = TranscriptAgentRequest.defaultInstruction,
        promptOrigin: MeetingPromptOrigin = .default
    ) {
        self.agentID = agentID
        self.model = model
        self.effort = effort
        self.folder = folder
        self.mcpURL = mcpURL
        self.prompt = prompt
        self.promptOrigin = promptOrigin
    }

    /// Seeds a new draft once from what was last sent, so a person who always
    /// sends to the same agent does not have to choose it again.
    public init(seededFrom preferences: TranscriptAgentPreferences) {
        let agentID = preferences.lastAgentID
        self.init(
            agentID: agentID,
            model: agentID.map(preferences.lastModel(for:)) ?? "",
            effort: agentID.flatMap(preferences.effort(for:))?.rawValue,
            mcpURL: preferences.mcpURL
        )
    }
}

/// Why a recording stopped. Anything other than `user` is an interruption,
/// which later phases use to hold a queued send for confirmation.
public enum MeetingStopReason: String, Codable, Sendable, Equatable, CaseIterable {
    case user
    case microphoneDisconnected
    case selectedApplicationExited
    case streamFailure
    case sleep
    case permissionRevoked
    case lowFreeSpace
    /// Found by launch reconciliation: the app ended while this was recording.
    case interrupted

    /// Maps the recorder's journal wording (`RecordingStopReason.journalReason`),
    /// which is the only stop vocabulary both modules can see.
    public init(journalReason: String) {
        switch journalReason {
        case "user-requested": self = .user
        case "microphone-disconnected": self = .microphoneDisconnected
        case "selected-application-exited": self = .selectedApplicationExited
        case "unrecoverable-stream-error": self = .streamFailure
        case "system-sleep": self = .sleep
        case "permission-revoked": self = .permissionRevoked
        case "low-free-space": self = .lowFreeSpace
        default: self = .interrupted
        }
    }

    public var isPersonRequested: Bool { self == .user }

    /// Shown on the row when the recording did not end because someone
    /// pressed Stop.
    public var interruptionDescription: String? {
        switch self {
        case .user: nil
        case .microphoneDisconnected: "Stopped when the microphone was disconnected"
        case .selectedApplicationExited: "Stopped when the meeting app quit"
        case .streamFailure: "Stopped by a capture error"
        case .sleep: "Stopped when the Mac went to sleep"
        case .permissionRevoked: "Stopped when recording permission was removed"
        case .lowFreeSpace: "Stopped because the disk was nearly full"
        case .interrupted: "Interrupted when Scribe quit unexpectedly"
        }
    }
}

/// Why a draft has nothing left to transcribe.
public enum MeetingOrphanReason: String, Codable, Sendable, Equatable {
    /// No raw recording, handoff request or transcription job survives.
    case recordingMissing

    public var explanation: String {
        switch self {
        case .recordingMissing:
            "The recording for these notes could not be found, so there is nothing to transcribe. The notes are kept until you delete the draft."
        }
    }
}

/// Where a meeting draft is in its life, from capture to a finished run.
public enum MeetingDraftPhase: Codable, Sendable, Equatable {
    case recording
    case awaitingTranscription(MeetingStopReason)
    case queued(runID: UUID)
    case attached(meetingKey: String, runID: UUID)
    case orphaned(MeetingOrphanReason)

    public var runID: UUID? {
        switch self {
        case .queued(let runID), .attached(_, let runID): runID
        case .recording, .awaitingTranscription, .orphaned: nil
        }
    }

    public var isAttached: Bool {
        if case .attached = self { return true }
        return false
    }

    /// True until a run exists: the draft is shown as a placeholder row.
    public var isPlaceholder: Bool {
        switch self {
        case .recording, .awaitingTranscription, .orphaned: true
        case .queued, .attached: false
        }
    }
}

/// Why a queued send waits for the person instead of firing (decision 7).
public enum MeetingSendHoldReason: String, Codable, Sendable, Equatable {
    /// The recording ended some other way than the person stopping it.
    case interrupted
    /// The meeting was picked up again after Scribe was relaunched.
    case recovered
    /// The send was queued longer ago than `QueuedHandoffRunner.queuedSendReconfirmAfter`.
    case stale

    /// Why the tray asks before sending.
    public var explanation: String {
        switch self {
        case .interrupted: "The recording didn\u{2019}t end normally, so Scribe is checking with you before sending."
        case .recovered: "Scribe was relaunched since this was queued, so it is checking with you before sending."
        case .stale: "This was queued more than four hours ago, so Scribe is checking with you before sending."
        }
    }
}

/// Exactly what a claimed send hands the agent, fixed at the moment it was
/// claimed (decision 6). A retry of the same send uses it unchanged, so Latch
/// sees the same request under the same ID. Private to the draft record.
public struct MeetingSendSnapshot: Codable, Sendable, Equatable {
    /// The run whose transcript is sent.
    public var runID: UUID
    public var agentID: String
    public var agentName: String
    /// The command the agent runs as, shown as the session's label.
    public var agentCommandLabel: String
    public var model: String?
    public var effort: String?
    /// Nil for "No folder".
    public var folderID: String?
    public var folderPath: String?
    public var folderName: String?
    public var mcpURL: String?
    public var instruction: String
    public var notes: [MeetingNote]

    public init(
        runID: UUID,
        agentID: String,
        agentName: String,
        agentCommandLabel: String,
        model: String?,
        effort: String?,
        folderID: String?,
        folderPath: String?,
        folderName: String?,
        mcpURL: String?,
        instruction: String,
        notes: [MeetingNote]
    ) {
        self.runID = runID
        self.agentID = agentID
        self.agentName = agentName
        self.agentCommandLabel = agentCommandLabel
        self.model = model
        self.effort = effort
        self.folderID = folderID
        self.folderPath = folderPath
        self.folderName = folderName
        self.mcpURL = mcpURL
        self.instruction = instruction
        self.notes = notes
    }

    /// "Claude Code in tough-leaf".
    public var destination: String {
        agentName + (folderName.map { " in \($0)" } ?? "")
    }
}

/// The send intent attached to a draft: "Send after processing" and what
/// became of it. Each intent has its own operation ID, which is also the
/// request ID Latch is given, so a retry after a crash can never start a
/// second agent.
public enum MeetingSend: Codable, Sendable, Equatable {
    case notQueued
    /// Waiting for the transcript. Settings stay editable (decision 6).
    case queued(operationID: UUID, queuedAt: Date)
    /// Ready, but waiting for the person to confirm (decision 7).
    case held(operationID: UUID, reason: MeetingSendHoldReason, queuedAt: Date)
    /// Committed: the snapshot is on disk and Latch has been, or is being,
    /// asked. A crash here is answered by re-issuing the same request.
    case claimed(operationID: UUID, snapshot: MeetingSendSnapshot, claimedAt: Date)
    case sent(operationID: UUID, latchSessionID: String, sessionName: String?, destination: String, at: Date)
    /// `definite`: nothing was started. Otherwise Scribe could not tell
    /// whether Latch started the session; `retry` is the snapshot a "Try
    /// again" re-issues under the same operation ID.
    case failed(operationID: UUID?, message: String, definite: Bool, retry: MeetingSendSnapshot?)

    /// True while a send is queued, held, claimed or has an outcome that is
    /// not yet known. Combining is refused then (decision 12): the send must
    /// be finished or cancelled first.
    public var blocksCombine: Bool {
        switch self {
        case .queued, .held, .claimed: true
        case .failed(_, _, let definite, _): !definite
        case .notQueued, .sent: false
        }
    }

    public var operationID: UUID? {
        switch self {
        case .notQueued: nil
        case .queued(let id, _), .held(let id, _, _), .claimed(let id, _, _), .sent(let id, _, _, _, _): id
        case .failed(let id, _, _, _): id
        }
    }

    /// Queued or held: the person can still cancel it.
    public var isCancellable: Bool {
        switch self {
        case .queued, .held: true
        default: false
        }
    }
}

/// Everything Scribe keeps about one recording before, and alongside, its
/// transcript: the person's title, notes, handoff settings and lifecycle.
///
/// Stored as one JSON file per draft under Application Support, never inside
/// the recorder's session directory, which is removed once transcription has
/// its own copy of the audio.
public struct MeetingDraft: Codable, Sendable, Equatable, Identifiable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: UUID
    public let recorderSessionID: UUID
    public let createdAt: Date
    /// Incremented on every change. A write carrying an older revision is
    /// rejected rather than allowed to overwrite a newer edit.
    public var revision: Int
    /// The person's own title. Nil means the default applies.
    public var title: String?
    /// The calendar event's name, else the session's dated name.
    public var defaultTitle: String
    public var notes: [MeetingNote]
    public var handoff: MeetingHandoffSettings
    public var phase: MeetingDraftPhase
    /// Set when launch reconciliation adopted this draft after a relaunch.
    public var recovered: Bool
    public var send: MeetingSend
    /// Why finishing the recording failed, when it did. Shown on the row.
    public var captureFailure: String?
    /// How the recording ended, kept after the phase moves on so a queued
    /// send can be held for an interrupted recording. Nil for drafts made
    /// before it was recorded.
    public var stopReason: MeetingStopReason?

    public init(
        id: UUID = UUID(),
        recorderSessionID: UUID,
        createdAt: Date = Date(),
        revision: Int = 1,
        title: String? = nil,
        defaultTitle: String,
        notes: [MeetingNote] = [],
        handoff: MeetingHandoffSettings = MeetingHandoffSettings(),
        phase: MeetingDraftPhase = .recording,
        recovered: Bool = false,
        send: MeetingSend = .notQueued,
        captureFailure: String? = nil,
        stopReason: MeetingStopReason? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.recorderSessionID = recorderSessionID
        self.createdAt = createdAt
        self.revision = revision
        self.title = title
        self.defaultTitle = defaultTitle
        self.notes = notes
        self.handoff = handoff
        self.phase = phase
        self.recovered = recovered
        self.send = send
        self.captureFailure = captureFailure
        self.stopReason = stopReason
    }

    /// The title the transcript should carry: the person's, else the default.
    public var effectiveTitle: String { title ?? defaultTitle }
}

/// Whether the draft's latest edit is on disk.
public enum MeetingDraftSaveState: Sendable, Equatable {
    case saved
    /// The last write failed; the edit is kept in memory and can be retried.
    case notSaved(message: String)

    public var isSaved: Bool { self == .saved }
}
