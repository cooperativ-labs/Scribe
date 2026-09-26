@testable import ScribeInference
import Foundation
import FluidAudio
import Testing
@testable import TranscriptionWorkerSupport

@Test("protocol envelopes round-trip with the pinned version")
func envelopeRoundTrip() throws {
    let expected = WorkerEnvelope(kind: .request, requestID: "request-1", payload: .object([
        "operation": .string("handshake"),
    ]))
    let decoded = try WorkerProtocol.decode(WorkerProtocol.encode(expected))
    #expect(decoded == expected)
}

@Test("protocol rejects records larger than the bounded control plane")
func oversizedRecordIsRejected() {
    let oversized = Data(repeating: 0x20, count: WorkerProtocol.maximumMessageBytes + 1)
    #expect(throws: WorkerProtocolError.self) {
        try WorkerProtocol.decode(oversized)
    }
}

@Test("production manifest disables telemetry and runtime downloads")
func manifestIsOfflineOnlyAndReportsMissingAssets() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let manifest = try ModelManifest.load(from: packageRoot.appending(path: "model_manifest.json"))
    #expect(manifest.telemetry.enabled == false)
    #expect(manifest.telemetry.runtimeDownloadsAllowed == false)
    #expect(manifest.totalDeclaredOnDiskBytes == 505044116)
    #expect(manifest.assets.count >= 10)
    let report = manifest.validate(modelsDirectory: packageRoot.appending(path: "models-not-installed"))
    #expect(report.isValid == false)
    #expect(report.failures.contains { $0.reason == "missing" })
}

@Test("Parakeet timing adapter preserves seconds and token punctuation")
func parakeetTimingContract() throws {
    let manifest = try ModelManifest.load(from: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "model_manifest.json"))
    let adapter = ParakeetAdapter(
        manifest: manifest,
        modelsDirectory: URL(fileURLWithPath: "/models-not-needed-for-this-test")
    )
    let result = ASRResult(
        text: "Hello, world!",
        confidence: 0.9,
        duration: 2.0,
        processingTime: 0.1,
        tokenTimings: [
            TokenTiming(token: "Hello", tokenId: 1, startTime: 0.08, endTime: 0.40, confidence: 0.9),
            TokenTiming(token: ",", tokenId: 2, startTime: 0.40, endTime: 0.48, confidence: 0.8),
            TokenTiming(token: "world", tokenId: 3, startTime: 0.56, endTime: 0.88, confidence: 0.9),
            TokenTiming(token: "!", tokenId: 4, startTime: 0.88, endTime: 0.96, confidence: 0.8),
        ]
    )

    let transcript = try adapter.makeTranscript(result, sourceDuration: 2.0)
    #expect(transcript.timestampUnit == "seconds")
    #expect(transcript.tokens.map(\.text) == ["Hello", ",", "world", "!"])
    #expect(transcript.tokens.map(\.startSeconds) == [0.08, 0.40, 0.56, 0.88])
    // Ends are the decoder's own durations and are passed through untouched.
    #expect(transcript.tokens.map(\.endSeconds) == [0.40, 0.48, 0.88, 0.96])
}

@Test("Parakeet timing adapter clamps a duration that overruns the recording but rejects an out-of-range start")
func parakeetTailDurationContract() throws {
    let manifest = try ModelManifest.load(from: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "model_manifest.json"))
    let adapter = ParakeetAdapter(
        manifest: manifest,
        modelsDirectory: URL(fileURLWithPath: "/models-not-needed-for-this-test")
    )

    // Since FluidAudio 0.12.5 a token end is `start + duration`, so the last
    // token of a recording can round past the prepared audio. That is a tail to
    // clamp, not a reason to fail an otherwise complete transcript.
    let overrunning = ASRResult(
        text: "Bye",
        confidence: 0.9,
        duration: 2.0,
        processingTime: 0.1,
        tokenTimings: [TokenTiming(token: "Bye", tokenId: 1, startTime: 1.84, endTime: 2.24, confidence: 0.9)]
    )
    let transcript = try adapter.makeTranscript(overrunning, sourceDuration: 2.0)
    #expect(transcript.tokens.map(\.startSeconds) == [1.84])
    #expect(transcript.tokens.map(\.endSeconds) == [2.0])

    // A start beyond the recording is still the signature of a chunk-rebasing
    // bug and must not be quietly absorbed.
    let misplaced = ASRResult(
        text: "Bye",
        confidence: 0.9,
        duration: 2.0,
        processingTime: 0.1,
        tokenTimings: [TokenTiming(token: "Bye", tokenId: 1, startTime: 2.4, endTime: 2.8, confidence: 0.9)]
    )
    #expect(throws: ParakeetAdapter.Error.invalidTokenTiming(index: 0)) {
        try adapter.makeTranscript(misplaced, sourceDuration: 2.0)
    }
}

@Test("offline diarization preserves overlap, first-appearance labels, and compatible vectors")
func offlineDiarizationContract() throws {
    let manifest = try ModelManifest.load(from: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "model_manifest.json"))
    let adapter = OfflineDiarizationAdapter(
        manifest: manifest,
        modelsDirectory: URL(fileURLWithPath: "/models-not-needed-for-this-test")
    )
    let raw = DiarizationResult(
        segments: [
            TimedSpeakerSegment(speakerId: "S9", embedding: [3, 4], startTimeSeconds: 2, endTimeSeconds: 4, qualityScore: 0.8),
            TimedSpeakerSegment(speakerId: "S2", embedding: [1, 0], startTimeSeconds: 1, endTimeSeconds: 3, qualityScore: 0.9),
            TimedSpeakerSegment(speakerId: "S9", embedding: [3, 4], startTimeSeconds: 5, endTimeSeconds: 6, qualityScore: 0.7),
        ],
        speakerDatabase: ["S9": [3, 4], "S2": [1, 0]]
    )

    let result = try adapter.makeResult(raw, sourceDuration: 6)
    #expect(result.usedDiskBackedAudio)
    #expect(result.intervals.map(\.speakerID) == ["speaker_1", "speaker_2", "speaker_2"])
    #expect(result.intervals.map(\.overlapsAnotherSpeaker) == [true, true, false])
    #expect(result.embeddings.map(\.speakerID) == ["speaker_1", "speaker_2"])
    #expect(result.embeddings.allSatisfy { abs($0.vector.reduce(0) { $1 * $1 + $0 }.squareRoot() - 1) < 0.0001 })
    #expect(result.embeddings.allSatisfy { $0.modelID == "wespeaker-embedding-coreml" })
    #expect(result.embeddings.allSatisfy { $0.preprocessingVersion == "fluidaudio-offline-fbank-16khz-mono-v0.15.6" })
    #expect(result.engine.runtime == "FluidAudio 0.17.4")
    #expect(result.configuration.clusteringThreshold == 0.6)
    #expect(result.clusteringDiagnostics.separationAppearsCollapsed == false)
}

@Test("offline diarization records occupancy and flags collapse without changing assignments")
func offlineDiarizationCollapseDiagnostics() throws {
    let manifest = try ModelManifest.load(from: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "model_manifest.json"))
    let adapter = OfflineDiarizationAdapter(
        manifest: manifest,
        modelsDirectory: URL(fileURLWithPath: "/models-not-needed-for-this-test")
    )
    let dominantChunks = (0..<96).map {
        ChunkEmbedding(speakerId: "S1", chunkIndex: $0, speakerIndex: 0, startTimeSeconds: Double($0), endTimeSeconds: Double($0 + 1), embedding256: [1, 0])
    }
    let minorChunks = (96..<100).map {
        ChunkEmbedding(speakerId: "S2", chunkIndex: $0, speakerIndex: 0, startTimeSeconds: Double($0), endTimeSeconds: Double($0 + 1), embedding256: [0, 1])
    }
    let raw = DiarizationResult(
        segments: [
            TimedSpeakerSegment(speakerId: "S1", embedding: [1, 0], startTimeSeconds: 0, endTimeSeconds: 99, qualityScore: 0.9),
            TimedSpeakerSegment(speakerId: "S2", embedding: [0, 1], startTimeSeconds: 99, endTimeSeconds: 100, qualityScore: 0.9),
        ],
        speakerDatabase: ["S1": [1, 0], "S2": [0, 1]],
        chunkEmbeddings: dominantChunks + minorChunks
    )

    let result = try adapter.makeResult(raw, sourceDuration: 100)
    #expect(result.intervals.map(\.speakerID) == ["speaker_1", "speaker_2"])
    #expect(result.clusteringDiagnostics.embeddingCount == 100)
    #expect(result.clusteringDiagnostics.occupancies.map(\.embeddingCount) == [96, 4])
    #expect(result.clusteringDiagnostics.dominantEmbeddingFraction == 0.96)
    #expect(result.clusteringDiagnostics.dominantIntervalFraction == 0.99)
    #expect(result.clusteringDiagnostics.separationAppearsCollapsed)
}

@Test("worker binary streams each sequential stage to the host run directory")
func workerBinarySequentialIntegration() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let fixture = packageRoot.deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Tests/Fixtures/Generated/microphone-16k/microphone.wav")
    let runDirectory = FileManager.default.temporaryDirectory.appending(path: "transcription-worker-sequential-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: runDirectory) }

    let process = Process()
    process.executableURL = packageRoot.appending(path: ".build/debug/TranscriptionWorker")
    process.currentDirectoryURL = packageRoot
    process.environment = ProcessInfo.processInfo.environment.merging(["SCRIBE_TRANSCRIPTION_WORKER_TEST_MODE": "1"]) { _, new in new }
    let input = Pipe(), output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    try process.run()
    let request = """
    {"version":1,"kind":"request","requestID":"sequential-run","payload":{"operation":"run","sourcePath":"\(fixture.path)","runDirectory":"\(runDirectory.path)","testMode":true}}
    """
    input.fileHandleForWriting.write(Data("\(request)\n".utf8))
    input.fileHandleForWriting.closeFile()
    process.waitUntilExit()
    let messages = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

    #expect(process.terminationStatus == 0)
    for file in ["prepared.wav", "prepare.json", "transcript.json", "diarization.json", "embeddings.json"] {
        #expect(FileManager.default.fileExists(atPath: runDirectory.appending(path: file).path))
    }
    #expect(messages.contains("\"stage\":\"complete\""))
}

@Test("worker binary checkpoints a cancelled request and preserves prior output offline")
func workerBinaryCancellationIntegration() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let fixture = packageRoot.deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Tests/Fixtures/Generated/microphone-16k/microphone.wav")
    let runDirectory = FileManager.default.temporaryDirectory.appending(path: "transcription-worker-integration-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: runDirectory) }

    let process = Process()
    process.executableURL = packageRoot.appending(path: ".build/debug/TranscriptionWorker")
    process.currentDirectoryURL = packageRoot
    process.environment = ProcessInfo.processInfo.environment.merging(["SCRIBE_TRANSCRIPTION_WORKER_TEST_MODE": "1"]) { _, new in new }
    let input = Pipe(), output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    try process.run()

    let outputCollector = OutputCollector()
    let prepareStarted = DispatchSemaphore(value: 0)
    output.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        guard !data.isEmpty else { return }
        let messages = outputCollector.appendAndRead(data)
        if messages.contains("\"stage\":\"prepare\",\"state\":\"started\"") { prepareStarted.signal() }
    }

    let request = """
    {"version":1,"kind":"request","requestID":"cancelled-run","payload":{"operation":"run","sourcePath":"\(fixture.path)","runDirectory":"\(runDirectory.path)","testMode":true,"testStageDelayMilliseconds":500}}
    """
    input.fileHandleForWriting.write(Data("\(request)\n".utf8))
    #expect(prepareStarted.wait(timeout: .now() + 5) == .success)
    // The test-only pause after prepare makes this a cancellation at the next
    // stage boundary rather than a pre-start cancellation.
    Thread.sleep(forTimeInterval: 0.1)
    input.fileHandleForWriting.write(Data("{\"version\":1,\"kind\":\"cancel\",\"requestID\":\"cancelled-run\",\"payload\":{}}\n".utf8))
    input.fileHandleForWriting.closeFile()
    process.waitUntilExit()
    output.fileHandleForReading.readabilityHandler = nil
    let messages = outputCollector.read()

    #expect(process.terminationStatus == 0)
    #expect(FileManager.default.fileExists(atPath: runDirectory.appending(path: "prepared.wav").path))
    #expect(FileManager.default.fileExists(atPath: runDirectory.appending(path: "prepare.json").path))
    #expect(!FileManager.default.fileExists(atPath: runDirectory.appending(path: "transcript.json").path))
    #expect(messages.contains("\"code\":\"cancelled\""))
}

@Test("worker binary crash leaves the preceding checkpoint intact")
func workerBinaryCrashRecoveryIntegration() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let fixture = packageRoot.deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Tests/Fixtures/Generated/microphone-16k/microphone.wav")
    let runDirectory = FileManager.default.temporaryDirectory.appending(path: "transcription-worker-crash-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: runDirectory) }

    let process = Process()
    process.executableURL = packageRoot.appending(path: ".build/debug/TranscriptionWorker")
    process.currentDirectoryURL = packageRoot
    process.environment = ProcessInfo.processInfo.environment.merging(["SCRIBE_TRANSCRIPTION_WORKER_TEST_MODE": "1"]) { _, new in new }
    let input = Pipe()
    process.standardInput = input
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let request = """
    {"version":1,"kind":"request","requestID":"crash-run","payload":{"operation":"run","sourcePath":"\(fixture.path)","runDirectory":"\(runDirectory.path)","testMode":true,"testCrashDuringStage":"transcribe"}}
    """
    input.fileHandleForWriting.write(Data("\(request)\n".utf8))
    input.fileHandleForWriting.closeFile()
    process.waitUntilExit()

    #expect(process.terminationStatus == 97)
    #expect(FileManager.default.fileExists(atPath: runDirectory.appending(path: "prepared.wav").path))
    #expect(FileManager.default.fileExists(atPath: runDirectory.appending(path: "prepare.json").path))
    #expect(!FileManager.default.fileExists(atPath: runDirectory.appending(path: "transcript.json").path))
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func appendAndRead(_ extra: Data) -> String {
        lock.lock(); defer { lock.unlock() }
        data.append(extra)
        return String(decoding: data, as: UTF8.self)
    }

    func read() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

@Test("offline diarization applies post-processing controls and a ceiling without forcing an exact count")
func offlineDiarizationConfigurationControls() throws {
    let manifest = try ModelManifest.load(from: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "model_manifest.json"))
    func adapter(_ configuration: OfflineDiarizationAdapter.Configuration) -> OfflineDiarizationAdapter {
        .init(manifest: manifest, modelsDirectory: URL(fileURLWithPath: "/unused"), configuration: configuration)
    }
    let config = try adapter(.init(maximumSpeakerCount: 4, minimumGapDurationSeconds: 0.5,
                                   minimumSegmentDurationSeconds: 1.2)).makeDiarizerConfiguration()
    #expect(config.clustering.maxSpeakers == 4)
    #expect(config.clustering.numSpeakers == nil)
    #expect(config.clustering.threshold == 0.6)
    #expect(config.postProcessing.minGapDurationSeconds == 0.5)
    #expect(config.segmentation.minDurationOn == 1.2)
    #expect(!config.postProcessing.exclusiveSegments)
    for invalid in [
        OfflineDiarizationAdapter.Configuration(maximumSpeakerCount: 0),
        .init(knownSpeakerCount: 2, maximumSpeakerCount: 4),
        .init(minimumGapDurationSeconds: -.infinity),
        .init(minimumSegmentDurationSeconds: -1),
    ] {
        #expect(throws: OfflineDiarizationAdapter.Error.self) { try adapter(invalid).makeDiarizerConfiguration() }
    }
}
