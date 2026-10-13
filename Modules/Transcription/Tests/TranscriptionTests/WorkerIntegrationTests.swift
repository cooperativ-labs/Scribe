import Foundation
import ScribeAppCore
import XCTest
import Vocabulary
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

    func testRealOfflineVocabularyBatchAndShortDictation() async throws {
        guard let audioPath = ProcessInfo.processInfo.environment["SCRIBE_VOCABULARY_TEST_AUDIO"],
              let dictationPath = ProcessInfo.processInfo.environment["SCRIBE_VOCABULARY_TEST_DICTATION"],
              let vocabularyPath = ProcessInfo.processInfo.environment["SCRIBE_VOCABULARY_TEST_SNAPSHOT"] else {
            throw XCTSkip("Set SCRIBE_VOCABULARY_TEST_AUDIO, SCRIBE_VOCABULARY_TEST_DICTATION and SCRIBE_VOCABULARY_TEST_SNAPSHOT for real offline vocabulary integration.")
        }
        let snapshot = try JSONDecoder().decode(VocabularySnapshot.self, from: Data(contentsOf: URL(fileURLWithPath: vocabularyPath)))
        let runner = WorkerStageRunner(configuration: .init(installation: try installation(), responseTimeout: .seconds(180)), hostStageRunner: TranscriptAssemblyStageRunner())
        let storeURL = root.appendingPathComponent("offline-vocabulary-store")
        let coordinator = try TranscriptionCoordinator(configuration: .init(transcriptStoreURL: storeURL), stageRunner: runner, vocabularySnapshot: { snapshot })
        let queued = try await coordinator.enqueue(.init(sourceURL: URL(fileURLWithPath: audioPath), modelProfileID: "parakeet-v3"))
        await coordinator.runPending()
        let job = await coordinator.job(id: queued.id)
        XCTAssertEqual(job?.state, .complete, "\(String(describing: job?.failure))")
        let run = try XCTUnwrap(TranscriptStore(storeDirectoryURL: storeURL).latestRunPerSource().first)
        let transcript = try XCTUnwrap(run.transcript)
        XCTAssertTrue(transcript.segments.map(\.text).joined(separator: " ").contains("Livmarli"))
        let raw = try WorkerASRTranscriptCodec.decode(Data(contentsOf: run.job.runDirectoryURL.appendingPathComponent("transcript.json")))
        XCTAssertTrue(raw.rawText?.contains("live marly") == true)
        XCTAssertTrue(raw.vocabularyReplacements?.contains { $0.replacement == "Livmarli" } == true)
        XCTAssertNil(raw.vocabularyWarning)

        let directory = root.appendingPathComponent("short-dictation")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audio = directory.appendingPathComponent("audio.wav")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: dictationPath), to: audio)
        try Data(contentsOf: URL(fileURLWithPath: vocabularyPath)).write(to: directory.appendingPathComponent("vocabulary.json"))
        let batch = try installation()
        let client = WorkerClient(configuration: .init(installation: WorkerInstallation(executableURL: batch.executableURL, manifestURL: batch.manifestURL, modelsDirectoryURL: batch.modelsDirectoryURL, mode: "dictation"), responseTimeout: .seconds(180)))
        try await client.handshake()
        let response = try await client.dictationCommand("dictate", payload: ["audioPath": .string(audio.path), "runDirectory": .string(directory.path), "vocabularyPath": .string("vocabulary.json")])
        XCTAssertEqual(response["status"]?.stringValue, "complete")
        XCTAssertTrue(response["text"]?.stringValue?.contains("Livmarli") == true, "\(response)")
        XCTAssertNil(response["vocabularyWarning"])
        XCTAssertEqual(response["vocabularyRevision"]?.stringValue, snapshot.revision)
        let empty = VocabularySnapshot(revision: nil, terms: [])
        try JSONEncoder().encode(empty).write(to: directory.appendingPathComponent("vocabulary.json"), options: .atomic)
        let emptyResponse = try await client.dictationCommand("dictate", payload: ["audioPath": .string(audio.path), "runDirectory": .string(directory.path), "vocabularyPath": .string("vocabulary.json")])
        XCTAssertEqual(emptyResponse["text"]?.stringValue, emptyResponse["rawText"]?.stringValue)
        XCTAssertNil(emptyResponse["vocabularyWarning"])
        let unrelated = VocabularySnapshot(revision: "nonhit-v1", terms: [VocabularyTerm(text: "Broomhilda")])
        try JSONEncoder().encode(unrelated).write(to: directory.appendingPathComponent("vocabulary.json"), options: .atomic)
        let nonhit = try await client.dictationCommand("dictate", payload: ["audioPath": .string(audio.path), "runDirectory": .string(directory.path), "vocabularyPath": .string("vocabulary.json")])
        XCTAssertEqual(nonhit["text"]?.stringValue, nonhit["rawText"]?.stringValue)
        XCTAssertNil(nonhit["vocabularyWarning"])
        await client.shutdown()

        let baseOnly = root.appendingPathComponent("base-models-only")
        try FileManager.default.createDirectory(at: baseOnly, withIntermediateDirectories: true)
        for name in ["parakeet-tdt-0.6b-v3-coreml", "speaker-diarization-coreml"] {
            try FileManager.default.createSymbolicLink(at: baseOnly.appendingPathComponent(name), withDestinationURL: try XCTUnwrap(batch.modelsDirectoryURL).appendingPathComponent(name))
        }
        try JSONEncoder().encode(snapshot).write(to: directory.appendingPathComponent("vocabulary.json"), options: .atomic)
        let missingClient = WorkerClient(configuration: .init(installation: WorkerInstallation(executableURL: batch.executableURL, manifestURL: batch.manifestURL, modelsDirectoryURL: baseOnly, mode: "dictation"), responseTimeout: .seconds(180)))
        try await missingClient.handshake()
        let missing = try await missingClient.dictationCommand("dictate", payload: ["audioPath": .string(audio.path), "runDirectory": .string(directory.path), "vocabularyPath": .string("vocabulary.json")])
        XCTAssertEqual(missing["status"]?.stringValue, "complete")
        XCTAssertEqual(missing["text"]?.stringValue, missing["rawText"]?.stringValue)
        XCTAssertEqual(missing["vocabularyWarning"]?.stringValue, "vocabulary_assets_unavailable")
        await missingClient.shutdown()
    }

    func testLongVocabularyEvidenceUsesSourceRelativeCanonicalWords() throws {
        guard let path = ProcessInfo.processInfo.environment["SCRIBE_VOCABULARY_TEST_LONG_TRANSCRIPT"] else {
            throw XCTSkip("Set SCRIBE_VOCABULARY_TEST_LONG_TRANSCRIPT to a real long-recording worker artifact.")
        }
        let transcript = try WorkerASRTranscriptCodec.decode(Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertTrue(transcript.usedChunkedProcessing)
        XCTAssertGreaterThanOrEqual(transcript.sourceDurationSeconds, 3600)
        let result = try TokenTimingReconciler().reconcile(.init(workerTranscript: transcript, timeMapping: .init(sourceSampleRate: 16_000), sourceDurationMs: Int(transcript.sourceDurationSeconds * 1_000)))
        let words = result.words.map { ReconciledWordsRecord.Word(id: $0.id, text: $0.text, startMs: $0.startMs, endMs: $0.endMs, enclosingStartMs: $0.enclosingStartMs, enclosingEndMs: $0.enclosingEndMs) }
        let replacements = try XCTUnwrap(transcript.vocabularyReplacements)
        XCTAssertGreaterThan(replacements.count, 100)
        XCTAssertTrue(replacements.contains { $0.startSeconds > 3600 })
        let corrected = VocabularyWordReplacer.apply(replacements, to: words)
        XCTAssertEqual(corrected.filter { $0.text.contains("Livmarli") }.count, replacements.filter { $0.replacement == "Livmarli" }.count)
        XCTAssertTrue(corrected.contains { $0.text.contains("Livmarli") && ($0.startMs ?? 0) > 3_600_000 })
        XCTAssertTrue(corrected.allSatisfy { ($0.endMs ?? 0) <= 7_200_000 })
        XCTAssertNil(transcript.vocabularyWarning)
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
