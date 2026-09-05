import Foundation
import ScribeAppCore
import XCTest
@testable import Transcription

/// Covers the bridge between the coordinator's job stages and the helper's own
/// four-stage run, using the scripted fake worker so these stay fast.
final class WorkerStageRunnerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Scribe Worker Stage Runner \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testAJobRunsFromQueuedToCompleteThroughOneHelperProcess() async throws {
        let events = EventLog()
        let runner = try makeRunner(FakeTranscriptionWorker.healthyRun(), events: events)
        let store = root.appending(path: "Meeting Transcripts", directoryHint: .isDirectory)
        let coordinator = try TranscriptionCoordinator(configuration: .init(transcriptStoreURL: store), stageRunner: runner)
        let job = try await coordinator.enqueue(.init(sourceURL: try makeSource(), modelProfileID: "parakeet-v3"))

        await coordinator.runPending()

        let finalJob = await coordinator.job(id: job.id)
        let completed = try XCTUnwrap(finalJob)
        XCTAssertEqual(completed.state, .complete)
        XCTAssertEqual(
            Set(completed.checkpoints.keys),
            Set(TranscriptionJobState.processingStages),
            "every job stage needs a checkpoint, including the two the helper does not own"
        )
        XCTAssertEqual(
            completed.checkpoints[.transcribing]?.artifactURL,
            completed.runDirectoryURL.appending(path: "transcript.json")
        )
        XCTAssertEqual(
            completed.checkpoints[.matchingSpeakers]?.artifactURL,
            completed.runDirectoryURL.appending(path: "embeddings.json")
        )
        // Stage progress reaches the host as the shared handoff event.
        let observed = events.stages()
        XCTAssertEqual(observed.filter { $0 != "reconcilingTimings" && $0 != "assembling" }, ["prepare", "transcribe", "diarize", "embed"])
        await runner.shutdown()
    }

    func testAHelperCrashFailsTheJobAndLeavesTheEarlierCheckpointForARetry() async throws {
        let worker = FakeTranscriptionWorker(steps: [
            .emit(kind: "stage_result", payload: #"{"stage":"prepare","status":"complete","resultPath":"prepare.json"}"#),
            .emit(kind: "progress", payload: #"{"stage":"transcribe","state":"started"}"#),
            .crash,
        ])
        let runner = try makeRunner(worker)
        let store = root.appending(path: "Meeting Transcripts", directoryHint: .isDirectory)
        let coordinator = try TranscriptionCoordinator(configuration: .init(transcriptStoreURL: store), stageRunner: runner)
        let job = try await coordinator.enqueue(.init(sourceURL: try makeSource(), modelProfileID: "parakeet-v3"))

        await coordinator.runPending()

        let finalJob = await coordinator.job(id: job.id)
        let failed = try XCTUnwrap(finalJob)
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.failure?.code, "transcription.stage.transcribing")
        XCTAssertNotNil(failed.checkpoints[.preparing], "the committed prepare checkpoint must survive the crash")
        XCTAssertNil(failed.checkpoints[.transcribing])

        let retry = try await coordinator.retry(jobID: job.id)
        XCTAssertEqual(Set(retry.checkpoints.keys), [.preparing], "a retry reuses only the compatible completed stage")
        XCTAssertNotEqual(retry.runDirectoryURL, failed.runDirectoryURL, "a rerun gets its own run directory")
        await runner.shutdown()
    }

    func testAStageTheHelperNeverReportsIsAStructuredProtocolFailure() async throws {
        let worker = FakeTranscriptionWorker(steps: [
            .emit(kind: "stage_result", payload: #"{"stage":"prepare","status":"complete","resultPath":"prepare.json"}"#),
            .emit(kind: "stage_result", payload: #"{"stage":"complete","status":"complete"}"#),
        ])
        let runner = try makeRunner(worker)
        let store = root.appending(path: "Meeting Transcripts", directoryHint: .isDirectory)
        let coordinator = try TranscriptionCoordinator(configuration: .init(transcriptStoreURL: store), stageRunner: runner)
        let job = try await coordinator.enqueue(.init(sourceURL: try makeSource(), modelProfileID: "parakeet-v3"))

        await coordinator.runPending()

        let finalJob = await coordinator.job(id: job.id)
        let failed = try XCTUnwrap(finalJob)
        XCTAssertEqual(failed.state, .failed)
        XCTAssertNotNil(failed.checkpoints[.preparing])
        await runner.shutdown()
    }

    func testNewJobsResolveTheCurrentInstallationWithoutRecreatingRunner() async throws {
        let installation = try FakeTranscriptionWorker.healthyRun().install(in: root.appending(path: "helper"))
        let provider = InstallationRequests(installation: installation)
        let runner = WorkerStageRunner(
            configuration: .init(installation: WorkerInstallation(executableURL: root.appending(path: "missing-helper"))),
            installationProvider: { await provider.resolve() }
        )
        let coordinator = try TranscriptionCoordinator(configuration: .init(transcriptStoreURL: root.appending(path: "store")), stageRunner: runner)
        for _ in 0..<2 {
            let job = try await coordinator.enqueue(.init(sourceURL: try makeSource(), modelProfileID: "parakeet-v3"))
            await coordinator.runPending()
            let completed = await coordinator.job(id: job.id)
            XCTAssertEqual(completed?.state, .complete)
        }
        let count = await provider.count
        XCTAssertEqual(count, 2, "resolve once per job, not once per app launch or stage")
        await runner.shutdown()
    }

    func testJobsStayQueuedUntilModelsAreReady() async throws {
        let readiness = ModelReadiness()
        let runner = try makeRunner(.healthyRun())
        let coordinator = try TranscriptionCoordinator(
            configuration: .init(transcriptStoreURL: root.appending(path: "store")),
            stageRunner: runner,
            canStartJob: { await readiness.ready }
        )
        let job = try await coordinator.enqueue(.init(sourceURL: try makeSource(), modelProfileID: "parakeet-v3"))
        await coordinator.runPending()
        let waiting = await coordinator.job(id: job.id)
        XCTAssertEqual(waiting?.state, .queued)
        await readiness.enable()
        await coordinator.runPending()
        let completed = await coordinator.job(id: job.id)
        XCTAssertEqual(completed?.state, .complete)
        await runner.shutdown()
    }

    private func makeRunner(_ worker: FakeTranscriptionWorker, events: EventLog? = nil) throws -> WorkerStageRunner {
        let installation = try worker.install(in: root.appending(path: "helper-\(UUID().uuidString)", directoryHint: .isDirectory))
        return WorkerStageRunner(
            configuration: .init(installation: installation, responseTimeout: .seconds(20)),
            eventHandler: events.map { log in { @Sendable event in log.record(event) } }
        )
    }

    private func makeSource() throws -> URL {
        let source = root.appending(path: "meeting \(UUID().uuidString).flac")
        try Data("audio bytes".utf8).write(to: source)
        return source
    }
}

/// Collects handoff events from the runner's callback, which fires off the
/// test's own task.
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [TranscriptionEvent] = []

    func record(_ event: TranscriptionEvent) {
        lock.lock(); defer { lock.unlock() }
        events.append(event)
    }

    func stages() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return events.map(\.stage)
    }
}

private actor InstallationRequests {
    let installation: WorkerInstallation
    var count = 0
    init(installation: WorkerInstallation) { self.installation = installation }
    func resolve() -> WorkerInstallation { count += 1; return installation }
}

private actor ModelReadiness {
    var ready = false
    func enable() { ready = true }
}
