@preconcurrency import AVFoundation
import CryptoKit
import Foundation

/// Runs one transcription request as independently committed checkpoints.
///
/// The worker deliberately writes a checkpoint only after a stage has returned
/// successfully.  This makes a process termination during a later stage safe:
/// the host can use every earlier result without having to distinguish a
/// partially-written JSON file from a valid one.
public struct WorkerJobRunner: Sendable {
    public struct Configuration: Sendable {
        public let manifestURL: URL
        public let modelsDirectory: URL

        public init(manifestURL: URL, modelsDirectory: URL) {
            self.manifestURL = manifestURL
            self.modelsDirectory = modelsDirectory
        }
    }

    public enum Error: Swift.Error, LocalizedError, Sendable {
        case missingValue(String)
        case invalidPath(String)
        case invalidSpeakerCount
        case unsafeTestMode

        public var errorDescription: String? {
            switch self {
            case let .missingValue(name): "Missing required job value \(name)."
            case let .invalidPath(message): message
            case .invalidSpeakerCount: "Speaker count must be a positive integer; choose either exact or maximum."
            case .unsafeTestMode: "The deterministic test pipeline is disabled outside the worker test environment."
            }
        }
    }

    public typealias Emitter = @Sendable (WorkerEnvelope) -> Void
    public typealias CancellationCheck = @Sendable () -> Bool

    public let configuration: Configuration

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Emits progress and stage-result envelopes as each durable checkpoint is
    /// committed. The final envelope is either `complete` or a structured
    /// error; no transcript-sized value is returned over stdout.
    public func run(
        requestID: String,
        payload: [String: JSONValue],
        isCancelled: @escaping CancellationCheck,
        emit: @escaping Emitter
    ) async {
        do {
            let job = try Job(payload: payload)
            let manifest = try ModelManifest.loadValidated(
                from: configuration.manifestURL,
                modelsDirectory: configuration.modelsDirectory
            )

            try FileManager.default.createDirectory(at: job.runDirectory, withIntermediateDirectories: true)
            let prepare = try await runPrepare(job: job, requestID: requestID, isCancelled: isCancelled, emit: emit)
            try stopIfCancelled(afterStage: "prepare", isCancelled: isCancelled)

            let transcript = try await runTranscription(job: job, prepared: prepare, manifest: manifest, requestID: requestID, isCancelled: isCancelled, emit: emit)
            _ = transcript // Its durable checkpoint is the handoff to later host stages.
            try stopIfCancelled(afterStage: "transcribe", isCancelled: isCancelled)

            let diarization = try await runDiarization(job: job, prepared: prepare, manifest: manifest, requestID: requestID, isCancelled: isCancelled, emit: emit)
            try stopIfCancelled(afterStage: "diarize", isCancelled: isCancelled)

            try await runEmbedding(job: job, diarization: diarization, requestID: requestID, isCancelled: isCancelled, emit: emit)
            try stopIfCancelled(afterStage: "embed", isCancelled: isCancelled)
            emit(stageResult(requestID: requestID, stage: "complete", status: "complete"))
        } catch let cancellation as Cancellation {
            emit(WorkerProtocol.error(requestID: requestID, code: "cancelled", message: cancellation.localizedDescription, details: .object([
                "stage": .string(cancellation.afterStage),
                "checkpointsPreserved": .bool(true),
            ])))
        } catch let setup as ModelSetupError {
            emit(WorkerProtocol.error(requestID: requestID, code: "model_setup_incomplete", message: setup.localizedDescription))
        } catch {
            emit(WorkerProtocol.error(requestID: requestID, code: "job_failed", message: error.localizedDescription))
        }
    }

    private func runPrepare(job: Job, requestID: String, isCancelled: @escaping CancellationCheck, emit: @escaping Emitter) async throws -> PreparedStage {
        emit(progress(requestID: requestID, stage: "prepare", state: "started"))
        let preparedURL = job.runDirectory.appending(path: "prepared.wav")
        let sourceDuration = try PreparedAudio.prepare(source: job.sourceURL, destination: preparedURL)
        let result = PreparedStage(preparedAudioPath: preparedURL.path, sourceDurationSeconds: sourceDuration, sampleRate: 16_000, channels: 1)
        try commit(result, to: job.runDirectory.appending(path: "prepare.json"))
        emit(stageResult(requestID: requestID, stage: "prepare", resultURL: job.runDirectory.appending(path: "prepare.json")))
        try await testPauseIfNeeded(job)
        try testCrashIfNeeded(job, during: "prepare")
        return result
    }

    private func runTranscription(job: Job, prepared: PreparedStage, manifest: ModelManifest, requestID: String, isCancelled: @escaping CancellationCheck, emit: @escaping Emitter) async throws -> ParakeetAdapter.Transcript {
        emit(progress(requestID: requestID, stage: "transcribe", state: "started"))
        try testCrashIfNeeded(job, during: "transcribe")
        let result: ParakeetAdapter.Transcript
        if job.testMode {
            result = ParakeetAdapter.Transcript(text: "fixture transcript", tokens: [], sourceDurationSeconds: prepared.sourceDurationSeconds, processingTimeSeconds: 0, usedChunkedProcessing: false, timestampUnit: "seconds")
        } else {
            // The adapter's manager and Core ML models are scoped to this call.
            // Returning only its value releases the ASR model set before VBx loads.
            result = try await ParakeetAdapter(manifest: manifest, modelsDirectory: configuration.modelsDirectory).transcribe(fileURL: URL(fileURLWithPath: prepared.preparedAudioPath))
        }
        let resultURL = job.runDirectory.appending(path: "transcript.json")
        try commit(result, to: resultURL)
        emit(stageResult(requestID: requestID, stage: "transcribe", resultURL: resultURL))
        try await testPauseIfNeeded(job)
        return result
    }

    private func runDiarization(job: Job, prepared: PreparedStage, manifest: ModelManifest, requestID: String, isCancelled: @escaping CancellationCheck, emit: @escaping Emitter) async throws -> OfflineDiarizationAdapter.Result {
        emit(progress(requestID: requestID, stage: "diarize", state: "started"))
        try testCrashIfNeeded(job, during: "diarize")
        let result: OfflineDiarizationAdapter.Result
        if job.testMode {
            result = OfflineDiarizationAdapter.Result(
                intervals: [],
                embeddings: [.init(speakerID: "speaker_1", vector: [1, 0], modelID: "test", modelRevision: "test", preprocessingVersion: "test", normalizationVersion: "l2-unit-v1")],
                sourceDurationSeconds: prepared.sourceDurationSeconds,
                usedDiskBackedAudio: false,
                timings: nil,
                engine: .init(runtime: "test", runtimeRevision: "test", modelRevision: "test"),
                configuration: .init(
                    knownSpeakerCount: job.knownSpeakerCount,
                    maximumSpeakerCount: job.maximumSpeakerCount,
                    minimumGapDurationSeconds: 0.1,
                    minimumSegmentDurationSeconds: 0,
                    clusteringThreshold: 0.6,
                    embeddingExcludeOverlap: true,
                    minimumEmbeddingDurationSeconds: 1,
                    segmentationStepRatio: 0.2,
                    preserveOverlappingIntervals: true,
                    constrainedAssignment: true,
                    warmStartFa: 0.07,
                    warmStartFb: 0.8,
                    maximumVBxIterations: 20
                ),
                clusteringDiagnostics: .init(
                    heuristicVersion: "dominant-occupancy-v1",
                    embeddingCount: 0,
                    intervalCount: 0,
                    overlapIntervalCount: 0,
                    occupancies: [],
                    dominantEmbeddingFraction: nil,
                    dominantIntervalFraction: nil,
                    separationAppearsCollapsed: false
                )
            )
        } else {
            result = try await OfflineDiarizationAdapter(
                manifest: manifest,
                modelsDirectory: configuration.modelsDirectory,
                configuration: .init(knownSpeakerCount: job.knownSpeakerCount, maximumSpeakerCount: job.maximumSpeakerCount)
            ).diarize(fileURL: URL(fileURLWithPath: prepared.preparedAudioPath))
        }
        let checkpoint = DiarizationStage(
            intervals: result.intervals,
            sourceDurationSeconds: result.sourceDurationSeconds,
            usedDiskBackedAudio: result.usedDiskBackedAudio,
            timings: result.timings,
            engine: result.engine,
            configuration: result.configuration,
            clusteringDiagnostics: result.clusteringDiagnostics
        )
        let resultURL = job.runDirectory.appending(path: "diarization.json")
        try commit(checkpoint, to: resultURL)
        emit(stageResult(requestID: requestID, stage: "diarize", resultURL: resultURL))
        try await testPauseIfNeeded(job)
        return result
    }

    private func runEmbedding(job: Job, diarization: OfflineDiarizationAdapter.Result, requestID: String, isCancelled: @escaping CancellationCheck, emit: @escaping Emitter) async throws {
        emit(progress(requestID: requestID, stage: "embed", state: "started"))
        try testCrashIfNeeded(job, during: "embed")
        let resultURL = job.runDirectory.appending(path: "embeddings.json")
        try commit(diarization.embeddings, to: resultURL)
        emit(stageResult(requestID: requestID, stage: "embed", resultURL: resultURL))
        try await testPauseIfNeeded(job)
    }

    private func stopIfCancelled(afterStage: String, isCancelled: CancellationCheck) throws {
        guard !isCancelled() else { throw Cancellation(afterStage: afterStage) }
    }

    private func progress(requestID: String, stage: String, state: String) -> WorkerEnvelope {
        WorkerEnvelope(kind: .progress, requestID: requestID, payload: .object(["stage": .string(stage), "state": .string(state)]))
    }

    private func stageResult(requestID: String, stage: String, status: String = "complete", resultURL: URL? = nil) -> WorkerEnvelope {
        var payload: [String: JSONValue] = ["stage": .string(stage), "status": .string(status)]
        if let resultURL {
            payload["resultPath"] = .string(resultURL.lastPathComponent)
            payload["sha256"] = .string(sha256(of: resultURL))
        }
        return WorkerEnvelope(kind: .stageResult, requestID: requestID, payload: .object(payload))
    }

    private func commit<T: Encodable>(_ value: T, to destination: URL) throws {
        let data = try JSONEncoder.workerCheckpoint.encode(value)
        try AtomicFilePublisher.write(data, to: destination)
    }

    private func sha256(of url: URL) -> String {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return "unavailable" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func testPauseIfNeeded(_ job: Job) async throws {
        guard job.testStageDelayMilliseconds > 0 else { return }
        try await Task.sleep(for: .milliseconds(job.testStageDelayMilliseconds))
    }

    private func testCrashIfNeeded(_ job: Job, during stage: String) throws {
        guard job.testCrashDuringStage == stage else { return }
        // This hook is admitted only when the caller explicitly enables the
        // test environment. It gives the integration test a real abrupt exit.
        Foundation.exit(97)
    }
}

private struct Job {
    let sourceURL: URL
    let runDirectory: URL
    let knownSpeakerCount: Int?
    let maximumSpeakerCount: Int?
    let testMode: Bool
    let testStageDelayMilliseconds: Int
    let testCrashDuringStage: String?

    init(payload: [String: JSONValue]) throws {
        guard let sourcePath = payload["sourcePath"]?.stringValue else { throw WorkerJobRunner.Error.missingValue("sourcePath") }
        guard let runPath = payload["runDirectory"]?.stringValue else { throw WorkerJobRunner.Error.missingValue("runDirectory") }
        guard sourcePath.hasPrefix("/"), runPath.hasPrefix("/") else { throw WorkerJobRunner.Error.invalidPath("sourcePath and runDirectory must be absolute local paths.") }
        sourceURL = URL(fileURLWithPath: sourcePath)
        runDirectory = URL(fileURLWithPath: runPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { throw WorkerJobRunner.Error.invalidPath("Input audio does not exist at \(sourceURL.path).") }
        func count(_ key: String) throws -> Int? {
            guard let raw = payload[key] else { return nil }
            guard let value = raw.numberValue, value.isFinite, value > 0,
                  value < Double(Int.max), value.rounded() == value else { throw WorkerJobRunner.Error.invalidSpeakerCount }
            return Int(value)
        }
        knownSpeakerCount = try count("knownSpeakerCount")
        maximumSpeakerCount = try count("maximumSpeakerCount")
        guard knownSpeakerCount == nil || maximumSpeakerCount == nil else { throw WorkerJobRunner.Error.invalidSpeakerCount }
        testMode = payload["testMode"]?.boolValue == true
        testStageDelayMilliseconds = Int(payload["testStageDelayMilliseconds"]?.numberValue ?? 0)
        testCrashDuringStage = payload["testCrashDuringStage"]?.stringValue
        if testMode || testCrashDuringStage != nil {
            guard ProcessInfo.processInfo.environment["SCRIBE_TRANSCRIPTION_WORKER_TEST_MODE"] == "1" else { throw WorkerJobRunner.Error.unsafeTestMode }
        }
    }
}

private struct PreparedStage: Codable {
    let preparedAudioPath: String
    let sourceDurationSeconds: TimeInterval
    let sampleRate: Int
    let channels: Int
}

private struct DiarizationStage: Codable {
    let intervals: [OfflineDiarizationAdapter.SpeakerInterval]
    let sourceDurationSeconds: TimeInterval
    let usedDiskBackedAudio: Bool
    let timings: OfflineDiarizationAdapter.Timings?
    let engine: OfflineDiarizationAdapter.Engine
    let configuration: OfflineDiarizationAdapter.AppliedConfiguration
    let clusteringDiagnostics: OfflineDiarizationAdapter.ClusteringDiagnostics
}

private struct Cancellation: LocalizedError {
    let afterStage: String
    var errorDescription: String? { "The request was cancelled at a stage boundary; completed stage outputs remain in the run directory." }
}

private enum PreparedAudio {
    static func prepare(source: URL, destination: URL) throws -> TimeInterval {
        let sourceFile = try AVAudioFile(forReading: source)
        let sourceFormat = sourceFile.processingFormat
        let duration = Double(sourceFile.length) / sourceFormat.sampleRate
        if abs(sourceFormat.sampleRate - 16_000) < 0.001, sourceFormat.channelCount == 1 {
            try replaceWithCopy(source: source, destination: destination)
            return duration
        }
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw WorkerJobRunner.Error.invalidPath("Could not create a 16 kHz mono audio conversion path.")
        }
        let temporary = destination.deletingLastPathComponent().appending(path: ".prepared-\(UUID().uuidString).wav")
        let output = try AVAudioFile(forWriting: temporary, settings: targetFormat.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        while sourceFile.framePosition < sourceFile.length {
            guard let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 4_096) else { break }
            try sourceFile.read(into: input)
            guard input.frameLength > 0 else { break }
            let capacity = AVAudioFrameCount((Double(input.frameLength) * targetFormat.sampleRate / sourceFormat.sampleRate).rounded(.up)) + 32
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { break }
            var supplied = false
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
                if supplied { inputStatus.pointee = .noDataNow; return nil }
                supplied = true
                inputStatus.pointee = .haveData
                return input
            }
            guard status != .error else { throw conversionError ?? WorkerJobRunner.Error.invalidPath("Audio conversion failed.") }
            if converted.frameLength > 0 { try output.write(from: converted) }
        }
        try AtomicFilePublisher.publish(temporary, to: destination)
        return duration
    }

    private static func replaceWithCopy(source: URL, destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appending(path: ".prepared-\(UUID().uuidString).wav")
        try FileManager.default.copyItem(at: source, to: temporary)
        try AtomicFilePublisher.publish(temporary, to: destination)
    }
}

private extension JSONEncoder {
    static let workerCheckpoint: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}
