import Foundation
import ScribeAppCore
import XCTest
@testable import Transcription

/// The deterministic half of the capture-coexistence gate.
///
/// `Tools/CaptureCoexistence` measures the real-time property — that a
/// controlled two-hour recording loses no audio with transcription queued — and
/// needs two hours to say so. These tests pin the contract that makes that
/// result hold: transcription starts nothing while capture is active, a run that
/// is already going stops at its next persisted stage boundary rather than being
/// killed, and everything resumes once the recording ends.
final class CaptureCoexistenceContractTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Scribe Coexistence \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// A recording that starts mid-run suspends the job at the next boundary and
    /// keeps every stage it had already committed.
    func testARecordingSuspendsARunningJobAtItsNextStageBoundary() async throws {
        let scheduler = CoexistenceScheduler(captureActive: false)
        // The recording starts while diarization is running, so that stage is
        // genuinely in flight rather than merely queued.
        let runner = SuspendingStageRunner(scheduler: scheduler, startsCaptureDuring: .diarizing)
        let coordinator = try TranscriptionCoordinator(
            configuration: .init(transcriptStoreURL: root.appending(path: "store", directoryHint: .isDirectory)),
            scheduler: scheduler,
            stageRunner: runner
        )
        let source = try writeSource(named: "call.wav")
        let job = try await coordinator.enqueue(TranscriptionRequest(sourceURL: source, modelProfileID: "test"))

        await coordinator.runPending()

        let suspendedJob = await coordinator.job(id: job.id)
        let suspended = try XCTUnwrap(suspendedJob)
        XCTAssertEqual(suspended.state, .queued, "a suspended job returns to the queue, it is not failed or cancelled")
        // The stage that was in flight is allowed to finish and commit; the
        // boundary is the *next* one. Everything committed stays on disk, so
        // resuming does not repeat work the machine already paid for.
        let suspendedAt: [TranscriptionJobState] = [.preparing, .transcribing, .reconcilingTimings, .diarizing]
        XCTAssertEqual(Set(suspended.checkpoints.keys), Set(suspendedAt))
        let stagesRun = await runner.stagesRun
        XCTAssertEqual(stagesRun, suspendedAt)
        XCTAssertNil(suspended.checkpoints[.assembling], "the stage after the boundary must not have started")

        // Offering the queue work while the recording continues starts nothing.
        await coordinator.runPending()
        let stagesAfterOffer = await runner.stagesRun
        XCTAssertEqual(stagesAfterOffer, suspendedAt, "no further stage may start while capture is active")
        let pendingIDs = await coordinator.pendingJobs().map(\.id)
        XCTAssertEqual(pendingIDs, [job.id])

        // The recording ends; the job resumes from where it stopped.
        await scheduler.setCaptureActive(false)
        await coordinator.runPending()

        let finishedJob = await coordinator.job(id: job.id)
        let finished = try XCTUnwrap(finishedJob)
        XCTAssertEqual(finished.state, .complete)
        let allStages = await runner.stagesRun
        XCTAssertEqual(allStages, TranscriptionJobState.processingStages, "resume continues the sequence rather than restarting it")
    }

    /// Recording priority is asked for per job, not assumed once: a second job
    /// queued during the same recording is deferred too.
    func testEveryQueuedJobIsOfferedToTheSchedulerSeparately() async throws {
        let scheduler = CoexistenceScheduler(captureActive: true)
        let runner = SuspendingStageRunner(scheduler: scheduler, startsCaptureDuring: nil)
        let coordinator = try TranscriptionCoordinator(
            configuration: .init(transcriptStoreURL: root.appending(path: "store", directoryHint: .isDirectory)),
            scheduler: scheduler,
            stageRunner: runner
        )
        for index in 0..<3 {
            _ = try await coordinator.enqueue(TranscriptionRequest(
                sourceURL: try writeSource(named: "call \(index).wav"),
                modelProfileID: "test"
            ))
        }

        await coordinator.runPending()
        let stagesDuringCapture = await runner.stagesRun
        XCTAssertTrue(stagesDuringCapture.isEmpty)
        let pendingCount = await coordinator.pendingJobs().count
        XCTAssertEqual(pendingCount, 3)
        let deferralsDuringCapture = await scheduler.deferralRequests
        XCTAssertEqual(deferralsDuringCapture, 1, "the queue stops at the first refusal rather than spinning through it")

        await scheduler.setCaptureActive(false)
        await coordinator.runPending()
        let remaining = await coordinator.pendingJobs()
        XCTAssertTrue(remaining.isEmpty)
        let totalDeferrals = await scheduler.deferralRequests
        XCTAssertEqual(totalDeferrals, 4)
    }

    /// A published recording becomes a queued job, and is claimed only once that
    /// job is durable.
    func testAPublishedRecordingIsQueuedAndOnlyThenClaimed() async throws {
        let coordinator = try TranscriptionCoordinator(
            configuration: .init(transcriptStoreURL: root.appending(path: "store", directoryHint: .isDirectory)),
            stageRunner: ScriptedWorkerStageRunner(hostStageRunner: TranscriptAssemblyStageRunner())
        )
        let final = try writeSource(named: "final.flac")
        let outbox = RecordingHandoffSource(requests: [
            TranscriptionRequest(
                sourceURL: final,
                modelProfileID: "parakeet-v3",
                provenance: TranscriptionProvenance(producerID: "scribe.recorder", sessionID: UUID())
            ),
        ])

        let outcome = try await TranscriptionHandoffConsumer(source: outbox).drain(into: coordinator)

        XCTAssertEqual(outcome.queued.count, 1)
        let claimed = await outbox.claimed
        XCTAssertEqual(claimed, outcome.queued)
        let firstPending = await coordinator.pendingJobs().first
        let queued = try XCTUnwrap(firstPending)
        XCTAssertEqual(queued.request.provenance?.producerID, "scribe.recorder")

        await coordinator.runPending()
        let finalState = await coordinator.job(id: queued.id)?.state
        XCTAssertEqual(finalState, .complete)
    }

    /// A request that cannot be queued stays in the outbox. Losing a finished
    /// meeting silently is worse than queueing it twice.
    func testARequestThatCannotBeQueuedIsNotClaimed() async throws {
        let coordinator = try TranscriptionCoordinator(
            configuration: .init(transcriptStoreURL: root.appending(path: "store", directoryHint: .isDirectory)),
            stageRunner: ScriptedWorkerStageRunner(hostStageRunner: TranscriptAssemblyStageRunner())
        )
        let outbox = RecordingHandoffSource(requests: [
            // The recorder published it, then the file went away before
            // transcription got to it: snapshotting has nothing to copy.
            TranscriptionRequest(sourceURL: root.appending(path: "vanished.flac"), modelProfileID: "parakeet-v3"),
        ])

        let outcome = try await TranscriptionHandoffConsumer(source: outbox).drain(into: coordinator)

        XCTAssertTrue(outcome.queued.isEmpty)
        XCTAssertEqual(outcome.failures.count, 1)
        let unclaimed = await outbox.claimed
        XCTAssertTrue(unclaimed.isEmpty, "an unqueued request must survive for the next drain")
        let noJobs = await coordinator.pendingJobs()
        XCTAssertTrue(noJobs.isEmpty)
    }

    private func writeSource(named name: String) throws -> URL {
        let url = root.appending(path: name)
        try Data(repeating: 0x41, count: 4_096).write(to: url)
        return url
    }
}

/// A scheduler that answers the way `ProcessingQueue` does and counts what it
/// was asked, so a test can tell "never started" from "never offered".
private actor CoexistenceScheduler: ProcessingScheduler {
    private var captureActive: Bool
    private(set) var deferralRequests = 0
    private var continuations: [UUID: [UUID: AsyncStream<ProcessingJobControlSignal>.Continuation]] = [:]

    init(captureActive: Bool) { self.captureActive = captureActive }

    func isCaptureActive() async -> Bool { captureActive }

    func requestDeferral(for job: ProcessingJobDescriptor) async -> ProcessingJobDeferral {
        deferralRequests += 1
        return captureActive ? .deferUntilCaptureEnds : .startNow
    }

    func jobControlSignals(for jobID: UUID) async -> AsyncStream<ProcessingJobControlSignal> {
        let token = UUID()
        return AsyncStream { continuation in
            continuations[jobID, default: [:]][token] = continuation
            if captureActive { continuation.yield(.suspend) }
        }
    }

    func setCaptureActive(_ active: Bool) async {
        guard captureActive != active else { return }
        captureActive = active
        let signal: ProcessingJobControlSignal = active ? .suspend : .resume
        for streams in continuations.values {
            for continuation in streams.values { continuation.yield(signal) }
        }
    }
}

/// Starts a recording part-way through a job, then records which stages ran.
private actor SuspendingStageRunner: TranscriptionStageRunning {
    private let scheduler: CoexistenceScheduler
    private let startsCaptureDuring: TranscriptionJobState?
    private(set) var stagesRun: [TranscriptionJobState] = []
    private var hasStartedCapture = false

    init(scheduler: CoexistenceScheduler, startsCaptureDuring: TranscriptionJobState?) {
        self.scheduler = scheduler
        self.startsCaptureDuring = startsCaptureDuring
    }

    func run(stage: TranscriptionJobState, job: TranscriptionJob) async throws -> TranscriptionStageOutput {
        if stage == startsCaptureDuring, !hasStartedCapture {
            hasStartedCapture = true
            await scheduler.setCaptureActive(true)
            // The signal reaches the coordinator on its own task; give it the
            // hop it needs before the stage boundary is evaluated.
            await Task.yield()
            try await Task.sleep(for: .milliseconds(50))
        }
        stagesRun.append(stage)
        return TranscriptionStageOutput()
    }
}

/// Stands in for the recorder's on-disk outbox.
private actor RecordingHandoffSource: TranscriptionHandoffSource {
    private var requests: [TranscriptionRequest]
    private(set) var claimed: [UUID] = []

    init(requests: [TranscriptionRequest]) { self.requests = requests }

    func pendingRequests() async throws -> [TranscriptionRequest] { requests }

    func claim(_ requestID: UUID) async throws {
        requests.removeAll { $0.requestID == requestID }
        claimed.append(requestID)
    }
}
