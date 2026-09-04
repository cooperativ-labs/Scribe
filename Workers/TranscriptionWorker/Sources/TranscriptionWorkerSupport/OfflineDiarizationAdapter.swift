import FluidAudio
import Foundation

/// Offline, whole-recording diarization over the local FluidAudio VBx stack.
/// The adapter deliberately creates a disk-backed source even for short
/// recordings. This keeps decoded PCM out of the Swift heap for multi-hour
/// inputs and ensures clusters are global to the complete recording.
public struct OfflineDiarizationAdapter: Sendable {
    public struct Configuration: Sendable, Equatable {
        /// Applies FluidAudio's exact global-cluster constraint when supplied.
        public let knownSpeakerCount: Int?
        public let computeUnits: ASRComputeUnits
        public let allowLowPrecisionAccumulationOnGPU: Bool
        /// The pinned FluidAudio build exposes overlap through nonexclusive
        /// reconstruction. This must remain true for canonical transcripts.
        public let preserveOverlappingIntervals: Bool

        public init(
            knownSpeakerCount: Int? = nil,
            computeUnits: ASRComputeUnits = .cpuAndNeuralEngine,
            allowLowPrecisionAccumulationOnGPU: Bool = true,
            preserveOverlappingIntervals: Bool = true
        ) {
            self.knownSpeakerCount = knownSpeakerCount
            self.computeUnits = computeUnits
            self.allowLowPrecisionAccumulationOnGPU = allowLowPrecisionAccumulationOnGPU
            self.preserveOverlappingIntervals = preserveOverlappingIntervals
        }
    }

    public struct SpeakerInterval: Codable, Sendable, Equatable {
        /// Stable only within this recording, assigned in order of appearance.
        public let speakerID: String
        public let startSeconds: TimeInterval
        public let endSeconds: TimeInterval
        public let qualityScore: Float
        public let overlapsAnotherSpeaker: Bool
    }

    /// A normalized global speaker vector suitable for comparison only with a
    /// vector carrying the same compatibility metadata.
    public struct SpeakerEmbedding: Codable, Sendable, Equatable {
        public let speakerID: String
        public let vector: [Float]
        public let modelID: String
        public let modelRevision: String
        public let preprocessingVersion: String
        public let normalizationVersion: String
    }

    public struct Result: Codable, Sendable, Equatable {
        public let intervals: [SpeakerInterval]
        public let embeddings: [SpeakerEmbedding]
        public let sourceDurationSeconds: TimeInterval
        public let usedDiskBackedAudio: Bool
        public let timings: Timings?
    }

    public struct Timings: Codable, Sendable, Equatable {
        public let audioLoadingSeconds: TimeInterval
        public let segmentationSeconds: TimeInterval
        public let embeddingExtractionSeconds: TimeInterval
        public let speakerClusteringSeconds: TimeInterval
        public let postProcessingSeconds: TimeInterval
        public let totalProcessingSeconds: TimeInterval
    }

    public enum Error: Swift.Error, LocalizedError, Sendable, Equatable {
        case inputDoesNotExist(String)
        case invalidKnownSpeakerCount(Int)
        case noEmbeddings
        case invalidInterval(Int)

        public var errorDescription: String? {
            switch self {
            case let .inputDoesNotExist(path): "Input audio does not exist at \(path)."
            case let .invalidKnownSpeakerCount(count): "knownSpeakerCount must be positive, got \(count)."
            case .noEmbeddings: "FluidAudio returned diarization intervals without exported speaker embeddings."
            case let .invalidInterval(index): "FluidAudio returned an invalid diarization interval at index \(index)."
            }
        }
    }

    private static let embeddingModelID = "wespeaker-embedding-coreml"
    private static let preprocessingVersion = "fluidaudio-offline-fbank-16khz-mono-v0.12.4"
    private static let normalizationVersion = "l2-unit-v1"

    public let manifest: ModelManifest
    public let modelsDirectory: URL
    public let configuration: Configuration

    public init(manifest: ModelManifest, modelsDirectory: URL, configuration: Configuration = .init()) {
        self.manifest = manifest
        self.modelsDirectory = modelsDirectory
        self.configuration = configuration
    }

    /// Processes the whole recording in one global clustering run.  The source
    /// factory decodes to a temporary mmap-backed 16 kHz mono PCM file; its
    /// temporary data is removed immediately after the manager returns.
    public func diarize(fileURL: URL) async throws -> Result {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw Error.inputDoesNotExist(fileURL.path)
        }
        if let count = configuration.knownSpeakerCount, count <= 0 {
            throw Error.invalidKnownSpeakerCount(count)
        }

        var diarizerConfiguration = OfflineDiarizerConfig.default
        diarizerConfiguration.postProcessing.exclusiveSegments = !configuration.preserveOverlappingIntervals
        if let count = configuration.knownSpeakerCount {
            diarizerConfiguration = diarizerConfiguration.withSpeakers(exactly: count)
        }

        let sourceResult = try StreamingAudioSourceFactory().makeDiskBackedSource(
            from: fileURL,
            targetSampleRate: diarizerConfiguration.segmentation.sampleRate
        )
        defer { sourceResult.source.cleanup() }

        let models = try OfflineModelLoader.loadDiarization(
            manifest: manifest,
            modelsDirectory: modelsDirectory,
            computeUnits: configuration.computeUnits,
            allowLowPrecisionAccumulationOnGPU: configuration.allowLowPrecisionAccumulationOnGPU
        )
        let manager = OfflineDiarizerManager(config: diarizerConfiguration)
        manager.initialize(models: models)
        let rawResult = try await manager.process(
            audioSource: sourceResult.source,
            audioLoadingSeconds: sourceResult.loadDuration
        )
        let duration = Double(sourceResult.source.sampleCount) / Double(diarizerConfiguration.segmentation.sampleRate)
        return try makeResult(rawResult, sourceDuration: duration)
    }

    /// Kept internal for deterministic tests of labels, overlap preservation,
    /// and vector compatibility without invoking Core ML.
    func makeResult(_ rawResult: DiarizationResult, sourceDuration: TimeInterval) throws -> Result {
        let ordered = rawResult.segments.sorted {
            if $0.startTimeSeconds == $1.startTimeSeconds { return $0.endTimeSeconds < $1.endTimeSeconds }
            return $0.startTimeSeconds < $1.startTimeSeconds
        }
        var stableIDs: [String: String] = [:]
        var intervals: [SpeakerInterval] = []
        for (index, segment) in ordered.enumerated() {
            let start = max(0, Double(segment.startTimeSeconds))
            let end = min(Double(segment.endTimeSeconds), sourceDuration)
            guard start.isFinite, end.isFinite, end > start else {
                // FluidAudio can emit a trailing window slightly past the
                // source duration; skip empty remnants rather than failing
                // an otherwise valid embedding export.
                continue
            }
            if stableIDs[segment.speakerId] == nil {
                stableIDs[segment.speakerId] = "speaker_\(stableIDs.count + 1)"
            }
            intervals.append(
                SpeakerInterval(
                    speakerID: stableIDs[segment.speakerId]!,
                    startSeconds: start,
                    endSeconds: end,
                    qualityScore: segment.qualityScore,
                    overlapsAnotherSpeaker: ordered.enumerated().contains { otherIndex, other in
                        otherIndex != index && other.speakerId != segment.speakerId
                            && other.startTimeSeconds < segment.endTimeSeconds
                            && segment.startTimeSeconds < other.endTimeSeconds
                    }
                )
            )
        }

        guard let database = rawResult.speakerDatabase, !database.isEmpty else { throw Error.noEmbeddings }
        for rawID in database.keys.sorted() where stableIDs[rawID] == nil {
            stableIDs[rawID] = "speaker_\(stableIDs.count + 1)"
        }
        let embeddingAsset = manifest.assets.first { $0.id == "wespeaker-embeddings" }
        let revision = embeddingAsset?.upstream.revision ?? "unknown"
        let embeddings = database.compactMap { rawID, vector -> SpeakerEmbedding? in
            guard let stableID = stableIDs[rawID], let normalized = normalized(vector) else { return nil }
            return SpeakerEmbedding(
                speakerID: stableID,
                vector: normalized,
                modelID: Self.embeddingModelID,
                modelRevision: revision,
                preprocessingVersion: Self.preprocessingVersion,
                normalizationVersion: Self.normalizationVersion
            )
        }.sorted { $0.speakerID < $1.speakerID }
        guard embeddings.count == stableIDs.count else { throw Error.noEmbeddings }

        return Result(
            intervals: intervals,
            embeddings: embeddings,
            sourceDurationSeconds: sourceDuration,
            usedDiskBackedAudio: true,
            timings: rawResult.timings.map {
                Timings(
                    audioLoadingSeconds: $0.audioLoadingSeconds,
                    segmentationSeconds: $0.segmentationSeconds,
                    embeddingExtractionSeconds: $0.embeddingExtractionSeconds,
                    speakerClusteringSeconds: $0.speakerClusteringSeconds,
                    postProcessingSeconds: $0.postProcessingSeconds,
                    totalProcessingSeconds: $0.totalProcessingSeconds
                )
            }
        )
    }

    private func normalized(_ vector: [Float]) -> [Float]? {
        guard !vector.isEmpty, vector.allSatisfy(\.isFinite) else { return nil }
        let squared = vector.reduce(Float.zero) { $0 + $1 * $1 }
        guard squared.isFinite, squared > 0 else { return nil }
        let scale = 1 / squared.squareRoot()
        return vector.map { $0 * scale }
    }
}
