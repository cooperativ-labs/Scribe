@preconcurrency import AVFoundation
import FluidAudio
import Foundation

/// Offline Parakeet v3 adapter for a *already prepared* 16 kHz mono source.
///
/// `AsrManager.transcribe(_:decoderState:)` is deliberately used instead of a
/// custom window implementation. In the pinned FluidAudio v0.17.4 it switches long
/// files to its disk-backed `ChunkProcessor`, which keeps 80 ms left context,
/// uses a 2 s overlap, rebases decoder frames by the chunk start, and removes
/// boundary duplicates before returning `ASRResult.tokenTimings` in seconds.
///
/// v0.12.5 first carried the decoder's own token durations all the way through
/// that chunk merge. v0.17.4 also includes upstream seam reconciliation,
/// fresh-state final-window decoding, and vocabulary-derived punctuation.
/// Word ends are decoder durations rather than next-token endpoints, so a token may
/// legitimately end a few frames past the prepared audio; that tail is clamped
/// to the source duration rather than rejected.
public struct ParakeetAdapter: Sendable {
    public struct Configuration: Sendable, Equatable {
        public let computeUnits: ASRComputeUnits
        public let allowLowPrecisionAccumulationOnGPU: Bool
        /// Files longer than this are sent through FluidAudio's disk-backed,
        /// overlap-aware chunk processor. The pinned model limit is 240,000
        /// samples (15 seconds at 16 kHz).
        public let streamingThresholdSamples: Int

        public init(
            computeUnits: ASRComputeUnits = .cpuAndNeuralEngine,
            allowLowPrecisionAccumulationOnGPU: Bool = true,
            streamingThresholdSamples: Int? = nil
        ) {
            self.computeUnits = computeUnits
            self.allowLowPrecisionAccumulationOnGPU = allowLowPrecisionAccumulationOnGPU
            self.streamingThresholdSamples = streamingThresholdSamples ?? ASRConstants.maxModelSamples
        }
    }

    public struct TimedToken: Codable, Sendable, Equatable {
        public let text: String
        public let tokenID: Int
        /// Source-media seconds, never chunk-relative frames.
        public let startSeconds: TimeInterval
        /// Source-media seconds, never chunk-relative frames.
        public let endSeconds: TimeInterval
        public let confidence: Float

        package init(
            text: String,
            tokenID: Int,
            startSeconds: TimeInterval,
            endSeconds: TimeInterval,
            confidence: Float
        ) {
            self.text = text
            self.tokenID = tokenID
            self.startSeconds = startSeconds
            self.endSeconds = endSeconds
            self.confidence = confidence
        }
    }

    public struct Transcript: Codable, Sendable, Equatable {
        public let text: String
        public let tokens: [TimedToken]
        public let sourceDurationSeconds: TimeInterval
        public let processingTimeSeconds: TimeInterval
        public let usedChunkedProcessing: Bool
        public let timestampUnit: String

        package init(
            text: String,
            tokens: [TimedToken],
            sourceDurationSeconds: TimeInterval,
            processingTimeSeconds: TimeInterval,
            usedChunkedProcessing: Bool,
            timestampUnit: String
        ) {
            self.text = text
            self.tokens = tokens
            self.sourceDurationSeconds = sourceDurationSeconds
            self.processingTimeSeconds = processingTimeSeconds
            self.usedChunkedProcessing = usedChunkedProcessing
            self.timestampUnit = timestampUnit
        }
    }

    public enum Error: Swift.Error, LocalizedError, Sendable, Equatable {
        case inputDoesNotExist(String)
        case notSixteenKilohertzMono(sampleRate: Double, channels: Int)
        case missingTokenTimings
        case invalidTokenTiming(index: Int)
        case audioInspectionFailed(String)

        public var errorDescription: String? {
            switch self {
            case let .inputDoesNotExist(path): "Input audio does not exist at \(path)."
            case let .notSixteenKilohertzMono(sampleRate, channels):
                "ParakeetAdapter requires prepared 16 kHz mono PCM audio; received \(sampleRate) Hz and \(channels) channel(s)."
            case .missingTokenTimings: "FluidAudio returned transcript text without the required token timings."
            case let .invalidTokenTiming(index): "FluidAudio returned an invalid token timing at index \(index)."
            case let .audioInspectionFailed(message): "Could not inspect input audio: \(message)"
            }
        }
    }

    public let manifest: ModelManifest
    public let modelsDirectory: URL
    public let configuration: Configuration

    public init(manifest: ModelManifest, modelsDirectory: URL, configuration: Configuration = .init()) {
        self.manifest = manifest
        self.modelsDirectory = modelsDirectory
        self.configuration = configuration
    }

    /// Transcribes a local 16 kHz mono file.  Long files use the pinned
    /// FluidAudio disk-backed chunker and produce source-relative timings.
    public func transcribe(fileURL: URL) async throws -> Transcript {
        let sourceDuration = try validatePreparedAudio(fileURL)
        let models = try await OfflineModelLoader.loadASR(
            manifest: manifest,
            modelsDirectory: modelsDirectory,
            computeUnits: configuration.computeUnits,
            allowLowPrecisionAccumulationOnGPU: configuration.allowLowPrecisionAccumulationOnGPU
        )
        let manager = AsrManager(config: ASRConfig(
            sampleRate: ASRConstants.sampleRate,
            streamingEnabled: true,
            streamingThreshold: configuration.streamingThresholdSamples
        ))
        try await manager.loadModels(models)
        var decoderState = TdtDecoderState.make(decoderLayers: models.version.decoderLayers)
        let result = try await manager.transcribe(fileURL, decoderState: &decoderState)
        return try makeTranscript(result, sourceDuration: sourceDuration)
    }

    /// Kept internal so unit tests can verify the host-facing timing contract
    /// without loading Core ML models.
    func makeTranscript(_ result: ASRResult, sourceDuration: TimeInterval) throws -> Transcript {
        let timings = result.tokenTimings ?? []
        if !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && timings.isEmpty {
            throw Error.missingTokenTimings
        }
        let tokens = try timings.enumerated().map { index, timing in
            // `startTime` still has to land inside the recording: a start past
            // the end is the signature of a chunk-rebasing bug and must fail
            // loudly. `endTime` is now a decoder duration rather than the next
            // token's start, so the final tokens of a recording can round a
            // frame or two past the prepared audio; clamp those instead.
            guard timing.startTime.isFinite, timing.endTime.isFinite,
                  timing.startTime >= 0, timing.endTime >= timing.startTime,
                  timing.startTime <= sourceDuration + 0.001 else {
                throw Error.invalidTokenTiming(index: index)
            }
            let startSeconds = min(timing.startTime, sourceDuration)
            return TimedToken(
                text: timing.token,
                tokenID: timing.tokenId,
                startSeconds: startSeconds,
                endSeconds: max(startSeconds, min(timing.endTime, sourceDuration)),
                confidence: timing.confidence
            )
        }
        return Transcript(
            text: result.text,
            tokens: tokens,
            sourceDurationSeconds: sourceDuration,
            processingTimeSeconds: result.processingTime,
            usedChunkedProcessing: sourceDuration * Double(ASRConstants.sampleRate) > Double(configuration.streamingThresholdSamples),
            timestampUnit: "seconds"
        )
    }

    private func validatePreparedAudio(_ fileURL: URL) throws -> TimeInterval {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw Error.inputDoesNotExist(fileURL.path)
        }
        do {
            let audioFile = try AVAudioFile(forReading: fileURL)
            let format = audioFile.processingFormat
            guard abs(format.sampleRate - Double(ASRConstants.sampleRate)) < 0.001,
                  format.channelCount == 1 else {
                throw Error.notSixteenKilohertzMono(sampleRate: format.sampleRate, channels: Int(format.channelCount))
            }
            return Double(audioFile.length) / format.sampleRate
        } catch let error as Error {
            throw error
        } catch {
            throw Error.audioInspectionFailed(error.localizedDescription)
        }
    }
}
