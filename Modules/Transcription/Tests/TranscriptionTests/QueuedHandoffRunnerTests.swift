import Foundation
import ScribeAppCore
import XCTest
@testable import Transcription

/// "Send after processing": the queued send that fires when a meeting's
/// transcript is ready, its holds, cancellation, and recovery after a crash.
@MainActor
final class QueuedHandoffRunnerTests: XCTestCase {
    private var root: URL!
    private var draftsURL: URL { root.appending(path: "drafts") }
    private var storeURL: URL { root.appending(path: "store") }
    private let defaultsSuite = "QueuedHandoffRunnerTests-\(UUID().uuidString)"
    private lazy var preferences = TranscriptAgentPreferences(defaults: UserDefaults(suiteName: defaultsSuite)!)
    /// Long before any send in these tests, so nothing is held as "queued
    /// before this launch" unless a test says so.
    private let launchedAt = Date(timeIntervalSince1970: 0)
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "QueuedHandoffRunnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removePersistentDomain(forName: defaultsSuite)
    }

    // MARK: - Firing

    func testAQueuedSendFiresOnceWhenTheTranscriptIsReadyWithNoWindowOpen() async throws {
        let latch = FakeLatch()
        let (lifecycle, runner, draft) = try await recordedMeeting(latch: latch, notes: ["Ask about the budget"])
        let notifier = NotifierSpy()
        runner.notifier = notifier

        await assertQueued(runner, draft.id)
        guard case .queued(let operationID, _) = lifecycle.drafts[draft.id]?.send else { return XCTFail("not queued") }
        XCTAssertEqual(notifier.prepared, 1, "permission is asked when the person first queues")

        // Still transcribing: nothing goes.
        let running = storedRun(draftID: draft.id, state: .transcribing)
        await reconcile(lifecycle, runner, runs: [running])
        XCTAssertTrue(latch.requests.isEmpty)

        // Duplicate completion events: two passes at once still send once.
        let finished = storedRun(draftID: draft.id, state: .complete, runID: running.job.runID)
        await lifecycle.reconcile(sessions: [:], pendingRequests: [], runs: [finished], autoTranscribe: true, isLaunch: false)
        async let first: Void = runner.reconcile(runs: [finished])
        async let second: Void = runner.reconcile(runs: [finished])
        _ = await (first, second)
        await runner.reconcile(runs: [finished])
        await runner.waitForAll()

        XCTAssertEqual(latch.requests.count, 1)
        let request = try XCTUnwrap(latch.requests.first)
        XCTAssertEqual(request.operationID, operationID, "the operation ID is Latch's request ID")
        XCTAssertEqual(request.delivery, .background, "a queued send never brings Latch forward")
        XCTAssertEqual(request.notes.map(\.text), ["Ask about the budget"])
        XCTAssertEqual(request.transcript.transcriptID, running.job.runID.uuidString)
        guard case let .sent(sentID, sessionID, _, destination, _)? = lifecycle.drafts[draft.id]?.send else {
            return XCTFail("not recorded as sent: \(String(describing: lifecycle.drafts[draft.id]?.send))")
        }
        XCTAssertEqual(sentID, operationID)
        XCTAssertEqual(sessionID, latch.sessions[operationID])
        XCTAssertEqual(destination, "Claude Code")
        XCTAssertEqual(notifier.notices.last, .sent(draftID: draft.id, operationID: operationID, meetingTitle: "Standup", destination: "Claude Code", latchSessionID: sessionID))
        XCTAssertEqual(preferences.lastAgentID, "claude", "history is written after a confirmed send")

        // A rerun of the meeting never fires the intent again.
        let rerun = storedRun(draftID: draft.id, state: .complete, retryOf: running.job.runID)
        await reconcile(lifecycle, runner, runs: [finished, rerun])
        XCTAssertEqual(latch.requests.count, 1)
    }

    func testSettingsEditedWhileQueuedAreTheOnesSent() async throws {
        let latch = FakeLatch()
        latch.environment = TranscriptAgentEnvironment(
            agents: [Self.claude, Self.codex],
            folders: [TranscriptAgentFolder(url: root)]
        )
        let (lifecycle, runner, draft) = try await recordedMeeting(latch: latch)
        await assertQueued(runner, draft.id)

        var edited = try XCTUnwrap(lifecycle.handoffSettings(draftID: draft.id))
        edited.agentID = "codex"
        edited.model = "gpt-5.5"
        edited.effort = "high"
        edited.folder = .folder(TranscriptAgentFolder(url: root).id)
        edited.prompt = "Only the decisions."
        edited.promptOrigin = .edited
        lifecycle.setHandoffSettings(draftID: draft.id, edited)
        XCTAssertTrue(lifecycle.drafts[draft.id]?.send.blocksCombine == true, "editing does not cancel or requeue")

        await reconcile(lifecycle, runner, runs: [storedRun(draftID: draft.id, state: .complete)])

        let request = try XCTUnwrap(latch.requests.first)
        XCTAssertEqual(request.agent.id, "codex")
        XCTAssertEqual(request.model, "gpt-5.5")
        XCTAssertEqual(request.effort, .high)
        XCTAssertEqual(request.folder?.url.standardizedFileURL.path, root.standardizedFileURL.path)
        XCTAssertEqual(request.instruction, "Only the decisions.")
    }

    func testWarningsStillSendAndNoSpeechEndsTheIntentWithTheNotesKept() async throws {
        let latch = FakeLatch()
        let (lifecycle, runner, draft) = try await recordedMeeting(latch: latch, notes: ["Kept"])
        await assertQueued(runner, draft.id)
        await reconcile(lifecycle, runner, runs: [storedRun(draftID: draft.id, state: .complete, status: .noSpeech)])

        XCTAssertTrue(latch.requests.isEmpty)
        guard case let .failed(_, message, definite, _)? = lifecycle.drafts[draft.id]?.send else { return XCTFail("not failed") }
        XCTAssertTrue(definite)
        XCTAssertTrue(message.contains("No speech"))
        XCTAssertEqual(lifecycle.notes(draftID: draft.id).notes.map(\.text), ["Kept"])

        let (warnedLifecycle, warnedRunner, warned) = try await recordedMeeting(latch: latch)
        await assertQueued(warnedRunner, warned.id)
        await reconcile(warnedLifecycle, warnedRunner, runs: [storedRun(draftID: warned.id, state: .complete, status: .completeWithWarnings)])
        XCTAssertEqual(latch.requests.count, 1)
    }

    func testAFailedRunEndsTheIntentAndRetranscribingNeedsAFreshSend() async throws {
        let latch = FakeLatch()
        let (lifecycle, runner, draft) = try await recordedMeeting(latch: latch)
        await assertQueued(runner, draft.id)
        let failed = storedRun(draftID: draft.id, state: .failed)
        await reconcile(lifecycle, runner, runs: [failed])
        guard case .failed(_, _, true, _)? = lifecycle.drafts[draft.id]?.send else { return XCTFail("not failed") }

        let retranscribed = storedRun(draftID: draft.id, state: .complete, retryOf: failed.job.runID)
        await reconcile(lifecycle, runner, runs: [failed, retranscribed])
        XCTAssertTrue(latch.requests.isEmpty, "a finished intent never fires again")
    }

    func testARemovedAgentOrFolderFailsDefinitelyWithoutSending() async throws {
        let latch = FakeLatch()
        let (lifecycle, runner, draft) = try await recordedMeeting(latch: latch)
        await assertQueued(runner, draft.id)
        latch.environment = TranscriptAgentEnvironment(agents: [Self.codex], folders: [])
        await reconcile(lifecycle, runner, runs: [storedRun(draftID: draft.id, state: .complete)])
        XCTAssertTrue(latch.requests.isEmpty)
        guard case let .failed(_, message, true, nil)? = lifecycle.drafts[draft.id]?.send else { return XCTFail("not failed") }
        XCTAssertTrue(message.contains("no longer installed"), message)
        XCTAssertFalse(lifecycle.drafts[draft.id]!.send.blocksCombine)

        latch.environment = TranscriptAgentEnvironment(agents: [Self.claude], folders: [])
        let (folderLifecycle, folderRunner, folderDraft) = try await recordedMeeting(latch: latch)
        var settings = try XCTUnwrap(folderLifecycle.handoffSettings(draftID: folderDraft.id))
        settings.folder = .folder("/nowhere/repo")
        folderLifecycle.setHandoffSettings(draftID: folderDraft.id, settings)
        await assertQueued(folderRunner, folderDraft.id)
        await reconcile(folderLifecycle, folderRunner, runs: [storedRun(draftID: folderDraft.id, state: .complete)])
        guard case let .failed(_, folderMessage, true, _)? = folderLifecycle.drafts[folderDraft.id]?.send else { return XCTFail("not failed") }
        XCTAssertTrue(folderMessage.contains("no longer connected"), folderMessage)
        XCTAssertTrue(latch.requests.isEmpty)
    }

    // MARK: - Holding (decision 7)

    func testAnInterruptedRecordingIsHeldAndSendsOnlyWhenConfirmed() async throws {
        let latch = FakeLatch()
        let notifier = NotifierSpy()
        let (lifecycle, runner, draft) = try await recordedMeeting(latch: latch, stopReason: .microphoneDisconnected)
        runner.notifier = notifier
        await assertQueued(runner, draft.id)
        let run = storedRun(draftID: draft.id, state: .complete)
        await reconcile(lifecycle, runner, runs: [run])

        guard case let .held(operationID, reason, _)? = lifecycle.drafts[draft.id]?.send else { return XCTFail("not held") }
        XCTAssertEqual(reason, .interrupted)
        XCTAssertTrue(latch.requests.isEmpty)
        XCTAssertEqual(notifier.notices.last, .held(draftID: draft.id, operationID: operationID, meetingTitle: "Standup", destination: "Claude Code", reason: .interrupted))
        XCTAssertEqual(lifecycle.summary(for: draft.id)?.status, "Ready to send \u{2014} confirm")

        // Reconciling again does not fire a held send, or notify twice.
        await reconcile(lifecycle, runner, runs: [run])
        XCTAssertTrue(latch.requests.isEmpty)
        XCTAssertEqual(notifier.notices.count, 1)

        // The notification's Send: sent, but Latch is not brought forward.
        runner.currentRuns = { [run] }
        await runner.confirmSend(draftID: draft.id, operationID: operationID, interactive: false)
        XCTAssertEqual(latch.requests.map(\.operationID), [operationID])
        XCTAssertEqual(latch.requests.first?.delivery, .background)
        guard case .sent? = lifecycle.drafts[draft.id]?.send else { return XCTFail("not sent") }
    }

    func testASendQueuedBeforeARelaunchIsHeldAndTheTrayConfirmBringsLatchForward() async throws {
        let latch = FakeLatch()
        let (lifecycle, runner, draft) = try await recordedMeeting(latch: latch)
        await assertQueued(runner, draft.id)

        // Relaunch: a new runner whose process started after the send was queued.
        clock = clock.addingTimeInterval(60)
        let relaunched = makeRunner(lifecycle, latch: latch, launchedAt: clock)
        let run = storedRun(draftID: draft.id, state: .complete)
        await reconcile(lifecycle, relaunched, runs: [run])
        guard case .held(_, .recovered, _)? = lifecycle.drafts[draft.id]?.send else { return XCTFail("not held as recovered") }

        relaunched.currentRuns = { [run] }
        await relaunched.confirmSend(draftID: draft.id, operationID: nil, interactive: true)
        XCTAssertEqual(latch.requests.first?.delivery, .manual)
    }

    func testASendQueuedMoreThanFourHoursAgoIsHeldAndCanBeCancelled() async throws {
        let latch = FakeLatch()
        let (lifecycle, runner, draft) = try await recordedMeeting(latch: latch)
        await assertQueued(runner, draft.id)
        clock = clock.addingTimeInterval(QueuedHandoffRunner.queuedSendReconfirmAfter + 1)
        await reconcile(lifecycle, runner, runs: [storedRun(draftID: draft.id, state: .complete)])
        guard case .held(let operationID, .stale, _)? = lifecycle.drafts[draft.id]?.send else { return XCTFail("not held as stale") }

        let cancelFailure = await runner.cancelSend(draftID: draft.id, operationID: operationID)
        XCTAssertNil(cancelFailure)
        XCTAssertEqual(lifecycle.drafts[draft.id]?.send, .notQueued)
        await runner.confirmSend(draftID: draft.id, operationID: operationID, interactive: false)
        XCTAssertTrue(latch.requests.isEmpty, "a cancelled send cannot be confirmed")
    }

    func testABackgroundSendWaitsWhileAnotherRecordingIsCaptured() async throws {
        let latch = FakeLatch()
        let (lifecycle, runner, draft) = try await recordedMeeting(latch: latch)
        var capturing = true
        runner.isCaptureActive = { capturing }
        await assertQueued(runner, draft.id)
        let run = storedRun(draftID: draft.id, state: .complete)
        await reconcile(lifecycle, runner, runs: [run])
        XCTAssertTrue(latch.requests.isEmpty)
        guard case .queued? = lifecycle.drafts[draft.id]?.send else { return XCTFail("should still be queued") }

        capturing = false
        await reconcile(lifecycle, runner, runs: [run])
        XCTAssertEqual(latch.requests.count, 1)
    }

    // MARK: - Cancel and delete racing a claim

    func testCancelBeforeClaimSendsNothingAndCancelAfterClaimIsRefused() async throws {
        let latch = FakeLatch()
        let (lifecycle, runner, draft) = try await recordedMeeting(latch: latch)
        await assertQueued(runner, draft.id)
        // The person cancels while the runner is reading what is installed.
        latch.onEnvironment = { [weak runner] in
            _ = await runner?.cancelSend(draftID: draft.id, operationID: nil)
        }
        await reconcile(lifecycle, runner, runs: [storedRun(draftID: draft.id, state: .complete)])
        XCTAssertTrue(latch.requests.isEmpty)
        XCTAssertEqual(lifecycle.drafts[draft.id]?.send, .notQueued)

        // Once claimed, cancelling is refused and the send completes.
        latch.onEnvironment = nil
        let gate = Gate()
        latch.beforeCreate = { await gate.wait() }
        await assertQueued(runner, draft.id)
        let run = storedRun(draftID: draft.id, state: .complete)
        await lifecycle.reconcile(sessions: [:], pendingRequests: [], runs: [run], autoTranscribe: true, isLaunch: false)
        await runner.reconcile(runs: [run])
        while case .queued? = lifecycle.drafts[draft.id]?.send { await Task.yield() }
        guard case .claimed? = lifecycle.drafts[draft.id]?.send else { return XCTFail("not claimed") }
        let refusal = await runner.cancelSend(draftID: draft.id, operationID: nil)
        XCTAssertEqual(refusal, "It is already being sent.")
        gate.open()
        await runner.waitForAll()
        guard case .sent? = lifecycle.drafts[draft.id]?.send else { return XCTFail("not sent") }
    }

    func testDeletingAMeetingWhileItsSendIsClaimedWaitsForTheOutcome() async throws {
        let latch = FakeLatch()
        let gate = Gate()
        latch.beforeCreate = { await gate.wait() }
        let (lifecycle, runner, draft) = try await recordedMeeting(latch: latch)
        await assertQueued(runner, draft.id)
        let run = storedRun(draftID: draft.id, state: .complete)
        await lifecycle.reconcile(sessions: [:], pendingRequests: [], runs: [run], autoTranscribe: true, isLaunch: false)
        await runner.reconcile(runs: [run])
        while latch.started.isEmpty { await Task.yield() }

        var deleted = false
        let deletion = Task { @MainActor in
            await runner.waitForInFlight(draftID: draft.id)
            try await lifecycle.deleteDraft(draftID: draft.id)
            deleted = true
        }
        for _ in 0 ..< 20 { await Task.yield() }
        XCTAssertFalse(deleted, "the claimed send records its outcome first")
        gate.open()
        try await deletion.value
        XCTAssertTrue(deleted)
        XCTAssertEqual(latch.sessions.count, 1)
        XCTAssertNil(lifecycle.drafts[draft.id])
    }

    // MARK: - Crashes (decision 8)

    /// Scribe is killed after Latch created the session and before the
    /// outcome was saved. The relaunch re-issues the same send under the same
    /// ID, and Latch answers with the session it already made: one session.
    func testAKillAfterLatchCreatesTheSessionLeavesExactlyOneSession() async throws {
        let latch = FakeLatch()
        let (lifecycle, runner, draft) = try await recordedMeeting(latch: latch, notes: ["One"])
        await assertQueued(runner, draft.id)
        let run = storedRun(draftID: draft.id, state: .complete)
        // The first attempt creates the session and then never returns: the
        // process is gone before the outcome is written.
        latch.hangAfterCreate = true
        await lifecycle.reconcile(sessions: [:], pendingRequests: [], runs: [run], autoTranscribe: true, isLaunch: false)
        await runner.reconcile(runs: [run])
        while latch.sessions.isEmpty { await Task.yield() }
        guard case let .claimed(operationID, snapshot, _)? = await lifecycle.store.draft(id: draft.id)?.send else {
            return XCTFail("the claim must be on disk before Latch is asked")
        }
        XCTAssertEqual(snapshot.notes.map(\.text), ["One"])

        // Relaunch from disk.
        latch.hangAfterCreate = false
        clock = clock.addingTimeInterval(30)
        let relaunched = await MeetingDraftLifecycle(store: MeetingDraftStore(directoryURL: draftsURL), transcriptStore: TranscriptStore(storeDirectoryURL: storeURL), preferences: preferences)
        // Settings changed after the claim are not what the retry sends.
        var later = try XCTUnwrap(relaunched.handoffSettings(draftID: draft.id))
        later.prompt = "Something else"
        relaunched.setHandoffSettings(draftID: draft.id, later)
        let secondRunner = makeRunner(relaunched, latch: latch, launchedAt: clock)
        await reconcile(relaunched, secondRunner, runs: [run])

        XCTAssertEqual(latch.sessions.count, 1, "exactly one Latch session")
        XCTAssertEqual(latch.requests.map(\.operationID), [operationID, operationID])
        XCTAssertEqual(latch.requests.last?.instruction, snapshot.instruction, "the retry uses the claimed snapshot unchanged")
        XCTAssertEqual(latch.requests.last?.delivery, .background)
        guard case let .sent(_, sessionID, _, _, _)? = relaunched.drafts[draft.id]?.send else { return XCTFail("not sent") }
        XCTAssertEqual(sessionID, latch.sessions[operationID])
    }

    func testAnUnknownOutcomeIsRetriedUnderTheSameIDAndBlocksCombining() async throws {
        let latch = FakeLatch()
        latch.unknownOutcomeOnce = true
        let (lifecycle, runner, draft) = try await recordedMeeting(latch: latch)
        await assertQueued(runner, draft.id)
        let run = storedRun(draftID: draft.id, state: .complete)
        await reconcile(lifecycle, runner, runs: [run])
        guard case let .failed(operationID?, _, false, snapshot?)? = lifecycle.drafts[draft.id]?.send else {
            return XCTFail("not an unknown outcome: \(String(describing: lifecycle.drafts[draft.id]?.send))")
        }
        XCTAssertTrue(lifecycle.summary(for: draft.id)?.sendBlocksCombine == true)
        let refused = await runner.queueSend(draftID: draft.id)
        XCTAssertNotNil(refused, "an unknown outcome is resolved before a new send")

        runner.currentRuns = { [run] }
        await runner.retrySend(draftID: draft.id)
        XCTAssertEqual(latch.requests.map(\.operationID), [operationID, operationID])
        XCTAssertEqual(latch.requests.last?.instruction, snapshot.instruction)
        XCTAssertEqual(latch.sessions.count, 1)
        guard case .sent? = lifecycle.drafts[draft.id]?.send else { return XCTFail("not sent") }
    }

    func testAClaimThatCannotBeSavedIsNeverDispatched() async throws {
        let latch = FakeLatch()
        let writer = SwitchableWriter()
        let lifecycle = await MeetingDraftLifecycle(
            store: MeetingDraftStore(directoryURL: draftsURL, writeFile: writer.write),
            transcriptStore: TranscriptStore(storeDirectoryURL: storeURL),
            preferences: preferences
        )
        let draft = try await startMeeting(lifecycle)
        let runner = makeRunner(lifecycle, latch: latch)
        await assertQueued(runner, draft.id)
        writer.fails = true
        let run = storedRun(draftID: draft.id, state: .complete)
        await reconcile(lifecycle, runner, runs: [run])
        XCTAssertTrue(latch.requests.isEmpty, "Not saved blocks the claim")

        writer.fails = false
        _ = await lifecycle.retrySave(draftID: draft.id)
        await reconcile(lifecycle, runner, runs: [run])
        XCTAssertEqual(latch.requests.count, 1)
    }

    func testNotificationsDeniedLeaveTheRowAsTheRecord() async throws {
        let latch = FakeLatch()
        let (lifecycle, runner, draft) = try await recordedMeeting(latch: latch)
        runner.notifier = nil
        await assertQueued(runner, draft.id)
        XCTAssertEqual(lifecycle.summary(for: draft.id)?.status.hasSuffix("sends to claude"), true)
        await reconcile(lifecycle, runner, runs: [storedRun(draftID: draft.id, state: .complete)])
        XCTAssertEqual(lifecycle.summary(for: draft.id)?.status, "Sent to Claude Code")
    }

    func testASendFromBeforeThisVersionStillDecodes() throws {
        // Drafts written by phase 1–3 builds carry `notQueued` and no stop reason.
        let draft = MeetingDraft(recorderSessionID: UUID(), defaultTitle: "Old")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: MeetingDraftStore.encode(draft)) as? [String: Any])
        json.removeValue(forKey: "stopReason")
        let decoded = try MeetingDraftStore.decode(JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.send, .notQueued)
        XCTAssertNil(decoded.stopReason)
    }

    // MARK: - Tray

    func testTheTrayOffersSendAfterProcessingThenShowsTheLiveDestination() async throws {
        let latch = FakeLatch()
        let lifecycle = await makeLifecycle()
        let draft = await lifecycle.captureStarted(sessionID: UUID(), startedAt: Date(), title: "Standup", sessionName: "Standup")
        var settings = draft.handoff
        settings.agentID = "claude"
        settings.folder = .none
        lifecycle.setHandoffSettings(draftID: draft.id, settings)
        let runner = makeRunner(lifecycle, latch: latch)
        let viewModel = TranscriptViewModel(
            files: [placeholder(for: draft, lifecycle)],
            playback: AgentPlaybackStub(),
            agentDispatcher: latch,
            agentPreferences: preferences,
            draftEditor: lifecycle,
            sendController: runner
        )
        let tray = viewModel.handoffTarget(for: viewModel.files[0])
        await viewModel.loadAgentEnvironment(for: tray)
        XCTAssertEqual(viewModel.handoffTrayState(for: tray), .canQueue)

        await viewModel.queueSend(tray)
        viewModel.reload(files: [placeholder(for: draft, lifecycle)])
        XCTAssertEqual(viewModel.handoffTrayState(for: tray), .waiting)
        XCTAssertFalse(viewModel.canSubmitHandoff(tray))
        viewModel.setHandoffModel("opus", for: tray)
        XCTAssertEqual(viewModel.handoffDestinationSummary(for: tray), "Claude Code \u{00B7} opus \u{00B7} no folder")

        await viewModel.cancelQueuedSend(tray)
        viewModel.reload(files: [placeholder(for: draft, lifecycle)])
        XCTAssertEqual(viewModel.handoffTrayState(for: tray), .canQueue)
    }

    // MARK: - Helpers

    static let claude = TranscriptAgent(id: "claude", displayName: "Claude Code", commandLabel: "claude", supportsEffort: true)
    static let codex = TranscriptAgent(id: "codex", displayName: "Codex", commandLabel: "codex", supportsEffort: true)

    private func assertQueued(_ runner: QueuedHandoffRunner, _ draftID: UUID, file: StaticString = #filePath, line: UInt = #line) async {
        let failure = await runner.queueSend(draftID: draftID)
        XCTAssertNil(failure, file: file, line: line)
    }

    private func makeLifecycle() async -> MeetingDraftLifecycle {
        await MeetingDraftLifecycle(
            store: MeetingDraftStore(directoryURL: draftsURL),
            transcriptStore: TranscriptStore(storeDirectoryURL: storeURL),
            preferences: preferences
        )
    }

    private func makeRunner(_ lifecycle: MeetingDraftLifecycle, latch: FakeLatch, launchedAt: Date? = nil) -> QueuedHandoffRunner {
        let runner = QueuedHandoffRunner(
            lifecycle: lifecycle,
            dispatcher: latch,
            preferences: preferences,
            launchedAt: launchedAt ?? self.launchedAt,
            now: { [unowned self] in self.clock }
        )
        runner.agentNames = ["claude": "Claude Code", "codex": "Codex"]
        return runner
    }

    /// A recording that has stopped, with an agent chosen and no folder.
    private func recordedMeeting(
        latch: FakeLatch,
        notes: [String] = [],
        stopReason: MeetingStopReason = .user
    ) async throws -> (MeetingDraftLifecycle, QueuedHandoffRunner, MeetingDraft) {
        let lifecycle = await makeLifecycle()
        let draft = try await startMeeting(lifecycle, notes: notes, stopReason: stopReason)
        return (lifecycle, makeRunner(lifecycle, latch: latch), draft)
    }

    private func startMeeting(_ lifecycle: MeetingDraftLifecycle, notes: [String] = [], stopReason: MeetingStopReason = .user) async throws -> MeetingDraft {
        let session = UUID()
        let draft = await lifecycle.captureStarted(sessionID: session, startedAt: Date(), title: "Standup", sessionName: "Standup")
        var settings = draft.handoff
        settings.agentID = "claude"
        settings.folder = .none
        lifecycle.setHandoffSettings(draftID: draft.id, settings)
        if !notes.isEmpty {
            lifecycle.setNotes(draftID: draft.id, notes: notes.map { MeetingNote(text: $0, recordingOffsetMilliseconds: 1_000) })
        }
        await lifecycle.captureStopped(sessionID: session, reason: stopReason)
        await lifecycle.flushAll()
        return try XCTUnwrap(lifecycle.drafts[draft.id])
    }

    private func reconcile(_ lifecycle: MeetingDraftLifecycle, _ runner: QueuedHandoffRunner, runs: [StoredTranscriptRun]) async {
        await lifecycle.reconcile(sessions: [:], pendingRequests: [], runs: runs, autoTranscribe: true, isLaunch: false)
        await runner.reconcile(runs: runs)
        await runner.waitForAll()
    }

    private func storedRun(
        draftID: UUID,
        state: TranscriptionJobState,
        status: TranscriptStatus = .complete,
        runID: UUID = UUID(),
        retryOf: UUID? = nil
    ) -> StoredTranscriptRun {
        let meeting = storeURL.appending(path: "meeting--\(draftID.uuidString.prefix(8))", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)
        let job = TranscriptionJob(
            runID: runID,
            request: TranscriptionRequest(
                requestID: UUID(),
                sourceURL: URL(fileURLWithPath: "/tmp/final.m4a"),
                modelProfileID: "default",
                draftID: draftID
            ),
            sourceSnapshotURL: meeting.appending(path: "source.m4a"),
            runDirectoryURL: meeting.appending(path: "runs/\(runID.uuidString)"),
            sourceFingerprint: "a",
            modelFingerprint: "b",
            configurationFingerprint: "c",
            state: state,
            retryOfRunID: retryOf
        )
        var transcript: CanonicalTranscript?
        if state == .complete {
            transcript = Self.transcript(id: runID.uuidString, status: status)
        }
        return StoredTranscriptRun(job: job, transcript: transcript)
    }

    private static func transcript(id: String, status: TranscriptStatus) -> CanonicalTranscript {
        CanonicalTranscript(
            transcriptID: id,
            revision: 1,
            title: nil,
            status: status,
            createdAt: "2026-11-19T10:00:00Z",
            source: TranscriptSource(filename: "final.m4a", durationMs: 1_000, checksum: "sha256:meeting"),
            language: "en",
            languageSource: .detected,
            speakers: [TranscriptSpeaker(id: "speaker_1", identityAssignment: .unmatched, labelSnapshot: "Speaker 1")],
            segments: status == .noSpeech ? [] : [
                TranscriptSegment(
                    id: "seg_1",
                    speakerID: "speaker_1",
                    speakerLabel: "Speaker 1",
                    startMs: 0,
                    endMs: 800,
                    text: "Hello.",
                    overlap: false,
                    timingQuality: .asrWord,
                    words: [TimedWord(text: "Hello.", startMs: 0, endMs: 800)]
                ),
            ]
        )
    }

    private func placeholder(for draft: MeetingDraft, _ lifecycle: MeetingDraftLifecycle) -> TranscriptReviewFile {
        TranscriptReviewFile(
            id: draft.id.uuidString,
            sourceSnapshotURL: URL(fileURLWithPath: "/dev/null"),
            transcript: nil,
            jobState: .queued,
            hasAudio: false,
            draft: lifecycle.summary(for: draft.id)
        )
    }
}

/// Latch as Scribe relies on it: one session per request ID, whatever
/// happens to the caller.
@MainActor
private final class FakeLatch: TranscriptAgentDispatching, @unchecked Sendable {
    var environment = TranscriptAgentEnvironment(agents: [QueuedHandoffRunnerTests.claude], folders: [])
    private(set) var requests: [TranscriptAgentRequest] = []
    private(set) var started: [UUID] = []
    /// Request ID to session ID.
    private(set) var sessions: [UUID: String] = [:]
    var onEnvironment: (@MainActor () async -> Void)?
    var beforeCreate: (@MainActor () async -> Void)?
    var hangAfterCreate = false
    var unknownOutcomeOnce = false

    nonisolated func environment() async -> TranscriptAgentEnvironment {
        await currentEnvironment()
    }

    private func currentEnvironment() async -> TranscriptAgentEnvironment {
        if let onEnvironment { await onEnvironment() }
        return environment
    }

    nonisolated func connectFolder() async -> TranscriptAgentEnvironment { await environment() }
    nonisolated func disconnectFolder(id _: TranscriptAgentFolder.ID) async -> TranscriptAgentEnvironment { await environment() }

    nonisolated func send(_ request: TranscriptAgentRequest) async -> TranscriptAgentOutcome {
        await create(request)
    }

    private func create(_ request: TranscriptAgentRequest) async -> TranscriptAgentOutcome {
        requests.append(request)
        started.append(request.operationID)
        await beforeCreate?()
        let session = sessions[request.operationID] ?? "session-\(sessions.count + 1)"
        sessions[request.operationID] = session
        if hangAfterCreate {
            // Killed: no outcome ever comes back.
            try? await Task.sleep(for: .seconds(3_600))
        }
        if unknownOutcomeOnce {
            unknownOutcomeOnce = false
            return TranscriptAgentOutcome(sessionName: nil, agentName: request.agent.displayName, folderName: nil, errorMessage: "Latch reported something Scribe could not read.", failureIsDefinite: false)
        }
        return TranscriptAgentOutcome(sessionName: "scribe-standup", sessionID: session, agentName: request.agent.displayName, folderName: request.folder?.displayName)
    }

    nonisolated func openSession(id _: String) async -> String? { nil }
}

@MainActor
private final class NotifierSpy: QueuedHandoffNotifying {
    private(set) var prepared = 0
    private(set) var notices: [QueuedHandoffNotice] = []
    func prepare() { prepared += 1 }
    func post(_ notice: QueuedHandoffNotice) { notices.append(notice) }
}

/// Holds a step until the test opens it.
@MainActor
private final class Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private final class SwitchableWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var failing = false
    var fails: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }

    func write(_ data: Data, _ url: URL) throws {
        if fails { throw CocoaError(.fileWriteOutOfSpace) }
        try MeetingDraftStore.writePrivateFile(data, url)
    }
}
