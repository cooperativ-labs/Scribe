import Foundation
import os

/// Something the person is told about a queued send, outside the window.
public enum QueuedHandoffNotice: Equatable, Sendable {
    /// The agent was started. Carries the session so the notification can
    /// offer "Open".
    case sent(draftID: UUID, operationID: UUID, meetingTitle: String, destination: String, latchSessionID: String)
    /// Ready, but waiting for the person: the notification offers Send and
    /// Cancel.
    case held(draftID: UUID, operationID: UUID, meetingTitle: String, destination: String, reason: MeetingSendHoldReason)
    case failed(draftID: UUID, operationID: UUID?, meetingTitle: String, message: String)
}

/// Posts notices about queued sends. A notification that cannot be shown
/// (permission denied, say) changes nothing: the tray and the row are the
/// record of every send.
@MainActor
public protocol QueuedHandoffNotifying: AnyObject {
    /// Asks for permission to notify, when the person first queues a send.
    func prepare()
    func post(_ notice: QueuedHandoffNotice)
}

/// What the tray and the notifications ask a queued send to do.
@MainActor
public protocol MeetingSendControlling: AnyObject {
    /// "Send after processing". Returns why it could not be queued, or nil.
    func queueSend(draftID: UUID) async -> String?
    /// Cancels a queued or held send. Returns why it could not be
    /// cancelled (it was already claimed), or nil.
    func cancelSend(draftID: UUID, operationID: UUID?) async -> String?
    /// Sends a held send now. `interactive` brings Latch forward.
    func confirmSend(draftID: UUID, operationID: UUID?, interactive: Bool) async
    /// Re-issues a send whose outcome is unknown, under the same operation
    /// ID and with the same snapshot.
    func retrySend(draftID: UUID) async
    /// Forgets a finished send's outcome: before the person sends again by
    /// hand, so the tray shows the new send rather than the old one, or when
    /// they dismiss a send whose outcome is unknown.
    func clearSendOutcome(draftID: UUID) async
}

/// Fires "Send after processing" when a meeting's transcript is ready.
///
/// Owned by the host and driven by reconciliation, never by the window, so a
/// send fires with the Transcripts window closed and survives a relaunch.
/// Every transition is written to the draft record before anything that
/// depends on it: a claim (with its immutable snapshot) is on disk before
/// Latch is asked, and Latch is given the operation ID as its request ID, so
/// re-issuing a claim whose outcome was lost returns the session the first
/// attempt started instead of starting a second agent (decision 8).
@MainActor
public final class QueuedHandoffRunner: MeetingSendControlling {
    /// A send queued longer ago than this is held for the person to confirm
    /// rather than fired (decision 7).
    public static let queuedSendReconfirmAfter: TimeInterval = 4 * 60 * 60

    private let lifecycle: MeetingDraftLifecycle
    /// Set by the host once its agent service exists.
    public var dispatcher: (any TranscriptAgentDispatching)?
    private let preferences: TranscriptAgentPreferences?
    public weak var notifier: (any QueuedHandoffNotifying)?
    private let reconfirmAfter: TimeInterval
    private let now: @MainActor () -> Date
    /// When this process started. A send queued before it survived a
    /// relaunch, and is held (decision 7).
    private let launchedAt: Date
    /// True while a recording is being captured: background sends wait so
    /// the agent does not compete with it or pop up mid-meeting.
    public var isCaptureActive: @MainActor () -> Bool
    /// The runs reconciliation last saw, for confirming and retrying between
    /// passes. The host supplies the store's current runs.
    public var currentRuns: @MainActor () -> [StoredTranscriptRun] = { [] }
    /// Agents' display names by ID, for notices written without asking the
    /// dispatcher what is installed.
    public var agentNames: [String: String] = [:]

    /// Drafts whose send is being claimed or dispatched in this process.
    /// Checked and set before the first await, so two reconciliation passes
    /// (duplicate completion events) can never both dispatch one send.
    private var inFlight: [UUID: Task<Void, Never>] = [:]
    private static let logger = Logger(subsystem: "com.scribe.app", category: "QueuedHandoff")

    public init(
        lifecycle: MeetingDraftLifecycle,
        dispatcher: (any TranscriptAgentDispatching)?,
        preferences: TranscriptAgentPreferences? = nil,
        notifier: (any QueuedHandoffNotifying)? = nil,
        reconfirmAfter: TimeInterval = QueuedHandoffRunner.queuedSendReconfirmAfter,
        launchedAt: Date = Date(),
        now: @escaping @MainActor () -> Date = { Date() },
        isCaptureActive: @escaping @MainActor () -> Bool = { false }
    ) {
        self.lifecycle = lifecycle
        self.dispatcher = dispatcher
        self.preferences = preferences
        self.notifier = notifier
        self.reconfirmAfter = reconfirmAfter
        self.launchedAt = launchedAt
        self.now = now
        self.isCaptureActive = isCaptureActive
    }

    // MARK: - Reconciliation

    /// Looks at every draft's send and moves the ones that can move: holds
    /// or claims queued sends whose transcript is ready, ends those whose run
    /// produced nothing to send, and re-issues claims a crash interrupted.
    /// Safe to call as often as reconciliation runs.
    public func reconcile(runs: [StoredTranscriptRun]) async {
        for draft in lifecycle.allDrafts {
            switch draft.send {
            case let .queued(operationID, queuedAt):
                await evaluateQueued(draft, operationID: operationID, queuedAt: queuedAt, runs: runs)
            case let .claimed(operationID, snapshot, _):
                guard inFlight[draft.id] == nil, isSaved(draft.id), !isCaptureActive() else { continue }
                // A claim with no dispatch running in this process: the last
                // one ended before its outcome was recorded. Same ID, same
                // snapshot; Latch answers with the session it already made.
                start(draft.id) { runner in
                    await runner.dispatch(draftID: draft.id, operationID: operationID, snapshot: snapshot, runs: runs, delivery: .background)
                }
            case .notQueued, .held, .sent, .failed:
                continue
            }
        }
    }

    /// Waits for any send being dispatched for this draft to record its
    /// outcome. Deleting a meeting waits on this, so a claimed send is
    /// never lost mid-flight.
    public func waitForInFlight(draftID: UUID) async {
        await inFlight[draftID]?.value
    }

    /// Waits for every dispatch under way. Tests use this.
    public func waitForAll() async {
        while let task = inFlight.values.first {
            await task.value
        }
    }

    private func evaluateQueued(_ draft: MeetingDraft, operationID: UUID, queuedAt: Date, runs: [StoredTranscriptRun]) async {
        guard inFlight[draft.id] == nil else { return }
        guard case .attached(_, let runID) = draft.phase,
              let run = runs.first(where: { $0.job.runID == runID }) else { return }
        // The run's outcome as review shows it: "no speech" comes from the
        // transcript's own status, not the job's.
        switch TranscriptJobState(run.job.state, transcript: run.transcript) {
        case .complete, .completeWithWarnings:
            break
        case .noSpeech:
            await fail(draft, operationID: operationID, message: "No speech was found in the recording, so nothing was sent.")
            return
        case .failed where run.job.state == .cancelled:
            await fail(draft, operationID: operationID, message: "Transcription was cancelled, so nothing was sent.")
            return
        case .failed:
            await fail(draft, operationID: operationID, message: "Transcription failed, so nothing was sent. Retranscribe, then send it yourself.")
            return
        case .recording, .ready, .queued, .processing:
            return
        }
        // Title and notes first: the agent gets the meeting as the person
        // left it, not a transcript still being renamed or notes still in
        // the draft record.
        guard eligible(draft, runs: runs) else { return }
        if let reason = holdReason(draft, queuedAt: queuedAt) {
            guard let held = await lifecycle.transitionSend(
                draftID: draft.id,
                to: .held(operationID: operationID, reason: reason, queuedAt: queuedAt),
                when: { $0 == .queued(operationID: operationID, queuedAt: queuedAt) }
            ) else { return }
            notifier?.post(.held(
                draftID: draft.id,
                operationID: operationID,
                meetingTitle: held.effectiveTitle,
                destination: destination(for: held.handoff),
                reason: reason
            ))
            return
        }
        guard !isCaptureActive() else { return }
        start(draft.id) { runner in
            await runner.claim(draftID: draft.id, operationID: operationID, runs: runs, delivery: .background)
        }
    }

    /// Ready to send: the run is finished, the person's title is on the
    /// transcript, the notes have moved into the meeting, and every edit is
    /// on disk.
    private func eligible(_ draft: MeetingDraft, runs: [StoredTranscriptRun]) -> Bool {
        guard draft.notes.isEmpty, isSaved(draft.id) else { return false }
        if let title = draft.title {
            guard let transcript = MeetingDraftReconciler.displayedRun(for: draft, in: runs)?.transcript,
                  transcript.title == title else { return false }
        }
        return true
    }

    private func holdReason(_ draft: MeetingDraft, queuedAt: Date) -> MeetingSendHoldReason? {
        if let reason = draft.stopReason, !reason.isPersonRequested { return .interrupted }
        if queuedAt < launchedAt { return .recovered }
        if now().timeIntervalSince(queuedAt) > reconfirmAfter { return .stale }
        return nil
    }

    private func isSaved(_ draftID: UUID) -> Bool {
        lifecycle.saveStates[draftID]?.isSaved ?? true
    }

    // MARK: - The person's actions

    public func queueSend(draftID: UUID) async -> String? {
        guard dispatcher != nil else { return "Sending to an agent is not available here." }
        guard let draft = lifecycle.drafts[draftID] else { return MeetingDraftLifecycle.LifecycleError.unknownDraft.errorDescription }
        if case .orphaned = draft.phase { return "There is no recording left to transcribe, so there is nothing to send." }
        let queued = MeetingSend.queued(operationID: UUID(), queuedAt: now())
        guard await lifecycle.transitionSend(draftID: draftID, to: queued, when: Self.canQueue) != nil else {
            return lifecycle.saveStates[draftID]?.isSaved == false
                ? "The send could not be saved. Try again."
                : "A send for this meeting is already under way."
        }
        notifier?.prepare()
        // The transcript may already be ready.
        await reconcile(runs: currentRuns())
        return nil
    }

    public func cancelSend(draftID: UUID, operationID: UUID?) async -> String? {
        let cancelled = await lifecycle.transitionSend(draftID: draftID, to: .notQueued) { send in
            send.isCancellable && (operationID == nil || send.operationID == operationID)
        }
        if cancelled != nil { return nil }
        guard let send = lifecycle.drafts[draftID]?.send else { return nil }
        switch send {
        case .claimed: return "It is already being sent."
        case .notQueued: return nil
        default: return send.isCancellable ? "The change could not be saved. Try again." : nil
        }
    }

    public func confirmSend(draftID: UUID, operationID: UUID?, interactive: Bool) async {
        guard inFlight[draftID] == nil,
              case .held(let held, _, _) = lifecycle.drafts[draftID]?.send,
              operationID == nil || operationID == held else { return }
        let runs = currentRuns()
        let task = start(draftID) { runner in
            await runner.claim(draftID: draftID, operationID: held, runs: runs, delivery: interactive ? .manual : .background)
        }
        await task.value
    }

    public func retrySend(draftID: UUID) async {
        guard inFlight[draftID] == nil,
              case let .failed(operationID?, _, false, snapshot?) = lifecycle.drafts[draftID]?.send else { return }
        let runs = currentRuns()
        let task = start(draftID) { runner in
            guard await runner.lifecycle.transitionSend(
                draftID: draftID,
                to: .claimed(operationID: operationID, snapshot: snapshot, claimedAt: runner.now()),
                when: { if case .failed(operationID?, _, false, _) = $0 { return true } else { return false } }
            ) != nil else { return }
            await runner.dispatch(draftID: draftID, operationID: operationID, snapshot: snapshot, runs: runs, delivery: .manual)
        }
        await task.value
    }

    public func clearSendOutcome(draftID: UUID) async {
        _ = await lifecycle.transitionSend(draftID: draftID, to: .notQueued) { send in
            switch send {
            case .sent, .failed: true
            default: false
            }
        }
    }

    /// A new intent may replace nothing, a finished send, or a failure that
    /// started nothing. A send whose outcome is unknown is resolved first.
    private static let canQueue: @Sendable (MeetingSend) -> Bool = { send in
        switch send {
        case .notQueued, .sent: true
        case .failed(_, _, let definite, _): definite
        case .queued, .held, .claimed: false
        }
    }

    // MARK: - Claiming and dispatching

    @discardableResult
    private func start(_ draftID: UUID, _ work: @escaping @MainActor (QueuedHandoffRunner) async -> Void) -> Task<Void, Never> {
        if let existing = inFlight[draftID] { return existing }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await work(self)
            self.inFlight[draftID] = nil
        }
        inFlight[draftID] = task
        return task
    }

    /// Fixes what is sent (decision 6: whatever the draft holds now), writes
    /// the claim with that snapshot, and only then dispatches. Anything that
    /// makes the send impossible ends it as a definite failure.
    private func claim(draftID: UUID, operationID: UUID, runs: [StoredTranscriptRun], delivery: TranscriptAgentDelivery) async {
        guard let dispatcher, let draft = lifecycle.drafts[draftID] else { return }
        guard case .attached(_, let runID) = draft.phase else { return }
        let environment = await dispatcher.environment()
        // The person may have cancelled while the environment was read.
        guard let current = lifecycle.drafts[draftID], current.send.operationID == operationID, current.send.isCancellable else { return }
        let snapshot: MeetingSendSnapshot
        switch Self.snapshot(of: current, runID: runID, notes: lifecycle.notes(draftID: draftID), environment: environment) {
        case .success(let made): snapshot = made
        case .failure(let problem):
            await fail(current, operationID: operationID, message: problem.message)
            return
        }
        guard await lifecycle.transitionSend(
            draftID: draftID,
            to: .claimed(operationID: operationID, snapshot: snapshot, claimedAt: now()),
            when: { $0.operationID == operationID && $0.isCancellable }
        ) != nil else { return }
        await dispatch(draftID: draftID, operationID: operationID, snapshot: snapshot, runs: runs, delivery: delivery)
    }

    private func dispatch(
        draftID: UUID,
        operationID: UUID,
        snapshot: MeetingSendSnapshot,
        runs: [StoredTranscriptRun],
        delivery: TranscriptAgentDelivery
    ) async {
        guard let dispatcher else { return }
        let run = runs.first { $0.job.runID == snapshot.runID } ?? currentRuns().first { $0.job.runID == snapshot.runID }
        guard let transcript = run?.transcript else {
            await record(draftID: draftID, operationID: operationID, as: .failed(
                operationID: operationID,
                message: "The transcript is no longer in the library, so nothing was sent.",
                definite: true,
                retry: nil
            ))
            return
        }
        let request = TranscriptAgentRequest(
            operationID: operationID,
            transcript: transcript,
            agent: TranscriptAgent(
                id: snapshot.agentID,
                displayName: snapshot.agentName,
                commandLabel: snapshot.agentCommandLabel,
                supportsEffort: snapshot.effort != nil
            ),
            model: snapshot.model,
            effort: snapshot.effort.flatMap(TranscriptAgentEffort.init(rawValue:)),
            folder: snapshot.folderPath.map { TranscriptAgentFolder(id: snapshot.folderID, url: URL(fileURLWithPath: $0, isDirectory: true)) },
            mcpURL: snapshot.mcpURL,
            instruction: snapshot.instruction,
            notes: snapshot.notes,
            delivery: delivery
        )
        let outcome = await dispatcher.send(request)
        let title = lifecycle.drafts[draftID]?.effectiveTitle ?? ""
        if outcome.succeeded {
            let sessionID = outcome.sessionID ?? ""
            await record(draftID: draftID, operationID: operationID, as: .sent(
                operationID: operationID,
                latchSessionID: sessionID,
                sessionName: outcome.sessionName,
                destination: snapshot.destination,
                at: now()
            ))
            // History and notices come after the outcome is on disk: neither
            // can change what was recorded.
            preferences?.recordSend(agentID: request.agent.id, model: request.model, effort: request.effort)
            preferences?.mcpURL = request.mcpURL ?? ""
            preferences?.recordInstruction(request.instruction, folderID: request.folder?.id)
            notifier?.post(.sent(draftID: draftID, operationID: operationID, meetingTitle: title, destination: snapshot.destination, latchSessionID: sessionID))
        } else {
            let message = outcome.errorMessage ?? "The agent could not be started."
            await record(draftID: draftID, operationID: operationID, as: .failed(
                operationID: operationID,
                message: message,
                definite: outcome.failureIsDefinite,
                retry: outcome.failureIsDefinite ? nil : snapshot
            ))
            notifier?.post(.failed(draftID: draftID, operationID: operationID, meetingTitle: title, message: message))
        }
    }

    /// Writes a claimed send's outcome. A draft deleted meanwhile has nothing
    /// to write to; the send still happened, and the notice says so.
    private func record(draftID: UUID, operationID: UUID, as outcome: MeetingSend) async {
        let written = await lifecycle.transitionSend(draftID: draftID, to: outcome) { send in
            if case .claimed(operationID, _, _) = send { return true }
            return false
        }
        if written == nil {
            Self.logger.error("A queued send's outcome could not be recorded")
        }
    }

    private func fail(_ draft: MeetingDraft, operationID: UUID, message: String) async {
        guard await lifecycle.transitionSend(
            draftID: draft.id,
            to: .failed(operationID: operationID, message: message, definite: true, retry: nil),
            when: { $0.operationID == operationID && $0.isCancellable }
        ) != nil else { return }
        notifier?.post(.failed(draftID: draft.id, operationID: operationID, meetingTitle: draft.effectiveTitle, message: message))
    }

    // MARK: - Snapshot

    struct SnapshotProblem: Error, Equatable {
        let message: String
    }

    /// The send as the draft describes it now, resolved against what is
    /// installed and connected now. Mirrors the tray's own resolution: an
    /// unset folder means the first connected one still there.
    static func snapshot(
        of draft: MeetingDraft,
        runID: UUID,
        notes: MeetingNotesContent,
        environment: TranscriptAgentEnvironment
    ) -> Result<MeetingSendSnapshot, SnapshotProblem> {
        if let reason = environment.unavailableReason { return .failure(.init(message: reason)) }
        let settings = draft.handoff
        guard let agentID = settings.agentID else {
            return .failure(.init(message: "No agent was chosen, so nothing was sent."))
        }
        guard let agent = environment.agents.first(where: { $0.id == agentID }) else {
            return .failure(.init(message: "\(agentID) is no longer installed on this Mac, so nothing was sent."))
        }
        let folder: TranscriptAgentFolder?
        switch settings.folder {
        case .unset: folder = environment.folders.first(where: \.isReachable) ?? environment.folders.first
        case .none: folder = nil
        case .folder(let id):
            guard let chosen = environment.folders.first(where: { $0.id == id }) else {
                return .failure(.init(message: "The folder chosen for this is no longer connected, so nothing was sent."))
            }
            folder = chosen
        }
        if let folder, !folder.isReachable {
            return .failure(.init(message: "\(folder.displayName) is no longer where it was, so nothing was sent."))
        }
        guard TranscriptViewModel.isAcceptableMCPURL(settings.mcpURL) else {
            return .failure(.init(message: "The MCP URL is not a web address, so nothing was sent."))
        }
        guard case .editable(let notes) = notes else {
            return .failure(.init(message: "The notes could not be read, so nothing was sent."))
        }
        // The same trimming and defaults a manual send's request applies.
        let effort = agent.supportsEffort ? settings.effort.flatMap(TranscriptAgentEffort.init(rawValue:)) : nil
        return .success(MeetingSendSnapshot(
            runID: runID,
            agentID: agent.id,
            agentName: agent.displayName,
            agentCommandLabel: agent.commandLabel,
            model: nonEmpty(settings.model),
            effort: effort?.rawValue,
            folderID: folder?.id,
            folderPath: folder?.url.standardizedFileURL.path,
            folderName: folder?.displayName,
            mcpURL: nonEmpty(settings.mcpURL),
            instruction: nonEmpty(settings.prompt) ?? TranscriptAgentRequest.defaultInstruction,
            notes: notes.filter { nonEmpty($0.text) != nil }
        ))
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// "Claude Code in tough-leaf", from the settings alone: a held send's
    /// notice is posted without asking what is installed.
    private func destination(for settings: MeetingHandoffSettings) -> String {
        let agent = settings.agentID.map { agentNames[$0] ?? $0 } ?? "the agent"
        switch settings.folder {
        case .folder(let id): return "\(agent) in \(URL(fileURLWithPath: id).lastPathComponent)"
        case .none, .unset: return agent
        }
    }
}
