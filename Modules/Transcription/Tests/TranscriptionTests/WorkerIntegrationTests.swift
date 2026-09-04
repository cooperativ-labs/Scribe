import Foundation
import ScribeAppCore
import XCTest
@testable import Transcription

/// Drives the real `TranscriptionWorker` binary over its real protocol.
///
/// The helper's guarded deterministic mode keeps this to seconds by skipping
/// the Core ML model work, but everything under test here is production code:
/// the argument vector, the newline framing, the stage sequence, the committed
/// checkpoint files, and what an abrupt death does to a job.
final class WorkerIntegrationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Scribe Worker Integration \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testAJobReachesCompleteThroughTheRealWorker() async throws {
        let runner = try makeStageRunner()
        let store = root.appending(path: "Meeting Transcripts", directoryHint: .isDirectory)
        let coordinator = try TranscriptionCoordinator(configuration: .init(transcriptStoreURL: store), stageRunner: runner)
        let job = try await coordinator.enqueue(.init(sourceURL: try fixtureURL(), modelProfileID: "parakeet-v3"))

        await coordinator.runPending()

        let finalJob = await coordinator.job(id: job.id)
        let completed = try XCTUnwrap(finalJob)
        XCTAssertEqual(completed.state, .complete, "the real worker must carry a queued job to complete")
        XCTAssertEqual(Set(completed.checkpoints.keys), Set(TranscriptionJobState.processingStages))
        for file in ["prepared.wav", "prepare.json", "transcript.json", "diarization.json", "embeddings.json"] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: completed.runDirectoryURL.appending(path: file).path),
                "\(file) is missing from the run directory"
            )
        }
        // The transcript checkpoint is a file reference the host can decode,
        // not data that travelled over the channel.
        let transcript = try XCTUnwrap(completed.checkpoints[.transcribing]?.artifactURL)
        XCTAssertNoThrow(try WorkerASRTranscriptCodec.decode(Data(contentsOf: transcript)))
        await runner.shutdown()
    }

    func testKillingTheRealWorkerMidStageIsAStructuredFailureWithItsEarlierCheckpointIntact() async throws {
        let runDirectory = root.appending(path: "run", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        let client = WorkerClient(configuration: .init(
            installation: try installation(),
            environment: workerEnvironment,
            responseTimeout: .seconds(60)
        ))
        try await client.handshake()
        // A delay after each stage leaves a window in which the helper is
        // genuinely mid-run when the signal arrives.
        try await client.startRun(.init(
            sourceURL: try fixtureURL(),
            runDirectoryURL: runDirectory,
            additionalOptions: ["testMode": .bool(true), "testStageDelayMilliseconds": .number(3_000)]
        ))

        var sawPrepare = false
        while !sawPrepare {
            if case let .stageResult(result) = try await client.nextRunEvent(), result.stage == "prepare" { sawPrepare = true }
        }
        let runningIdentifier = await client.processIdentifier
        let identifier = try XCTUnwrap(runningIdentifier)
        XCTAssertEqual(kill(identifier, SIGKILL), 0)

        do {
            _ = try await client.nextRunEvent()
            XCTFail("Expected a structured failure after the helper was killed")
        } catch let failure as WorkerFailure {
            XCTAssertEqual(failure.code, WorkerFailure.crashedCode)
            XCTAssertEqual(failure.completedStages, ["prepare"])
            XCTAssertTrue(failure.checkpointsPreserved)
            XCTAssertEqual(failure.diagnostic.code, "transcription.worker.worker_crashed")
        }
        // The killed stage left the earlier committed checkpoint on disk, which
        // is what makes the retry cheap.
        XCTAssertTrue(FileManager.default.fileExists(atPath: runDirectory.appending(path: "prepare.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: runDirectory.appending(path: "transcript.json").path))
        await client.shutdown()
    }

    func testARealWorkerFailureLeavesTheJobRetryableFromItsCompletedStage() async throws {
        // The helper's guarded crash hook leaves abruptly part-way through the
        // transcription stage, after the prepare checkpoint is committed.
        let runner = try makeStageRunner(additionalRunOptions: ["testMode": .bool(true), "testCrashDuringStage": .string("transcribe")])
        let store = root.appending(path: "Meeting Transcripts", directoryHint: .isDirectory)
        let coordinator = try TranscriptionCoordinator(configuration: .init(transcriptStoreURL: store), stageRunner: runner)
        let job = try await coordinator.enqueue(.init(sourceURL: try fixtureURL(), modelProfileID: "parakeet-v3"))

        await coordinator.runPending()

        let finalJob = await coordinator.job(id: job.id)
        let failed = try XCTUnwrap(finalJob)
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.failure?.code, "transcription.stage.transcribing")
        XCTAssertNotNil(failed.checkpoints[.preparing])
        XCTAssertNil(failed.checkpoints[.transcribing])

        let retry = try await coordinator.retry(jobID: job.id)
        XCTAssertEqual(Set(retry.checkpoints.keys), [.preparing])
        await runner.shutdown()
    }

    // MARK: - Helpers

    private func makeStageRunner(
        additionalRunOptions: [String: WorkerJSONValue] = ["testMode": .bool(true)]
    ) throws -> WorkerStageRunner {
        WorkerStageRunner(
            configuration: .init(
                installation: try installation(),
                environment: workerEnvironment,
                responseTimeout: .seconds(120)
            ),
            additionalRunOptions: additionalRunOptions
        )
    }

    private var workerEnvironment: [String: String] {
        ProcessInfo.processInfo.environment.merging(["SCRIBE_TRANSCRIPTION_WORKER_TEST_MODE": "1"]) { _, new in new }
    }

    private func installation() throws -> WorkerInstallation {
        let package = repositoryRoot.appending(path: "Workers/TranscriptionWorker", directoryHint: .isDirectory)
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment[WorkerLocator.executablePathEnvironmentKey] {
            candidates.append(URL(fileURLWithPath: override))
        }
        candidates += ["debug", "release"].map { package.appending(path: ".build/\($0)/\(WorkerLocator.helperName)") }
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw XCTSkip("Build the helper with `swift build --package-path Workers/TranscriptionWorker`, or set \(WorkerLocator.executablePathEnvironmentKey), for this integration test.")
        }
        return WorkerInstallation(
            executableURL: executable,
            manifestURL: package.appending(path: "model_manifest.json"),
            modelsDirectoryURL: package.appending(path: "models", directoryHint: .isDirectory)
        )
    }

    private func fixtureURL() throws -> URL {
        let fixture = repositoryRoot.appending(path: "Tests/Fixtures/Generated/microphone-16k/microphone.wav")
        guard FileManager.default.fileExists(atPath: fixture.path) else {
            throw XCTSkip("Generate the shared audio fixtures before running this integration test.")
        }
        // The coordinator snapshots its source into the transcript store, so a
        // copy here keeps each test's meeting directory its own.
        let copy = root.appending(path: "meeting \(UUID().uuidString).wav")
        try FileManager.default.copyItem(at: fixture, to: copy)
        return copy
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // TranscriptionTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Transcription
            .deletingLastPathComponent() // Modules
            .deletingLastPathComponent() // repository root
    }
}
