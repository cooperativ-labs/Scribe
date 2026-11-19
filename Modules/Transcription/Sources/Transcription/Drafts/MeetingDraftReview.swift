import Foundation
import ScribeAppCore

/// What review needs to know about a row's meeting draft. Prompt, MCP URL and
/// the rest of the handoff settings are deliberately absent.
public struct MeetingDraftSummary: Equatable, Sendable {
    public let id: UUID
    public let revision: Int
    public let title: String?
    public let defaultTitle: String
    public let noteCount: Int
    public let phase: MeetingDraftPhase
    public let recovered: Bool
    public let saveState: MeetingDraftSaveState
    /// The second line a placeholder row shows, such as "Processing audio".
    public let status: String
    /// A longer explanation for the detail pane, when there is one.
    public let explanation: String?
    /// A finished recording that was not handed to transcription (the
    /// setting is off) can be sent now.
    public let canTranscribeNow: Bool
    /// A send to an agent is queued, held, claimed or of unknown outcome, so
    /// the meeting cannot be combined until it is resolved.
    public let sendBlocksCombine: Bool
    /// The queued send and what became of it, for the tray.
    public let send: MeetingSend

    public init(
        id: UUID,
        revision: Int,
        title: String?,
        defaultTitle: String,
        noteCount: Int = 0,
        phase: MeetingDraftPhase,
        recovered: Bool = false,
        saveState: MeetingDraftSaveState = .saved,
        status: String,
        explanation: String? = nil,
        canTranscribeNow: Bool = false,
        sendBlocksCombine: Bool = false,
        send: MeetingSend = .notQueued
    ) {
        self.id = id
        self.revision = revision
        self.title = title
        self.defaultTitle = defaultTitle
        self.noteCount = noteCount
        self.phase = phase
        self.recovered = recovered
        self.saveState = saveState
        self.status = status
        self.explanation = explanation
        self.canTranscribeNow = canTranscribeNow
        self.sendBlocksCombine = sendBlocksCombine
        self.send = send
    }

    /// Only drafts without a run can be deleted as drafts; a draft with a run
    /// is deleted with its transcript.
    public var canDeleteDraft: Bool { phase.isPlaceholder && phase != .recording }

    public var isOrphaned: Bool {
        if case .orphaned = phase { return true }
        return false
    }

    /// "4 notes", or nil with none.
    public var noteCountText: String? {
        noteCount == 0 ? nil : "\(noteCount) note\(noteCount == 1 ? "" : "s")"
    }
}

/// The recording in progress, as review shows it.
public struct LiveCaptureState: Equatable, Sendable {
    public let sessionID: UUID
    public let startedAt: Date
    public var isPaused: Bool

    public init(sessionID: UUID, startedAt: Date, isPaused: Bool = false) {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.isPaused = isPaused
    }
}

/// Merges meeting drafts into the transcript list.
///
/// Every draft is one row keyed by its draft ID, from the moment recording
/// starts to long after its transcript is finished, so selection never jumps
/// as the meeting moves from placeholder to queued to complete, or across a
/// relaunch. Runs that belong to no draft keep today's one-row-per-meeting
/// presentation. The live recording is pinned first.
public enum MeetingDraftReviewMerger {
    public struct Environment: Sendable {
        public var live: LiveCaptureState?
        public var sessions: [UUID: RecorderSessionEvidence]
        public var pendingRequests: [TranscriptionRequest]
        public var autoTranscribe: Bool
        /// Why queued transcription is not running, such as a missing model.
        public var transcriptionBlockedReason: String?
        /// Notes each draft's row shows, where they are no longer in the
        /// draft record (after transcription they live with the meeting).
        public var noteCounts: [UUID: Int]
        /// Agents' display names by ID, for "sends to Claude Code".
        public var agentNames: [String: String]

        public init(
            live: LiveCaptureState? = nil,
            sessions: [UUID: RecorderSessionEvidence] = [:],
            pendingRequests: [TranscriptionRequest] = [],
            autoTranscribe: Bool = true,
            transcriptionBlockedReason: String? = nil,
            noteCounts: [UUID: Int] = [:],
            agentNames: [String: String] = [:]
        ) {
            self.live = live
            self.sessions = sessions
            self.pendingRequests = pendingRequests
            self.autoTranscribe = autoTranscribe
            self.transcriptionBlockedReason = transcriptionBlockedReason
            self.noteCounts = noteCounts
            self.agentNames = agentNames
        }
    }

    public static func files(
        drafts: [MeetingDraft],
        saveStates: [UUID: MeetingDraftSaveState] = [:],
        runs: [StoredTranscriptRun],
        environment: Environment = Environment()
    ) -> [TranscriptReviewFile] {
        var claimedRunIDs = Set<UUID>()
        var draftRows: [(file: TranscriptReviewFile, sortDate: Date)] = []
        for draft in drafts {
            let owned = MeetingDraftReconciler.runs(for: draft, in: runs)
            claimedRunIDs.formUnion(owned.map(\.job.runID))
            let displayed = MeetingDraftReconciler.displayedRun(for: draft, in: runs)
            let summary = self.summary(
                for: draft,
                saveState: saveStates[draft.id] ?? .saved,
                run: displayed,
                environment: environment
            )
            if let displayed {
                draftRows.append((TranscriptReviewFile(displayed, draft: summary), displayed.job.createdAt))
            } else {
                draftRows.append((placeholder(for: draft, summary: summary, environment: environment), draft.createdAt))
            }
        }

        // Runs outside any draft: newest completed transcript per meeting,
        // exactly as before drafts existed.
        let unowned = Dictionary(grouping: runs.filter { !claimedRunIDs.contains($0.job.runID) }) {
            $0.job.meetingDirectoryURL.standardizedFileURL
        }
        let storeRows: [(file: TranscriptReviewFile, sortDate: Date)] = unowned.values.compactMap { meetingRuns in
            let run = meetingRuns.filter { $0.transcript != nil }.max { $0.job.createdAt < $1.job.createdAt }
                ?? meetingRuns.max { $0.job.createdAt < $1.job.createdAt }
            return run.map { (TranscriptReviewFile($0), $0.job.createdAt) }
        }

        let liveDraftID = environment.live.flatMap { live in drafts.first { $0.recorderSessionID == live.sessionID }?.id }
        return (draftRows + storeRows)
            .sorted { lhs, rhs in
                let leftLive = lhs.file.draft?.id == liveDraftID && liveDraftID != nil
                let rightLive = rhs.file.draft?.id == liveDraftID && liveDraftID != nil
                if leftLive != rightLive { return leftLive }
                if lhs.sortDate != rhs.sortDate { return lhs.sortDate > rhs.sortDate }
                return lhs.file.id < rhs.file.id
            }
            .map(\.file)
    }

    private static func placeholder(
        for draft: MeetingDraft,
        summary: MeetingDraftSummary,
        environment: Environment
    ) -> TranscriptReviewFile {
        let jobState: TranscriptJobState
        if case .recording = draft.phase, let live = environment.live, live.sessionID == draft.recorderSessionID {
            jobState = .recording(startedAt: live.startedAt, isPaused: live.isPaused)
        } else if environment.pendingRequests.contains(where: { $0.draftID == draft.id }) {
            jobState = .queued
        } else {
            jobState = .ready
        }
        let session = environment.sessions[draft.recorderSessionID]
        return TranscriptReviewFile(
            id: draft.id.uuidString,
            runID: nil,
            sourceSnapshotURL: session?.directoryURL ?? URL(fileURLWithPath: "/dev/null"),
            transcript: nil,
            jobState: jobState,
            hasAudio: false,
            draft: summary
        )
    }

    /// The row's draft facts and the words that describe its state.
    public static func summary(
        for draft: MeetingDraft,
        saveState: MeetingDraftSaveState,
        run: StoredTranscriptRun?,
        environment: Environment
    ) -> MeetingDraftSummary {
        let session = environment.sessions[draft.recorderSessionID]
        var status: String
        var explanation: String?
        var canTranscribeNow = false
        switch draft.phase {
        case .recording:
            status = "Recording"
            if environment.live?.sessionID != draft.recorderSessionID {
                status = "Recording ended unexpectedly"
            }
        case .awaitingTranscription(let reason):
            explanation = reason.interruptionDescription
            if let failure = draft.captureFailure {
                status = "Recording could not be finished"
                explanation = failure
            } else if environment.pendingRequests.contains(where: {
                $0.draftID == draft.id || $0.requestID == TranscriptionRequest.recorderRequestID(forSession: draft.recorderSessionID)
            }) {
                status = environment.transcriptionBlockedReason ?? "Waiting to transcribe"
            } else if let session {
                switch session.processingState {
                case .pending, .running:
                    status = "Processing audio"
                case .failed:
                    status = "Audio cleanup failed"
                    explanation = [session.processingFailure, "The original tracks were kept in the recordings folder."]
                        .compactMap { $0 }.joined(separator: " ")
                case .complete where session.hasFinalMix:
                    if environment.autoTranscribe {
                        status = "Waiting to transcribe"
                    } else {
                        status = "Not transcribed"
                        explanation = "\u{201C}Transcribe when the final recording is ready\u{201D} is off in Settings."
                        canTranscribeNow = true
                    }
                case .complete:
                    status = "Final recording missing"
                }
            } else {
                status = "Waiting to transcribe"
            }
        case .queued:
            status = environment.transcriptionBlockedReason ?? "Transcribing"
        case .attached:
            status = "Transcribed"
        case .orphaned(let reason):
            status = "Notes only"
            explanation = reason.explanation
        }
        if draft.recovered, case .awaitingTranscription = draft.phase, explanation == nil {
            explanation = "Recovered after Scribe was relaunched."
        }
        // The queued send is part of the row's state, so a person who denied
        // notifications still sees what happened to it.
        let agentName = draft.handoff.agentID.map { environment.agentNames[$0] ?? $0 } ?? "the agent"
        switch draft.send {
        case .notQueued:
            break
        case .queued:
            status = !draft.phase.isAttached
                ? "\(status) \u{00B7} sends to \(agentName)"
                : "Will send to \(agentName)"
        case .held(_, let reason, _):
            status = "Ready to send \u{2014} confirm"
            explanation = reason.explanation
        case .claimed(_, let snapshot, _):
            status = "Sending to \(snapshot.agentName)"
        case .sent(_, _, _, let destination, _):
            status = "Sent to \(destination)"
        case .failed(_, let message, let definite, _):
            status = definite ? "Couldn\u{2019}t send to agent" : "Send not confirmed"
            explanation = message
        }
        if case .notSaved = saveState { status = "Not saved" }
        return MeetingDraftSummary(
            id: draft.id,
            revision: draft.revision,
            title: draft.title,
            defaultTitle: draft.defaultTitle,
            noteCount: environment.noteCounts[draft.id] ?? draft.notes.count,
            phase: draft.phase,
            recovered: draft.recovered,
            saveState: saveState,
            status: status,
            explanation: explanation,
            canTranscribeNow: canTranscribeNow,
            sendBlocksCombine: draft.send.blocksCombine,
            send: draft.send
        )
    }
}

public extension TranscriptReviewFile {
    /// A stored run shown as a meeting draft's row: keyed by the draft, run
    /// operations still addressed to the run.
    init(_ run: StoredTranscriptRun, draft: MeetingDraftSummary) {
        let plain = TranscriptReviewFile(run)
        self.init(
            id: draft.id.uuidString,
            runID: run.job.runID.uuidString,
            sourceSnapshotURL: plain.sourceSnapshotURL,
            transcript: plain.transcript,
            jobState: plain.jobState,
            processingError: plain.processingError,
            hasAudio: plain.hasAudio,
            suggestions: plain.suggestions,
            draft: draft
        )
    }
}

/// Edits a meeting draft named by ID. Review never edits "the selected
/// draft": every call carries the draft it was made for, captured before any
/// await, so a selection change while a write is in flight cannot redirect it.
@MainActor
public protocol MeetingDraftEditing: AnyObject {
    /// Sets or clears the person's title. `basedOnRevision` and
    /// `previousTitle` are what the caller saw; a title changed by someone
    /// else since then is a conflict, an unrelated change is not.
    func setTitle(draftID: UUID, title: String?, basedOnRevision: Int, previousTitle: String?) async throws -> MeetingDraftSummary?
    /// Tries the failed write again; returns the refreshed summary.
    func retrySave(draftID: UUID) async -> MeetingDraftSummary?
    func deleteDraft(draftID: UUID) async throws
    /// Publishes a finished recording that was not handed off automatically.
    /// Returns a failure message, or nil on success.
    func transcribeNow(draftID: UUID) async -> String?

    /// The notes the draft's row shows, wherever they are kept now.
    func notes(draftID: UUID) -> MeetingNotesContent
    /// The notes an export of the draft's row carries: what the row shows,
    /// each attributed to the draft it was written in. Never the prompt,
    /// MCP URL or send state.
    func exportNotes(draftID: UUID) -> Result<[TranscriptExportNote], MeetingNotesExportError>
    /// Replaces the draft's notes. Applied at once, written shortly after.
    func setNotes(draftID: UUID, notes: [MeetingNote])
    /// Writes the draft's pending notes edit now.
    func flushNotes(draftID: UUID) async
    /// The recording time a note written now in this draft gets, or nil.
    func noteClock(draftID: UUID) -> Int?
    /// Readies drafts for combining; returns why it must wait, or nil.
    func prepareForCombine(draftIDs: [UUID]) async -> String?
    /// Records that two meetings were combined into the owner's row.
    func finishCombine(ownerDraftID: UUID?, absorbedDraftIDs: [UUID]) async

    /// The agent handoff this draft's tray shows, or nil for a draft that no
    /// longer exists. Private to the draft: never exported or relayed.
    func handoffSettings(draftID: UUID) -> MeetingHandoffSettings?
    /// Replaces the draft's handoff settings. Applied at once, written
    /// shortly after, like notes.
    func setHandoffSettings(draftID: UUID, _ settings: MeetingHandoffSettings)
    /// An edit made to the draft that is not on disk yet, or whose write
    /// failed. Writes still waiting for the store's own quiet period count
    /// as saved here; `flushNotes` writes those.
    func hasUnsavedEdits(draftID: UUID) -> Bool
}

public extension MeetingDraftEditing {
    func hasUnsavedEdits(draftID: UUID) -> Bool { false }

    /// Every note attributed to the row's own draft, for editors that keep
    /// no combined meetings.
    func exportNotes(draftID: UUID) -> Result<[TranscriptExportNote], MeetingNotesExportError> {
        switch notes(draftID: draftID) {
        case .editable(let notes): .success(notes.map { TranscriptExportNote($0, draftID: draftID) })
        case .unavailable(let message): .failure(MeetingNotesExportError(message: message))
        }
    }
}

/// The meeting's notes could not be read for an export.
public struct MeetingNotesExportError: Error, Equatable, Sendable {
    public let message: String
    public init(message: String) { self.message = message }
}

/// A draft's notes as the editor gets them.
public enum MeetingNotesContent: Equatable, Sendable {
    case editable([MeetingNote])
    /// The notes exist but cannot be read; editing is refused so nothing
    /// overwrites them.
    case unavailable(String)

    public var notes: [MeetingNote] {
        if case .editable(let notes) = self { return notes }
        return []
    }
}
