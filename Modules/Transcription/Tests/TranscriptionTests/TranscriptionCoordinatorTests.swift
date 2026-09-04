import Foundation
import ScribeAppCore
import XCTest
@testable import Transcription

final class TranscriptionCoordinatorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Scribe Coordinator \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testRecoveryAtEveryStageResumesOnlyMissingStages() async throws {
        let source = root.appendingPathComponent("source.flac")
        try Data("audio bytes".utf8).write(to: source)
        let request = TranscriptionRequest(sourceURL: source, modelProfileID: "parakeet-v3")
        let fingerprint = try ImportFingerprint(fileAt: source, configuration: .init(modelProfileID: request.modelProfileID))
        let modelFingerprint = FileContentHash.sha256(of: Data(request.modelProfileID.utf8))

        for (index, interruptedStage) in TranscriptionJobState.processingStages.enumerated() {
            let store = root.appendingPathComponent("store-\(interruptedStage.rawValue)", isDirectory: true)
            let run = store
                .appendingPathComponent("meeting--\(fingerprint.sourceID)", isDirectory: true)
                .appendingPathComponent("runs", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let checkpoints = Dictionary(uniqueKeysWithValues: TranscriptionJobState.processingStages.prefix(index).map { stage in
                (stage, TranscriptionStageCheckpoint(
                    stage: stage,
                    sourceFingerprint: fingerprint.contentHash,
                    modelFingerprint: modelFingerprint,
                    configurationFingerprint: fingerprint.configurationHash
                ))
            })
            let interrupted = TranscriptionJob(
                request: request,
                sourceSnapshotURL: source,
                runDirectoryURL: run,
                sourceFingerprint: fingerprint.contentHash,
                modelFingerprint: modelFingerprint,
                configurationFingerprint: fingerprint.configurationHash,
                state: interruptedStage,
                checkpoints: checkpoints
            )
            try write(interrupted)

            let runner = RecordingRunner()
            let coordinator = try TranscriptionCoordinator(
                configuration: .init(transcriptStoreURL: store),
                stageRunner: runner
            )
            let pendingIDs = await coordinator.pendingJobs().map(\.id)
            XCTAssertEqual(pendingIDs, [interrupted.id], "\(interruptedStage) must recover at launch")
            await coordinator.runPending()

            let recoveredJob = await coordinator.job(id: interrupted.id)
            let completed = try XCTUnwrap(recoveredJob)
            XCTAssertEqual(completed.state, .complete, "\(interruptedStage)")
            let executed = await runner.stages()
            XCTAssertEqual(executed, Array(TranscriptionJobState.processingStages.dropFirst(index)), "\(interruptedStage) duplicated a checkpoint")
        }
    }

    func testActiveCaptureDefersQueuedWorkUntilItEnds() async throws {
        let store = root.appendingPathComponent("Meeting Transcripts", isDirectory: true)
        let source = root.appendingPathComponent("meeting.flac")
        try Data("audio bytes".utf8).write(to: source)
        let scheduler = TestScheduler(captureActive: true)
        let runner = RecordingRunner()
        let coordinator = try TranscriptionCoordinator(configuration: .init(transcriptStoreURL: store), scheduler: scheduler, stageRunner: runner)
        let job = try await coordinator.enqueue(.init(sourceURL: source, modelProfileID: "parakeet-v3"))

        await coordinator.runPending()
        let deferredStages = await runner.stages()
        let deferredState = await coordinator.job(id: job.id)?.state
        XCTAssertEqual(deferredStages, [])
        XCTAssertEqual(deferredState, .queued)

        await scheduler.setCaptureActive(false)
        await coordinator.runPending()
        let completedState = await coordinator.job(id: job.id)?.state
        let finishedStages = await runner.stages()
        XCTAssertEqual(completedState, .complete)
        XCTAssertEqual(finishedStages, TranscriptionJobState.processingStages)
    }

    func testRetryCreatesNewRunAndReusesCompatibleCheckpoints() async throws {
        let store = root.appendingPathComponent("Meeting Transcripts", isDirectory: true)
        let source = root.appendingPathComponent("meeting.flac")
        try Data("audio bytes".utf8).write(to: source)
        let runner = RecordingRunner(failingAt: .diarizing)
        let coordinator = try TranscriptionCoordinator(configuration: .init(transcriptStoreURL: store), stageRunner: runner)
        let original = try await coordinator.enqueue(.init(sourceURL: source, modelProfileID: "parakeet-v3"))
        await coordinator.runPending()
        let originalState = await coordinator.job(id: original.id)?.state
        XCTAssertEqual(originalState, .failed)

        let retry = try await coordinator.retry(jobID: original.id)
        XCTAssertNotEqual(retry.runID, original.runID)
        XCTAssertEqual(Set(retry.checkpoints.keys), Set([.preparing, .transcribing, .reconcilingTimings]))
        XCTAssertEqual(retry.retryOfRunID, original.runID)
    }

    func testCancellationAtABoundaryKeepsAlreadyCommittedCheckpoints() async throws {
        let store = root.appendingPathComponent("Meeting Transcripts", isDirectory: true)
        let source = root.appendingPathComponent("meeting.flac")
        try Data("audio bytes".utf8).write(to: source)
        let runner = BoundaryCancellingRunner(after: .transcribing)
        let coordinator = try TranscriptionCoordinator(configuration: .init(transcriptStoreURL: store), stageRunner: runner)
        await runner.connect(to: coordinator)
        let job = try await coordinator.enqueue(.init(sourceURL: source, modelProfileID: "parakeet-v3"))

        await coordinator.runPending()

        let persistedJob = await coordinator.job(id: job.id)
        let saved = try XCTUnwrap(persistedJob)
        XCTAssertEqual(saved.state, .cancelled)
        XCTAssertEqual(Set(saved.checkpoints.keys), Set([.preparing, .transcribing]))
        XCTAssertNil(saved.failure)
    }

    private func write(_ job: TranscriptionJob) throws {
        try FileManager.default.createDirectory(at: job.runDirectoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(job).write(to: job.jobFileURL)
    }
}

private actor RecordingRunner: TranscriptionStageRunning {
    private var executed: [TranscriptionJobState] = []
    private let failingAt: TranscriptionJobState?

    init(failingAt: TranscriptionJobState? = nil) { self.failingAt = failingAt }

    func run(stage: TranscriptionJobState, job: TranscriptionJob) async throws -> TranscriptionStageOutput {
        executed.append(stage)
        if stage == failingAt { throw TestFailure() }
        return .init()
    }

    func stages() -> [TranscriptionJobState] { executed }
}

private struct TestFailure: LocalizedError { var errorDescription: String? { "intentional test failure" } }

private actor BoundaryCancellingRunner: TranscriptionStageRunning {
    private let cancellationStage: TranscriptionJobState
    private var coordinator: TranscriptionCoordinator?

    init(after cancellationStage: TranscriptionJobState) { self.cancellationStage = cancellationStage }
    func connect(to coordinator: TranscriptionCoordinator) { self.coordinator = coordinator }

    func run(stage: TranscriptionJobState, job: TranscriptionJob) async throws -> TranscriptionStageOutput {
        if stage == cancellationStage, let coordinator { try? await coordinator.cancel(jobID: job.id) }
        return .init()
    }
}

private actor TestScheduler: ProcessingScheduler {
    private var captureActive: Bool

    init(captureActive: Bool) { self.captureActive = captureActive }
    func setCaptureActive(_ active: Bool) { captureActive = active }
    func isCaptureActive() async -> Bool { captureActive }
    func requestDeferral(for job: ProcessingJobDescriptor) async -> ProcessingJobDeferral {
        captureActive ? .deferUntilCaptureEnds : .startNow
    }
    func jobControlSignals(for jobID: UUID) async -> AsyncStream<ProcessingJobControlSignal> { AsyncStream { _ in } }
}
