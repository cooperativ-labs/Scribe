import Foundation
import ScribeAppCore
import XCTest
@testable import Transcription

/// Phase 1 of live meeting notes: draft identities, the draft store, the
/// capture-to-transcript lifecycle and its reconciliation, placeholder rows,
/// and titles that survive completion and reruns.
final class MeetingDraftStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Scribe Drafts \(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testDraftRoundTripsThroughAnOwnerOnlyFile() async throws {
        let directory = root.appendingPathComponent("drafts", isDirectory: true)
        let store = MeetingDraftStore(directoryURL: directory)
        let sessionID = UUID()
        let (draft, created) = await store.open(sessionID: sessionID, defaultTitle: "Weekly sync")
        XCTAssertTrue(created)
        try await store.update(id: draft.id, flush: true) { draft in
            draft.title = "Board prep"
            draft.notes = [MeetingNote(text: "Ask about Q3", recordingOffsetMilliseconds: 61_000), MeetingNote(text: "Untimed")]
            draft.handoff.folder = .none
            draft.handoff.promptOrigin = .edited
        }

        let file = await store.fileURL(for: draft.id)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [])

        let reopened = MeetingDraftStore(directoryURL: directory)
        let loaded = try await XCTUnwrapAsync(await reopened.draft(id: draft.id))
        XCTAssertEqual(loaded.schemaVersion, 1)
        XCTAssertEqual(loaded.recorderSessionID, sessionID)
        XCTAssertEqual(loaded.revision, 2)
        XCTAssertEqual(loaded.title, "Board prep")
        XCTAssertEqual(loaded.defaultTitle, "Weekly sync")
        XCTAssertEqual(loaded.notes.map(\.recordingOffsetMilliseconds), [61_000, nil])
        XCTAssertEqual(loaded.handoff.folder, MeetingHandoffFolder.none)
        XCTAssertEqual(loaded.phase, .recording)
        XCTAssertEqual(loaded.send, .notQueued)
    }

    func testOpeningIsIdempotentPerSessionAcrossRelaunch() async throws {
        let directory = root.appendingPathComponent("drafts", isDirectory: true)
        let sessionID = UUID()
        let store = MeetingDraftStore(directoryURL: directory)
        let first = await store.open(sessionID: sessionID, defaultTitle: "A")
        let resumed = await store.open(sessionID: sessionID, defaultTitle: "A")
        XCTAssertFalse(resumed.created)
        XCTAssertEqual(resumed.draft.id, first.draft.id)

        let relaunched = MeetingDraftStore(directoryURL: directory)
        let again = await relaunched.open(sessionID: sessionID, defaultTitle: "A")
        XCTAssertFalse(again.created)
        XCTAssertEqual(again.draft.id, first.draft.id)
        let all = await relaunched.all()
        XCTAssertEqual(all.count, 1)
    }

    func testAStaleRevisionIsRejected() async throws {
        let store = MeetingDraftStore(directoryURL: root)
        let draft = await store.open(sessionID: UUID(), defaultTitle: "A").draft
        try await store.update(id: draft.id, expectedRevision: 1) { $0.title = "First" }
        do {
            try await store.update(id: draft.id, expectedRevision: 1) { $0.title = "Second" }
            XCTFail("A write based on revision 1 must not overwrite revision 2")
        } catch let error as MeetingDraftStore.StoreError {
            XCTAssertEqual(error, .staleRevision(expected: 1, actual: 2))
        }
        let current = await store.draft(id: draft.id)
        XCTAssertEqual(current?.title, "First")
    }

    func testEditsAreWrittenAfterTheQuietPeriodOrAtAFlush() async throws {
        let store = MeetingDraftStore(directoryURL: root, debounce: .milliseconds(150))
        let draft = await store.open(sessionID: UUID(), defaultTitle: "A").draft
        try await store.update(id: draft.id) { $0.title = "Pending" }
        XCTAssertNil(try readDraft(draft.id).title, "Not written before the quiet period")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(try readDraft(draft.id).title, "Pending")

        try await store.update(id: draft.id) { $0.title = "Flushed" }
        await store.flush(id: draft.id)
        XCTAssertEqual(try readDraft(draft.id).title, "Flushed")
    }

    func testAFailedWriteIsVisibleAndRetryable() async throws {
        let disk = ToggleableDisk()
        disk.failing = true
        let store = MeetingDraftStore(directoryURL: root, writeFile: disk.write)
        let draft = await store.open(sessionID: UUID(), defaultTitle: "A").draft
        let failed = await store.saveState(id: draft.id)
        guard case .notSaved(let message) = failed else { return XCTFail("Expected Not saved, got \(failed)") }
        XCTAssertTrue(message.contains("disk full"))
        // The edit stays in memory while the disk refuses it.
        let inMemory = await store.draft(id: draft.id)
        XCTAssertEqual(inMemory?.id, draft.id)

        disk.failing = false
        let retried = await store.retrySave(id: draft.id)
        XCTAssertEqual(retried, .saved)
        XCTAssertEqual(try readDraft(draft.id).id, draft.id)
    }

    func testDeletingRemovesTheFile() async throws {
        let store = MeetingDraftStore(directoryURL: root)
        let draft = await store.open(sessionID: UUID(), defaultTitle: "A").draft
        try await store.delete(id: draft.id)
        let file = await store.fileURL(for: draft.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let remaining = await store.all()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testEveryStopReasonMapsFromTheRecorderJournal() {
        let journal: [String: MeetingStopReason] = [
            "user-requested": .user,
            "microphone-disconnected": .microphoneDisconnected,
            "selected-application-exited": .selectedApplicationExited,
            "unrecoverable-stream-error": .streamFailure,
            "system-sleep": .sleep,
            "permission-revoked": .permissionRevoked,
            "low-free-space": .lowFreeSpace,
            "something new": .interrupted,
        ]
        for (text, reason) in journal {
            XCTAssertEqual(MeetingStopReason(journalReason: text), reason, text)
        }
        for reason in MeetingStopReason.allCases {
            XCTAssertEqual(reason.isPersonRequested, reason == .user)
            XCTAssertEqual(reason.interruptionDescription == nil, reason == .user, "\(reason)")
        }
    }

    private func readDraft(_ id: UUID) throws -> MeetingDraft {
        try MeetingDraftStore.decode(Data(contentsOf: root.appendingPathComponent("\(id.uuidString).json")))
    }
}

final class MeetingDraftIdentityTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Scribe Identity \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testTheRecorderRequestIDIsDeterministicPerSession() {
        let session = UUID()
        let id = TranscriptionRequest.recorderRequestID(forSession: session)
        XCTAssertEqual(id, TranscriptionRequest.recorderRequestID(forSession: session))
        XCTAssertNotEqual(id, TranscriptionRequest.recorderRequestID(forSession: UUID()))
        XCTAssertEqual(id.uuidString.dropFirst(14).first, "5", "a version 5 UUID")
    }

    func testLegacyOutboxAndJobJSONWithoutADraftIDStillDecode() throws {
        let source = root.appendingPathComponent("legacy.m4a")
        try Data("audio".utf8).write(to: source)
        let request = TranscriptionRequest(sourceURL: source, modelProfileID: "default", title: "Old meeting")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let requestJSON = try encoder.encode(request)
        XCTAssertFalse(String(decoding: requestJSON, as: UTF8.self).contains("draftID"), "nil is omitted, as in files written before drafts")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertNil(try decoder.decode(TranscriptionRequest.self, from: requestJSON).draftID)

        let job = TranscriptionJob(
            request: request,
            sourceSnapshotURL: source,
            runDirectoryURL: root.appendingPathComponent("meeting--x/runs/\(UUID().uuidString)"),
            sourceFingerprint: "a",
            modelFingerprint: "b",
            configurationFingerprint: "c"
        )
        let decodedJob = try decoder.decode(TranscriptionJob.self, from: encoder.encode(job))
        XCTAssertNil(decodedJob.draftID)

        // And a current request carries it.
        let draftID = UUID()
        let current = TranscriptionRequest(sourceURL: source, modelProfileID: "default", draftID: draftID)
        XCTAssertEqual(try decoder.decode(TranscriptionRequest.self, from: encoder.encode(current)).draftID, draftID)
    }

    func testARepublishedRequestReusesItsJobInsteadOfAllocatingASecondRun() async throws {
        let store = root.appendingPathComponent("store", isDirectory: true)
        let source = try writeAudio("final.m4a", contents: "meeting audio")
        let session = UUID()
        let request = TranscriptionRequest(
            requestID: TranscriptionRequest.recorderRequestID(forSession: session),
            sourceURL: source,
            modelProfileID: "default",
            provenance: TranscriptionProvenance(producerID: "com.scribe.recorder", sessionID: session),
            draftID: UUID()
        )
        let first = try TranscriptionCoordinator(configuration: .init(transcriptStoreURL: store), stageRunner: TitledTranscriptRunner())
        let job = try await first.enqueue(request)
        let again = try await first.enqueue(request)
        XCTAssertEqual(again.runID, job.runID)

        // After a crash between the job write and the outbox claim the same
        // request is drained again by a fresh coordinator.
        let relaunched = try TranscriptionCoordinator(configuration: .init(transcriptStoreURL: store), stageRunner: TitledTranscriptRunner())
        let replayed = try await relaunched.enqueue(request)
        XCTAssertEqual(replayed.runID, job.runID)
        XCTAssertEqual(TranscriptStore(storeDirectoryURL: store).runs().count, 1)
        XCTAssertEqual(replayed.draftID, request.draftID, "the job record keeps the draft link")
    }

    func testTwoSessionsWithIdenticalAudioAreTwoRowsAndTwoRuns() async throws {
        let store = root.appendingPathComponent("store", isDirectory: true)
        let drafts = MeetingDraftStore(directoryURL: root.appendingPathComponent("drafts"))
        let coordinator = try TranscriptionCoordinator(configuration: .init(transcriptStoreURL: store), stageRunner: TitledTranscriptRunner())
        var draftIDs: [UUID] = []
        for name in ["a", "b"] {
            let session = UUID()
            let draft = await drafts.open(sessionID: session, defaultTitle: "Session \(name)").draft
            draftIDs.append(draft.id)
            let source = try writeAudio("\(name)/final.m4a", contents: "identical audio")
            _ = try await coordinator.enqueue(TranscriptionRequest(
                requestID: TranscriptionRequest.recorderRequestID(forSession: session),
                sourceURL: source,
                modelProfileID: "default",
                draftID: draft.id
            ))
        }
        await coordinator.runPending()
        let runs = TranscriptStore(storeDirectoryURL: store).runs()
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(Set(runs.map(\.job.meetingDirectoryURL)).count, 1, "the audio deduplicates into one meeting directory")

        let files = MeetingDraftReviewMerger.files(drafts: await drafts.all(), runs: runs)
        XCTAssertEqual(Set(files.map(\.id)), Set(draftIDs.map(\.uuidString)))
        XCTAssertEqual(Set(files.compactMap(\.runID)), Set(runs.map(\.job.runID.uuidString)))
    }

    func testRerunsCarryTheDraftAndTheGivenTitle() async throws {
        let store = root.appendingPathComponent("store", isDirectory: true)
        let source = try writeAudio("final.m4a", contents: "rerun audio")
        let draftID = UUID()
        let coordinator = try TranscriptionCoordinator(configuration: .init(transcriptStoreURL: store), stageRunner: TitledTranscriptRunner())
        let original = try await coordinator.enqueue(TranscriptionRequest(sourceURL: source, modelProfileID: "default", title: "Calendar name", draftID: draftID))
        await coordinator.runPending()
        let completed = try XCTUnwrap(TranscriptStore(storeDirectoryURL: store).run(withRunID: original.runID)?.job)

        let reprocessed = try await coordinator.reprocess(completed, speakerCount: .known(2), title: "Person's name")
        XCTAssertEqual(reprocessed.request.title, "Person's name")
        XCTAssertEqual(reprocessed.draftID, draftID)
        XCTAssertNotEqual(reprocessed.request.requestID, original.request.requestID)
        let retranscribed = try await coordinator.retranscribe(completed, modelProfileID: "default", speakerCount: .automatic, title: nil)
        XCTAssertEqual(retranscribed.request.title, "Calendar name", "nil keeps the original request title")
        XCTAssertEqual(retranscribed.draftID, draftID)
    }

    private func writeAudio(_ path: String, contents: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }
}

final class MeetingDraftReconcilerTests: XCTestCase {
    private let session = UUID()
    private lazy var requestID = TranscriptionRequest.recorderRequestID(forSession: session)

    func testARecordingDraftWhoseCaptureIsNotRunningIsInterrupted() {
        let draft = MeetingDraft(recorderSessionID: session, defaultTitle: "A", phase: .recording)
        let live = MeetingDraftReconciler.actions(for: .init(drafts: [draft], liveSessionID: session, sessions: [session: evidence(.capturing, .pending)]))
        XCTAssertEqual(live, [], "the live recording is left alone")

        let relaunched = MeetingDraftReconciler.actions(for: .init(drafts: [draft], sessions: [session: evidence(.interrupted, .pending)], isLaunch: true))
        XCTAssertEqual(relaunched, [.markInterrupted(draftID: draft.id)])
    }

    func testCrashAfterTheFinalMixPublishesTheHandoffWhenAllowed() {
        let draft = MeetingDraft(recorderSessionID: session, defaultTitle: "A", phase: .awaitingTranscription(.user))
        let finished = evidence(.complete, .complete, finalMix: true)
        XCTAssertEqual(
            MeetingDraftReconciler.actions(for: .init(drafts: [draft], sessions: [session: finished], autoTranscribe: true)),
            [.publishHandoff(draftID: draft.id, sessionDirectory: finished.directoryURL)]
        )
        XCTAssertEqual(
            MeetingDraftReconciler.actions(for: .init(drafts: [draft], sessions: [session: finished], autoTranscribe: false)),
            [],
            "with automatic transcription off the row says Not transcribed instead"
        )
        let summary = MeetingDraftReviewMerger.summary(for: draft, saveState: .saved, run: nil, environment: .init(sessions: [session: finished], autoTranscribe: false))
        XCTAssertEqual(summary.status, "Not transcribed")
        XCTAssertTrue(summary.canTranscribeNow)
    }

    func testCrashAfterTheOutboxWriteLeavesTheRequestToTheConsumer() {
        let draft = MeetingDraft(recorderSessionID: session, defaultTitle: "A", phase: .awaitingTranscription(.user))
        let request = TranscriptionRequest(requestID: requestID, sourceURL: URL(fileURLWithPath: "/tmp/final.m4a"), modelProfileID: "default", draftID: draft.id)
        let actions = MeetingDraftReconciler.actions(for: .init(
            drafts: [draft],
            sessions: [session: evidence(.complete, .complete, finalMix: true)],
            pendingRequests: [request]
        ))
        XCTAssertEqual(actions, [])
        // A legacy request without the draft ID is still recognised by its
        // deterministic ID.
        let legacy = TranscriptionRequest(requestID: requestID, sourceURL: URL(fileURLWithPath: "/tmp/final.m4a"), modelProfileID: "default")
        XCTAssertEqual(MeetingDraftReconciler.actions(for: .init(drafts: [draft], pendingRequests: [legacy])), [])
    }

    func testCrashAfterTheJobWriteBindsTheDraftAsRecovered() {
        let draft = MeetingDraft(recorderSessionID: session, defaultTitle: "A", phase: .awaitingTranscription(.user))
        let run = storedRun(draftID: draft.id, state: .queued)
        XCTAssertEqual(
            MeetingDraftReconciler.actions(for: .init(drafts: [draft], runs: [run], isLaunch: true)),
            [.bindQueued(draftID: draft.id, runID: run.job.runID, recovered: true)]
        )
    }

    func testCrashAfterTerminalCompletionAttachesAndAppliesTheTitle() {
        var draft = MeetingDraft(recorderSessionID: session, defaultTitle: "A", phase: .awaitingTranscription(.user))
        draft.title = "Named while recording"
        let run = storedRun(draftID: draft.id, state: .complete, title: "A")
        draft.phase = .queued(runID: run.job.runID)
        XCTAssertEqual(MeetingDraftReconciler.actions(for: .init(drafts: [draft], runs: [run])), [
            .attach(draftID: draft.id, runID: run.job.runID, meetingKey: run.job.meetingDirectoryURL.lastPathComponent, recovered: false),
            .applyTitle(draftID: draft.id, runID: run.job.runID, title: "Named while recording"),
        ])
    }

    func testFailedAndNoSpeechRunsStillAttach() {
        for state in [TranscriptionJobState.failed, .cancelled] {
            let draft = MeetingDraft(recorderSessionID: session, defaultTitle: "A", phase: .awaitingTranscription(.user))
            let run = storedRun(draftID: draft.id, state: state, transcript: false)
            XCTAssertEqual(
                MeetingDraftReconciler.actions(for: .init(drafts: [draft], runs: [run])),
                [.attach(draftID: draft.id, runID: run.job.runID, meetingKey: run.job.meetingDirectoryURL.lastPathComponent, recovered: false)],
                "\(state)"
            )
        }
    }

    func testADraftWithNothingLeftIsOrphanedAndRestoredIfItsRecordingReturns() {
        let draft = MeetingDraft(recorderSessionID: session, defaultTitle: "A", phase: .awaitingTranscription(.sleep))
        XCTAssertEqual(MeetingDraftReconciler.actions(for: .init(drafts: [draft])), [.orphan(draftID: draft.id, reason: .recordingMissing)])

        var orphan = draft
        orphan.phase = .orphaned(.recordingMissing)
        XCTAssertEqual(MeetingDraftReconciler.actions(for: .init(drafts: [orphan])), [], "orphaning is not repeated")
        XCTAssertEqual(
            MeetingDraftReconciler.actions(for: .init(drafts: [orphan], sessions: [session: evidence(.interrupted, .pending)])),
            [.restore(draftID: draft.id)]
        )
        let summary = MeetingDraftReviewMerger.summary(for: orphan, saveState: .saved, run: nil, environment: .init())
        XCTAssertEqual(summary.status, "Notes only")
        XCTAssertTrue(summary.canDeleteDraft)
    }

    private func evidence(_ capture: CaptureState, _ processing: ProcessingState, finalMix: Bool = false) -> RecorderSessionEvidence {
        RecorderSessionEvidence(
            sessionID: session,
            directoryURL: URL(fileURLWithPath: "/tmp/recordings/2026-11-19 10-00-00 +0000"),
            captureState: capture,
            processingState: processing,
            hasFinalMix: finalMix
        )
    }

    private func storedRun(draftID: UUID, state: TranscriptionJobState, title: String? = nil, transcript: Bool = true) -> StoredTranscriptRun {
        let runID = UUID()
        let job = TranscriptionJob(
            runID: runID,
            request: TranscriptionRequest(requestID: requestID, sourceURL: URL(fileURLWithPath: "/tmp/final.m4a"), modelProfileID: "default", draftID: draftID),
            sourceSnapshotURL: URL(fileURLWithPath: "/tmp/store/meeting--abc/source.m4a"),
            runDirectoryURL: URL(fileURLWithPath: "/tmp/store/meeting--abc/runs/\(runID.uuidString)"),
            sourceFingerprint: "a",
            modelFingerprint: "b",
            configurationFingerprint: "c",
            state: state
        )
        return StoredTranscriptRun(job: job, transcript: transcript && state == .complete ? sampleTranscript(id: runID.uuidString, title: title) : nil)
    }
}

/// The lifecycle end to end, against a real coordinator and transcript store.
@MainActor
final class MeetingDraftLifecycleTests: XCTestCase {
    private var root: URL!
    private var storeURL: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Scribe Lifecycle \(UUID().uuidString)", isDirectory: true)
        storeURL = root.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    func testCaptureEventsMoveADraftThroughEveryStopReason() async throws {
        let lifecycle = await makeLifecycle()
        for reason in MeetingStopReason.allCases where reason != .interrupted {
            let session = UUID()
            let started = await lifecycle.captureStarted(sessionID: session, startedAt: Date(), title: nil, sessionName: "2026-11-19 10-00-00 +0000")
            XCTAssertEqual(started.defaultTitle, "2026-11-19 10-00-00 +0000", "the dated session name when there is no calendar title")
            XCTAssertEqual(lifecycle.liveCapture?.sessionID, session)
            lifecycle.capturePaused(true, sessionID: session)
            XCTAssertEqual(lifecycle.liveCapture?.isPaused, true)
            // Resume re-reports recording for the same session.
            let resumed = await lifecycle.captureStarted(sessionID: session, startedAt: Date(), title: nil, sessionName: "other")
            XCTAssertEqual(resumed.id, started.id)
            await lifecycle.captureStopped(sessionID: session, reason: reason)
            XCTAssertEqual(lifecycle.drafts[started.id]?.phase, .awaitingTranscription(reason))
            XCTAssertNil(lifecycle.liveCapture)
        }
        XCTAssertEqual(lifecycle.drafts.count, MeetingStopReason.allCases.count - 1, "one draft per session, never one per resume")
    }

    func testACommitFailureIsRecordedOnTheDraft() async throws {
        let lifecycle = await makeLifecycle()
        let session = UUID()
        let draft = await lifecycle.captureStarted(sessionID: session, startedAt: Date(), title: "Planning", sessionName: "x")
        XCTAssertEqual(draft.defaultTitle, "Planning")
        await lifecycle.captureFailed(sessionID: session, message: "The disk could not be written.")
        let failed = try XCTUnwrap(lifecycle.drafts[draft.id])
        XCTAssertEqual(failed.captureFailure, "The disk could not be written.")
        let summary = MeetingDraftReviewMerger.summary(for: failed, saveState: .saved, run: nil, environment: .init())
        XCTAssertEqual(summary.status, "Recording could not be finished")
        XCTAssertEqual(summary.explanation, "The disk could not be written.")
    }

    func testSelectionAndTitleHoldFromPlaceholderToCompleteToRerunAndRelaunch() async throws {
        let draftsDirectory = root.appendingPathComponent("drafts", isDirectory: true)
        let lifecycle = await makeLifecycle(draftsDirectory: draftsDirectory)
        let transcripts = TranscriptStore(storeDirectoryURL: storeURL)
        let coordinator = try TranscriptionCoordinator(configuration: .init(transcriptStoreURL: storeURL), stageRunner: TitledTranscriptRunner())
        let session = UUID()
        let startedAt = Date()
        let draft = await lifecycle.captureStarted(sessionID: session, startedAt: startedAt, title: "Calendar name", sessionName: "x")
        let rowKey = draft.id.uuidString

        // Recording: a pinned placeholder row that can be renamed.
        var files = rows(lifecycle, transcripts)
        XCTAssertEqual(files.map(\.id), [rowKey])
        XCTAssertEqual(files[0].jobState, .recording(startedAt: startedAt, isPaused: false))
        XCTAssertTrue(files[0].isPlaceholder)
        let viewModel = TranscriptViewModel(files: files, playback: LifecyclePlayback(), draftEditor: lifecycle)
        XCTAssertEqual(viewModel.selectedFileID, rowKey)
        _ = try await lifecycle.setTitle(draftID: draft.id, title: "Board sync", basedOnRevision: draft.revision, previousTitle: nil)
        viewModel.reload(files: rows(lifecycle, transcripts))
        XCTAssertEqual(viewModel.selectedFile?.displayName, "Board sync")

        // Stopped, handed off and queued: same row.
        await lifecycle.captureStopped(sessionID: session, reason: .user)
        let source = root.appendingPathComponent("final.m4a")
        try Data("meeting".utf8).write(to: source)
        let job = try await coordinator.enqueue(TranscriptionRequest(
            requestID: TranscriptionRequest.recorderRequestID(forSession: session),
            sourceURL: source,
            modelProfileID: "default",
            title: "Calendar name",
            draftID: draft.id
        ))
        await lifecycle.jobQueued(job)
        XCTAssertEqual(lifecycle.drafts[draft.id]?.phase, .queued(runID: job.runID))
        viewModel.reload(files: rows(lifecycle, transcripts))
        XCTAssertEqual(viewModel.selectedFileID, rowKey)
        XCTAssertEqual(viewModel.selectedFile?.runID, job.runID.uuidString)

        // Complete: attached, and the transcript takes the person's title.
        await coordinator.runPending()
        await reconcile(lifecycle, transcripts)
        XCTAssertEqual(lifecycle.drafts[draft.id]?.phase, .attached(meetingKey: job.meetingDirectoryURL.lastPathComponent, runID: job.runID))
        XCTAssertEqual(transcripts.run(withRunID: job.runID)?.transcript?.title, "Board sync")
        viewModel.reload(files: rows(lifecycle, transcripts))
        XCTAssertEqual(viewModel.files.map(\.id), [rowKey])
        XCTAssertEqual(viewModel.selectedFileID, rowKey)
        XCTAssertEqual(viewModel.selectedFile?.displayName, "Board sync")

        // A rerun opens under the same title and keeps the row.
        let completed = try XCTUnwrap(transcripts.run(withRunID: job.runID)?.job)
        let rerun = try await coordinator.retranscribe(completed, modelProfileID: "default", speakerCount: .automatic, title: lifecycle.drafts[draft.id]?.title)
        await coordinator.runPending()
        await reconcile(lifecycle, transcripts)
        XCTAssertEqual(transcripts.run(withRunID: rerun.runID)?.transcript?.title, "Board sync")
        viewModel.reload(files: rows(lifecycle, transcripts))
        XCTAssertEqual(viewModel.files.map(\.id), [rowKey])
        XCTAssertEqual(viewModel.selectedFile?.runID, rerun.runID.uuidString)
        XCTAssertEqual(lifecycle.drafts[draft.id]?.phase.runID, job.runID, "a rerun never re-opens the draft lifecycle")

        // Relaunch: a new store and lifecycle produce the same row key.
        await lifecycle.flushAll()
        let relaunched = await makeLifecycle(draftsDirectory: draftsDirectory)
        await reconcile(relaunched, transcripts, isLaunch: true)
        XCTAssertEqual(rows(relaunched, transcripts).map(\.id), [rowKey])
        XCTAssertEqual(rows(relaunched, transcripts).first?.displayName, "Board sync")
    }

    func testATitleEditedDuringAttachmentIsApplied() async throws {
        let lifecycle = await makeLifecycle()
        let transcripts = TranscriptStore(storeDirectoryURL: storeURL)
        let coordinator = try TranscriptionCoordinator(configuration: .init(transcriptStoreURL: storeURL), stageRunner: TitledTranscriptRunner())
        let session = UUID()
        let draft = await lifecycle.captureStarted(sessionID: session, startedAt: Date(), title: nil, sessionName: "x")
        await lifecycle.captureStopped(sessionID: session, reason: .user)
        let source = root.appendingPathComponent("final.m4a")
        try Data("audio".utf8).write(to: source)
        let job = try await coordinator.enqueue(TranscriptionRequest(sourceURL: source, modelProfileID: "default", draftID: draft.id))
        await coordinator.runPending()
        await reconcile(lifecycle, transcripts)
        XCTAssertNil(transcripts.run(withRunID: job.runID)?.transcript?.title)

        let attached = try XCTUnwrap(lifecycle.drafts[draft.id])
        _ = try await lifecycle.setTitle(draftID: draft.id, title: "Late name", basedOnRevision: attached.revision - 1, previousTitle: nil)
        await reconcile(lifecycle, transcripts)
        XCTAssertEqual(transcripts.run(withRunID: job.runID)?.transcript?.title, "Late name")
    }

    func testAConflictingTitleEditIsRefused() async throws {
        let lifecycle = await makeLifecycle()
        let draft = await lifecycle.captureStarted(sessionID: UUID(), startedAt: Date(), title: nil, sessionName: "x")
        _ = try await lifecycle.setTitle(draftID: draft.id, title: "Window", basedOnRevision: draft.revision, previousTitle: nil)
        do {
            _ = try await lifecycle.setTitle(draftID: draft.id, title: "Panel", basedOnRevision: draft.revision, previousTitle: nil)
            XCTFail("A title changed since it was read must not be overwritten")
        } catch let error as MeetingDraftLifecycle.LifecycleError {
            XCTAssertEqual(error, .titleConflict)
        }
        XCTAssertEqual(lifecycle.drafts[draft.id]?.title, "Window")
    }

    func testAnInterruptedRecordingIsRecoveredAtLaunchAndANotesOnlyDraftCanBeDeleted() async throws {
        let draftsDirectory = root.appendingPathComponent("drafts", isDirectory: true)
        let lifecycle = await makeLifecycle(draftsDirectory: draftsDirectory)
        let draft = await lifecycle.captureStarted(sessionID: UUID(), startedAt: Date(), title: nil, sessionName: "x")
        await lifecycle.flushAll()

        // The app died mid-recording and nothing of the session survived.
        let relaunched = await makeLifecycle(draftsDirectory: draftsDirectory)
        let transcripts = TranscriptStore(storeDirectoryURL: storeURL)
        await reconcile(relaunched, transcripts, isLaunch: true)
        let recovered = try XCTUnwrap(relaunched.drafts[draft.id])
        XCTAssertTrue(recovered.recovered)
        XCTAssertEqual(recovered.phase, .orphaned(.recordingMissing))

        let file = try XCTUnwrap(rows(relaunched, transcripts).first)
        XCTAssertEqual(file.sidebarDetail(), "Notes only")
        let viewModel = TranscriptViewModel(files: [file], playback: LifecyclePlayback(), draftEditor: relaunched)
        XCTAssertTrue(viewModel.canDeleteDraft(file))
        XCTAssertFalse(viewModel.canDelete(file), "placeholders have no transcript to delete")
        XCTAssertFalse(viewModel.canRetranscribe(file))
        await viewModel.deleteDraft(fileID: file.id)
        XCTAssertTrue(viewModel.files.isEmpty)
        XCTAssertNil(relaunched.drafts[draft.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: draftsDirectory.appendingPathComponent("\(draft.id.uuidString).json").path))
    }

    func testAWriteErrorShowsNotSavedUntilRetried() async throws {
        let disk = ToggleableDisk()
        let store = MeetingDraftStore(directoryURL: root.appendingPathComponent("drafts"), writeFile: disk.write)
        let lifecycle = await MeetingDraftLifecycle(store: store, transcriptStore: TranscriptStore(storeDirectoryURL: storeURL))
        let draft = await lifecycle.captureStarted(sessionID: UUID(), startedAt: Date(), title: nil, sessionName: "x")
        disk.failing = true
        _ = try await lifecycle.setTitle(draftID: draft.id, title: "Unsaved", basedOnRevision: draft.revision, previousTitle: nil)
        await lifecycle.flush(draftID: draft.id)
        let failing = rows(lifecycle, TranscriptStore(storeDirectoryURL: storeURL))
        XCTAssertEqual(failing.first?.sidebarDetail(), "Not saved")
        XCTAssertEqual(failing.first?.displayName, "Unsaved", "the edit is still shown")

        disk.failing = false
        let summary = await lifecycle.retrySave(draftID: draft.id)
        XCTAssertEqual(summary?.saveState, .saved)
        XCTAssertNotEqual(rows(lifecycle, TranscriptStore(storeDirectoryURL: storeURL)).first?.sidebarDetail(), "Not saved")
    }

    func testTheLiveRecordingIsPinnedAboveNewerRows() async throws {
        let lifecycle = await makeLifecycle()
        let older = await lifecycle.captureStarted(sessionID: UUID(), startedAt: Date(timeIntervalSinceNow: -60), title: nil, sessionName: "a")
        await lifecycle.captureStopped(sessionID: older.recorderSessionID, reason: .user)
        let live = await lifecycle.captureStarted(sessionID: UUID(), startedAt: Date(timeIntervalSinceNow: -120), title: nil, sessionName: "b")
        let files = rows(lifecycle, TranscriptStore(storeDirectoryURL: storeURL))
        XCTAssertEqual(files.first?.id, live.id.uuidString)
        XCTAssertTrue(files.first?.isRecording == true)
    }

    // MARK: - Helpers

    private func makeLifecycle(draftsDirectory: URL? = nil) async -> MeetingDraftLifecycle {
        let store = MeetingDraftStore(directoryURL: draftsDirectory ?? root.appendingPathComponent("drafts-\(UUID().uuidString)"))
        return await MeetingDraftLifecycle(store: store, transcriptStore: TranscriptStore(storeDirectoryURL: storeURL))
    }

    private func rows(_ lifecycle: MeetingDraftLifecycle, _ transcripts: TranscriptStore) -> [TranscriptReviewFile] {
        MeetingDraftReviewMerger.files(
            drafts: lifecycle.allDrafts,
            saveStates: lifecycle.saveStates,
            runs: transcripts.runs(),
            environment: .init(live: lifecycle.liveCapture)
        )
    }

    private func reconcile(_ lifecycle: MeetingDraftLifecycle, _ transcripts: TranscriptStore, isLaunch: Bool = false) async {
        await lifecycle.reconcile(sessions: [:], pendingRequests: [], runs: transcripts.runs(), autoTranscribe: true, isLaunch: isLaunch)
    }
}

// MARK: - Doubles

/// Writes a canonical transcript titled from the request at the assembling
/// stage, the way the real assembly runner does.
private struct TitledTranscriptRunner: TranscriptionStageRunning {
    func run(stage: TranscriptionJobState, job: TranscriptionJob) async throws -> TranscriptionStageOutput {
        guard stage == .assembling else { return .init() }
        let url = job.runDirectoryURL.appendingPathComponent(TranscriptRunArtifact.canonicalTranscript)
        try CanonicalTranscriptCodec.encode(sampleTranscript(id: job.runID.uuidString, title: job.request.title)).write(to: url)
        return .init(artifactURL: url)
    }
}

private final class ToggleableDisk: @unchecked Sendable {
    private let lock = NSLock()
    private var _failing = false
    var failing: Bool {
        get { lock.withLock { _failing } }
        set { lock.withLock { _failing = newValue } }
    }

    var write: MeetingDraftStore.FileWriter {
        { [self] data, url in
            if failing { throw CocoaError(.fileWriteOutOfSpace, userInfo: [NSLocalizedDescriptionKey: "The disk full error"]) }
            try MeetingDraftStore.writePrivateFile(data, url)
        }
    }
}

@MainActor
private final class LifecyclePlayback: TranscriptPlaybackSeeking {
    func load(sourceSnapshotURL: URL) {}
    func seek(toMilliseconds milliseconds: Int) {}
}

private func sampleTranscript(id: String, title: String?) -> CanonicalTranscript {
    CanonicalTranscript(
        transcriptID: id,
        revision: 1,
        title: title,
        status: .complete,
        createdAt: "2026-11-19T10:00:00Z",
        source: TranscriptSource(filename: "final.m4a", durationMs: 1_000, checksum: "sha256:meeting"),
        language: "en",
        languageSource: .detected,
        speakers: [TranscriptSpeaker(id: "speaker_1", identityAssignment: .unmatched, labelSnapshot: "Speaker 1")],
        segments: [
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

private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
