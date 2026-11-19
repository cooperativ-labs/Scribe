import Foundation
import ScribeAppCore

/// What the recordings folder says about one recorder session.
public struct RecorderSessionEvidence: Sendable, Equatable {
    public let sessionID: UUID
    public let directoryURL: URL
    public let captureState: CaptureState
    public let processingState: ProcessingState
    /// Processing finished and described a final mix that is on disk.
    public let hasFinalMix: Bool
    /// The calendar title the session was started with, if any.
    public let title: String?
    /// The reason processing gave up, when it did.
    public let processingFailure: String?

    public init(
        sessionID: UUID,
        directoryURL: URL,
        captureState: CaptureState,
        processingState: ProcessingState,
        hasFinalMix: Bool,
        title: String? = nil,
        processingFailure: String? = nil
    ) {
        self.sessionID = sessionID
        self.directoryURL = directoryURL
        self.captureState = captureState
        self.processingState = processingState
        self.hasFinalMix = hasFinalMix
        self.title = title
        self.processingFailure = processingFailure
    }

    /// Reads every session manifest directly inside the recordings folder.
    /// Unreadable manifests are skipped: they are evidence of nothing.
    public static func scan(recordingsDirectory: URL, fileManager: FileManager = .default) -> [UUID: RecorderSessionEvidence] {
        let directories = (try? fileManager.contentsOfDirectory(
            at: recordingsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var evidence: [UUID: RecorderSessionEvidence] = [:]
        for directory in directories {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("metadata.json")),
                  let manifest = try? RecorderSessionManifestCodec.decode(data) else { continue }
            let finalMix = manifest.tracks.finalTrack.map { directory.appendingPathComponent($0.fileName) }
            evidence[manifest.sessionID] = RecorderSessionEvidence(
                sessionID: manifest.sessionID,
                directoryURL: directory,
                captureState: manifest.capture.state,
                processingState: manifest.processing.state,
                hasFinalMix: manifest.processing.state == .complete
                    && finalMix.map { fileManager.fileExists(atPath: $0.path) } == true,
                title: manifest.title,
                processingFailure: manifest.processing.state == .failed
                    ? (manifest.processing.errors.last?.message ?? "Audio cleanup failed.")
                    : nil
            )
        }
        return evidence
    }
}

/// The durable facts reconciliation joins: session manifests, outbox
/// requests, job records (with their transcripts) and draft records.
public struct MeetingDraftReconciliationInput: Sendable {
    public var drafts: [MeetingDraft]
    /// The session being captured right now; its draft is not interrupted.
    public var liveSessionID: UUID?
    public var sessions: [UUID: RecorderSessionEvidence]
    public var pendingRequests: [TranscriptionRequest]
    public var runs: [StoredTranscriptRun]
    /// Whether a finished recording is handed to transcription on its own.
    public var autoTranscribe: Bool
    /// True on the pass made at launch: anything adopted is marked recovered.
    public var isLaunch: Bool

    public init(
        drafts: [MeetingDraft],
        liveSessionID: UUID? = nil,
        sessions: [UUID: RecorderSessionEvidence] = [:],
        pendingRequests: [TranscriptionRequest] = [],
        runs: [StoredTranscriptRun] = [],
        autoTranscribe: Bool = true,
        isLaunch: Bool = false
    ) {
        self.drafts = drafts
        self.liveSessionID = liveSessionID
        self.sessions = sessions
        self.pendingRequests = pendingRequests
        self.runs = runs
        self.autoTranscribe = autoTranscribe
        self.isLaunch = isLaunch
    }
}

/// One step reconciliation wants taken. Draft changes are applied by
/// `MeetingDraftLifecycle`; publishing a handoff is the host's.
public enum MeetingDraftReconciliationAction: Sendable, Equatable {
    /// A draft still marked recording whose capture is not running: the app
    /// ended mid-recording and the session was repaired.
    case markInterrupted(draftID: UUID)
    /// The recording finished processing but no handoff request or job
    /// exists (a crash between the mix and the outbox write).
    case publishHandoff(draftID: UUID, sessionDirectory: URL)
    /// A run exists for a draft that has not recorded it.
    case bindQueued(draftID: UUID, runID: UUID, recovered: Bool)
    /// The draft's run reached a terminal state, or an attached draft still
    /// holds notes that belong in its meeting's `meeting-notes.json`.
    case attach(draftID: UUID, runID: UUID, meetingKey: String, recovered: Bool)
    /// The person's title differs from the one in the displayed transcript.
    case applyTitle(draftID: UUID, runID: UUID, title: String?)
    /// Nothing usable survives for this draft.
    case orphan(draftID: UUID, reason: MeetingOrphanReason)
    /// An orphaned draft whose recording has reappeared (for example, the
    /// recordings folder was changed back).
    case restore(draftID: UUID)
}

/// Joins the durable stores and says what must change so every draft agrees
/// with them. Pure: the same input always gives the same actions, which is
/// what lets launch and every state change run the same pass.
public enum MeetingDraftReconciler {
    public static func actions(for input: MeetingDraftReconciliationInput) -> [MeetingDraftReconciliationAction] {
        var actions: [MeetingDraftReconciliationAction] = []
        for draft in input.drafts {
            actions += self.actions(for: draft, input: input)
        }
        return actions
    }

    /// The runs that belong to a draft: those carrying its ID, and the one
    /// made from the session's deterministic request ID when a request was
    /// published without the draft ID (a lookup that failed at handoff).
    public static func runs(for draft: MeetingDraft, in runs: [StoredTranscriptRun]) -> [StoredTranscriptRun] {
        let requestID = TranscriptionRequest.recorderRequestID(forSession: draft.recorderSessionID)
        return runs.filter { run in
            if let draftID = run.job.draftID { return draftID == draft.id }
            return run.job.request.requestID == requestID
        }
    }

    /// The run a draft's lifecycle follows: the one its handoff created.
    /// Reruns carry the draft ID too, but they never re-open the lifecycle.
    public static func handoffRun(for draft: MeetingDraft, in runs: [StoredTranscriptRun]) -> StoredTranscriptRun? {
        let owned = self.runs(for: draft, in: runs)
        let requestID = TranscriptionRequest.recorderRequestID(forSession: draft.recorderSessionID)
        if let bound = draft.phase.runID, let run = owned.first(where: { $0.job.runID == bound }) { return run }
        return owned.filter { $0.job.request.requestID == requestID }.min { $0.job.createdAt < $1.job.createdAt }
            ?? owned.filter { $0.job.retryOfRunID == nil }.min { $0.job.createdAt < $1.job.createdAt }
    }

    /// The run review shows for a draft: the newest with a transcript, else
    /// the newest.
    public static func displayedRun(for draft: MeetingDraft, in runs: [StoredTranscriptRun]) -> StoredTranscriptRun? {
        let owned = self.runs(for: draft, in: runs)
        let depths = rerunDepths(owned)
        let isOlder = { (lhs: StoredTranscriptRun, rhs: StoredTranscriptRun) -> Bool in
            Self.isOlder(lhs, rhs, depths: depths)
        }
        return owned.filter { $0.transcript != nil }.max(by: isOlder) ?? owned.max(by: isOlder)
    }

    /// Job dates are stored to the second, so reruns made in the same second
    /// as their predecessors tie on `createdAt`; the run further down the
    /// rerun chain is the newer. A total order, so `max` gives the same
    /// answer whatever order the store lists the runs in.
    private static func isOlder(_ lhs: StoredTranscriptRun, _ rhs: StoredTranscriptRun, depths: [UUID: Int]) -> Bool {
        if lhs.job.createdAt != rhs.job.createdAt { return lhs.job.createdAt < rhs.job.createdAt }
        let lhsDepth = depths[lhs.job.runID] ?? 0
        let rhsDepth = depths[rhs.job.runID] ?? 0
        if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
        return lhs.job.runID.uuidString < rhs.job.runID.uuidString
    }

    /// How many reruns separate each run from the first run of its chain,
    /// counting only runs in `runs` (and stopping at a cycle).
    private static func rerunDepths(_ runs: [StoredTranscriptRun]) -> [UUID: Int] {
        let parents = Dictionary(runs.map { ($0.job.runID, $0.job.retryOfRunID) }, uniquingKeysWith: { first, _ in first })
        var depths: [UUID: Int] = [:]
        for run in runs {
            var depth = 0
            var seen: Set<UUID> = [run.job.runID]
            var current = run.job.retryOfRunID
            while let parent = current, parents.keys.contains(parent), seen.insert(parent).inserted {
                depth += 1
                current = parents[parent] ?? nil
            }
            depths[run.job.runID] = depth
        }
        return depths
    }

    private static func actions(for draft: MeetingDraft, input: MeetingDraftReconciliationInput) -> [MeetingDraftReconciliationAction] {
        var actions: [MeetingDraftReconciliationAction] = []
        var phase = draft.phase
        let isLive = draft.recorderSessionID == input.liveSessionID

        if case .recording = phase, !isLive {
            actions.append(.markInterrupted(draftID: draft.id))
            phase = .awaitingTranscription(.interrupted)
        }
        if case .recording = phase { return actions }

        if let run = handoffRun(for: draft, in: input.runs) {
            let meetingKey = run.job.meetingDirectoryURL.lastPathComponent
            if run.job.state.isTerminal {
                // Notes still in an attached draft are a half-done
                // attachment (or an edit that raced it): attach again, which
                // moves them into the meeting's notes.
                if phase != .attached(meetingKey: meetingKey, runID: run.job.runID) || !draft.notes.isEmpty {
                    actions.append(.attach(draftID: draft.id, runID: run.job.runID, meetingKey: meetingKey, recovered: input.isLaunch))
                }
            } else if phase != .queued(runID: run.job.runID) {
                if case .orphaned = phase { actions.append(.restore(draftID: draft.id)) }
                actions.append(.bindQueued(draftID: draft.id, runID: run.job.runID, recovered: input.isLaunch))
            }
            if let displayed = displayedRun(for: draft, in: input.runs),
               displayed.job.state.isTerminal,
               let transcript = displayed.transcript,
               let title = draft.title,
               transcript.title != title {
                actions.append(.applyTitle(draftID: draft.id, runID: displayed.job.runID, title: title))
            }
            return actions
        }

        let requestID = TranscriptionRequest.recorderRequestID(forSession: draft.recorderSessionID)
        let hasRequest = input.pendingRequests.contains { $0.draftID == draft.id || $0.requestID == requestID }
        let session = input.sessions[draft.recorderSessionID]

        if hasRequest || session != nil {
            if case .orphaned = phase { actions.append(.restore(draftID: draft.id)) }
            // A request on file is the consumer's to queue; its ID is
            // deterministic, so it cannot become a second run.
            if !hasRequest, let session, session.hasFinalMix, input.autoTranscribe {
                actions.append(.publishHandoff(draftID: draft.id, sessionDirectory: session.directoryURL))
            }
            return actions
        }

        if case .orphaned = phase { return actions }
        actions.append(.orphan(draftID: draft.id, reason: .recordingMissing))
        return actions
    }
}
