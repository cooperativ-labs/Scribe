import ScribeInference
@preconcurrency import AVFoundation
@preconcurrency import CoreML
import FluidAudio
import Foundation
import os

/// A single ASR manager is retained for the lifetime of the dictation worker,
/// and so is the optional vocabulary booster once a snapshot needs it.
/// Batch jobs use their original per-job worker and never enter this actor.
///
/// Logs carry stage names, readiness and timings only: never transcript text
/// or vocabulary contents.
public actor WorkerDictationSession {
    static let logger = Logger(subsystem: "com.scribe.TranscriptionWorker", category: "Dictation")
    private let configuration: WorkerJobRunner.Configuration
    private var models: AsrModels?
    private var manager: AsrManager?
    private var vad: VadManager?
    let booster = VocabularyBooster()

    public init(configuration: WorkerJobRunner.Configuration) {
        self.configuration = configuration
    }

    public func handle(operation: String, requestID: String, payload: [String: JSONValue], emit: (WorkerEnvelope) -> Void) async {
        do {
            let result: [String: JSONValue]
            switch operation {
            case "warm": result = try await warm(payload)
            case "dictate": result = try await dictate(payload)
            case "unload":
                let boosterWasResident = await booster.isResident
                models = nil
                manager = nil
                vad = nil
                await booster.release()
                Self.logger.notice("Dictation models released on unload request (vocabulary booster resident: \(boosterWasResident, privacy: .public))")
                result = ["stage": .string("unload"), "status": .string("ready")]
            default: throw DictationError.invalidRequest("Unsupported operation \(operation).")
            }
            emit(WorkerEnvelope(version: 2, kind: .stageResult, requestID: requestID, payload: .object(result)))
        } catch {
            emit(WorkerProtocol.error(requestID: requestID, code: "dictation_failed", message: error.localizedDescription, version: 2))
        }
    }

    /// Prepares speech recognition and, when the payload carries a snapshot with
    /// a usable term, the vocabulary booster including one representative CTC
    /// prediction. Missing or corrupt optional assets never fail the warm.
    private func warm(_ payload: [String: JSONValue]) async throws -> [String: JSONValue] {
        let started = ContinuousClock.now
        let speech = try await warmSpeech()
        var result: [String: JSONValue] = ["stage": .string("warm"), "status": .string("ready"), "speech": .string(speech)]
        if let value = payload["vocabulary"] {
            let snapshot = try JSONDecoder().decode(WorkerVocabularySnapshot.self, from: JSONEncoder().encode(value))
            let report = await booster.warm(snapshot: snapshot, manifestURL: configuration.manifestURL,
                                            modelsDirectory: configuration.modelsDirectory)
            result["vocabularyBooster"] = .object(report.json)
            Self.logger.notice("Vocabulary booster warm: \(report.readiness.rawValue, privacy: .public), source \(report.source?.rawValue ?? "none", privacy: .public), model load \(report.modelLoadSeconds, format: .fixed(precision: 3), privacy: .public) s, warm inference \(report.warmInferenceSeconds ?? 0, format: .fixed(precision: 3), privacy: .public) s")
        }
        let total = (ContinuousClock.now - started).seconds
        result["timings"] = .object(["totalSeconds": .number(total)])
        Self.logger.notice("Dictation warm finished in \(total, format: .fixed(precision: 3), privacy: .public) s (speech \(speech, privacy: .public))")
        return result
    }

    /// Returns "retained" or "loaded".
    private func warmSpeech() async throws -> String {
        if manager != nil { return "retained" }
        let loadStarted = ContinuousClock.now
        let manifest = try ModelManifest.loadValidated(from: configuration.manifestURL, modelsDirectory: configuration.modelsDirectory)
        let loaded = try await OfflineModelLoader.loadASR(manifest: manifest, modelsDirectory: configuration.modelsDirectory)
        let asr = AsrManager(config: ASRConfig(sampleRate: ASRConstants.sampleRate, streamingEnabled: true))
        try await asr.loadModels(loaded)
        // The compiled Silero asset is shipped with the worker. Load it by explicit
        // URL: FluidAudio's convenience path can attempt a runtime download.
        guard let modelURL = Bundle.module.url(forResource: "silero-vad-unified-256ms-v6.2.1", withExtension: "mlmodelc") else {
            throw DictationError.invalidRequest("Offline Silero VAD asset is missing from the worker.")
        }
        let vadModel = try MLModel(contentsOf: modelURL)
        vad = VadManager(vadModel: vadModel)
        models = loaded
        manager = asr
        Self.logger.notice("Speech recognition loaded in \((ContinuousClock.now - loadStarted).seconds, format: .fixed(precision: 3), privacy: .public) s")
        return "loaded"
    }

    private func dictate(_ payload: [String: JSONValue]) async throws -> [String: JSONValue] {
        guard let path = payload["audioPath"]?.stringValue, path.hasPrefix("/"),
              let runPath = payload["runDirectory"]?.stringValue, runPath.hasPrefix("/") else {
            throw DictationError.invalidRequest("dictate requires absolute audioPath and runDirectory.")
        }
        let audioURL = URL(fileURLWithPath: path).standardizedFileURL
        let runURL = URL(fileURLWithPath: runPath, isDirectory: true).standardizedFileURL
        guard audioURL.deletingLastPathComponent() == runURL,
              FileManager.default.fileExists(atPath: audioURL.path) else {
            throw DictationError.invalidRequest("audioPath must be an existing file directly in runDirectory.")
        }
        let snapshot = try WorkerVocabularySnapshot.load(in: runURL, path: payload["vocabularyPath"]?.stringValue)
        let started = ContinuousClock.now
        let speechState = try await warmSpeech()
        guard let manager, let models, let vad else { throw DictationError.invalidRequest("ASR is unavailable.") }
        let file = try AVAudioFile(forReading: audioURL)
        let format = file.processingFormat
        guard abs(format.sampleRate - 16_000) < 0.01, format.channelCount == 1,
              file.length > 0, file.length <= 16_000 * 300 else {
            throw DictationError.invalidRequest("Expected a nonempty 16 kHz mono WAV of at most five minutes.")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw DictationError.invalidRequest("Could not allocate audio buffer.")
        }
        try file.read(into: buffer)
        let vadStarted = ContinuousClock.now
        let speech = try await vad.process(buffer)
        let vadSeconds = (ContinuousClock.now - vadStarted).seconds
        guard speech.contains(where: { $0.isVoiceActive }) else {
            return ["stage": .string("dictate"), "status": .string("no_speech"), "text": .string(""), "tokens": .array([])]
        }
        // Parakeet v3 returned an empty result for a real three-second clip
        // in the signed-process spike. Six seconds with a silent tail yielded
        // the expected words, so pad short speech only after VAD has accepted it.
        let inferenceBuffer: AVAudioPCMBuffer
        if buffer.frameLength < 16_000 * 6,
           let source = buffer.floatChannelData?[0],
           let padded = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000 * 6),
           let destination = padded.floatChannelData?[0] {
            destination.update(from: source, count: Int(buffer.frameLength))
            destination.advanced(by: Int(buffer.frameLength)).update(
                repeating: 0, count: 16_000 * 6 - Int(buffer.frameLength)
            )
            padded.frameLength = 16_000 * 6
            inferenceBuffer = padded
        } else {
            inferenceBuffer = buffer
        }
        var state = TdtDecoderState.make(decoderLayers: models.version.decoderLayers)
        let language = payload["language"]?.stringValue.flatMap { $0 == "automatic" || $0 == "auto" ? nil : Language(rawValue: $0) }
        let asrStarted = ContinuousClock.now
        let result = try await manager.transcribe(inferenceBuffer, decoderState: &state, language: language)
        let asrSeconds = (ContinuousClock.now - asrStarted).seconds
        let duration = Double(buffer.frameLength) / 16_000
        let tokens: [JSONValue] = (result.tokenTimings ?? []).map { token in
            let start = min(max(0, token.startTime), duration)
            let end = min(max(start, token.endTime), duration)
            return .object([
                "text": .string(token.token),
                "tokenID": .number(Double(token.tokenId)),
                "startSeconds": .number(start),
                "endSeconds": .number(end),
                "confidence": .number(Double(token.confidence)),
            ])
        }
        let corrected = await OfflineVocabularyRescorer.rescore(booster: booster, fileURL: audioURL, text: result.text,
            tokens: (result.tokenTimings ?? []).filter { $0.startTime < duration }.map {
                TokenTiming(token: $0.token, tokenId: $0.tokenId, startTime: $0.startTime, endTime: min(duration, $0.endTime), confidence: $0.confidence)
            }, snapshot: snapshot, manifestURL: configuration.manifestURL, modelsDirectory: configuration.modelsDirectory)
        let report = corrected.booster
        let timings: [String: JSONValue] = [
            "speechLoad": .string(speechState),
            "vadSeconds": .number(vadSeconds),
            "speechRecognitionSeconds": .number(asrSeconds),
            "vocabularyPreparationSeconds": .number(report.preparationSeconds),
            "vocabularyModelLoadSeconds": .number(report.modelLoadSeconds),
            "acousticSpottingSeconds": .number(corrected.spottingSeconds),
            "candidateComparisonSeconds": .number(corrected.comparisonSeconds),
            "totalSeconds": .number((ContinuousClock.now - started).seconds),
        ]
        Self.logger.notice("Dictation timings: speech \(speechState, privacy: .public), VAD \(vadSeconds, format: .fixed(precision: 3), privacy: .public) s, ASR \(asrSeconds, format: .fixed(precision: 3), privacy: .public) s, vocabulary \(report.readiness.rawValue, privacy: .public)/\(report.source?.rawValue ?? "none", privacy: .public) prep \(report.preparationSeconds, format: .fixed(precision: 3), privacy: .public) s (model load \(report.modelLoadSeconds, format: .fixed(precision: 3), privacy: .public) s), spotting \(corrected.spottingSeconds, format: .fixed(precision: 3), privacy: .public) s, comparison \(corrected.comparisonSeconds, format: .fixed(precision: 3), privacy: .public) s")
        if let source = report.source, source != .retained {
            Self.logger.notice("Vocabulary booster \(source.rawValue, privacy: .public) on the dictation path; the helper process was not restarted")
        }
        var response: [String: JSONValue] = ["stage": .string("dictate"), "status": .string("complete"),
            "text": .string(corrected.text), "rawText": .string(result.text), "tokens": .array(tokens),
            "timings": .object(timings), "vocabularyBooster": .object(report.json)]
        if let warning = corrected.warning { response["vocabularyWarning"] = .string(warning) }
        if let revision = snapshot.revision { response["vocabularyRevision"] = .string(revision) }
        // Retain raw/corrected text, snapshot revision and replacement spans together.
        struct Record: Encodable {
            let rawText: String; let text: String; let vocabularyRevision: String?
            let vocabularyReplacements: [VocabularyReplacement]; let vocabularyWarning: String?
        }
        try JSONEncoder().encode(Record(rawText: result.text, text: corrected.text, vocabularyRevision: snapshot.revision,
            vocabularyReplacements: corrected.replacements, vocabularyWarning: corrected.warning))
            .write(to: runURL.appendingPathComponent("dictation-transcript.json"), options: .atomic)
        return response
    }

    public enum DictationError: LocalizedError {
        case invalidRequest(String)
        public var errorDescription: String? {
            if case let .invalidRequest(message) = self { return message }
            return nil
        }
    }
}

extension VocabularyBooster.Report {
    /// Readiness, source and timings only; never terms.
    var json: [String: JSONValue] {
        var value: [String: JSONValue] = [
            "readiness": .string(readiness.rawValue),
            "preparationSeconds": .number(preparationSeconds),
            "modelLoadSeconds": .number(modelLoadSeconds),
            "contextReused": .bool(contextReused),
        ]
        if let source { value["source"] = .string(source.rawValue) }
        if let warmInferenceSeconds { value["warmInferenceSeconds"] = .number(warmInferenceSeconds) }
        return value
    }
}
