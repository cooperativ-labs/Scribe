import ScribeInference
@preconcurrency import AVFoundation
@preconcurrency import CoreML
import FluidAudio
import Foundation

/// A single ASR manager is retained for the lifetime of the dictation worker.
/// Batch jobs use their original per-job worker and never enter this actor.
public actor WorkerDictationSession {
    private let configuration: WorkerJobRunner.Configuration
    private var models: AsrModels?
    private var manager: AsrManager?
    private var vad: VadManager?

    public init(configuration: WorkerJobRunner.Configuration) {
        self.configuration = configuration
    }

    public func handle(operation: String, requestID: String, payload: [String: JSONValue], emit: (WorkerEnvelope) -> Void) async {
        do {
            let result: [String: JSONValue]
            switch operation {
            case "warm": result = try await warm()
            case "dictate": result = try await dictate(payload)
            case "unload":
                models = nil
                manager = nil
                vad = nil
                result = ["stage": .string("unload"), "status": .string("ready")]
            default: throw DictationError.invalidRequest("Unsupported operation \(operation).")
            }
            emit(WorkerEnvelope(version: 2, kind: .stageResult, requestID: requestID, payload: .object(result)))
        } catch {
            emit(WorkerProtocol.error(requestID: requestID, code: "dictation_failed", message: error.localizedDescription, version: 2))
        }
    }

    private func warm() async throws -> [String: JSONValue] {
        if manager != nil { return ["stage": .string("warm"), "status": .string("ready")] }
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
        return ["stage": .string("warm"), "status": .string("ready")]
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
        _ = try await warm()
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
        let speech = try await vad.process(buffer)
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
        let result = try await manager.transcribe(inferenceBuffer, decoderState: &state, language: language)
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
        return ["stage": .string("dictate"), "status": .string("complete"), "text": .string(result.text), "tokens": .array(tokens)]
    }

    public enum DictationError: LocalizedError {
        case invalidRequest(String)
        public var errorDescription: String? {
            if case let .invalidRequest(message) = self { return message }
            return nil
        }
    }
}
