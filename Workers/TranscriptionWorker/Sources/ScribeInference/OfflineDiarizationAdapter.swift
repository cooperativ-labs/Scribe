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
        public let maximumSpeakerCount: Int?
        public let minimumGapDurationSeconds: Double
        /// Maps to segmentation.minDurationOn; reconstruction also applies the embedding duration floor.
        public let minimumSegmentDurationSeconds: Double
        public let computeUnits: ASRComputeUnits
        public let allowLowPrecisionAccumulationOnGPU: Bool
        /// The pinned FluidAudio build exposes overlap through nonexclusive
        /// reconstruction. This must remain true for canonical transcripts.
        public let preserveOverlappingIntervals: Bool
        /// FluidAudio's AHC dendrogram cut distance. Exposed so the offline
        /// benchmark can compare supported configurations without patching a
        /// SwiftPM checkout; production keeps the pinned community default.
        public let clusteringThreshold: Double
        public let embeddingExcludeOverlap: Bool
        public let minimumEmbeddingDurationSeconds: Double
        public let segmentationStepRatio: Double

        public init(
            knownSpeakerCount: Int? = nil,
            maximumSpeakerCount: Int? = nil,
            minimumGapDurationSeconds: Double = 0.1,
            minimumSegmentDurationSeconds: Double = 0.0,
            computeUnits: ASRComputeUnits = .cpuAndNeuralEngine,
            allowLowPrecisionAccumulationOnGPU: Bool = true,
            preserveOverlappingIntervals: Bool = true,
            clusteringThreshold: Double = 0.6,
            embeddingExcludeOverlap: Bool = true,
            minimumEmbeddingDurationSeconds: Double = 1.0,
            segmentationStepRatio: Double = 0.2
        ) {
            self.knownSpeakerCount = knownSpeakerCount
            self.maximumSpeakerCount = maximumSpeakerCount
            self.minimumGapDurationSeconds = minimumGapDurationSeconds
            self.minimumSegmentDurationSeconds = minimumSegmentDurationSeconds
            self.computeUnits = computeUnits
            self.allowLowPrecisionAccumulationOnGPU = allowLowPrecisionAccumulationOnGPU
            self.preserveOverlappingIntervals = preserveOverlappingIntervals
            self.clusteringThreshold = clusteringThreshold
            self.embeddingExcludeOverlap = embeddingExcludeOverlap
            self.minimumEmbeddingDurationSeconds = minimumEmbeddingDurationSeconds
            self.segmentationStepRatio = segmentationStepRatio
        }
    }

    public struct Engine: Codable, Sendable, Equatable {
        public let runtime: String
        public let runtimeRevision: String
        public let modelRevision: String

        package init(
            runtime: String,
            runtimeRevision: String,
            modelRevision: String
        ) {
            self.runtime = runtime
            self.runtimeRevision = runtimeRevision
            self.modelRevision = modelRevision
        }
    }

    public struct AppliedConfiguration: Codable, Sendable, Equatable {
        public let knownSpeakerCount: Int?
        public let maximumSpeakerCount: Int?
        public let minimumGapDurationSeconds: Double
        /// Maps to segmentation.minDurationOn; reconstruction also applies the embedding duration floor.
        public let minimumSegmentDurationSeconds: Double
        public let clusteringThreshold: Double
        public let embeddingExcludeOverlap: Bool
        public let minimumEmbeddingDurationSeconds: Double
        public let segmentationStepRatio: Double
        public let preserveOverlappingIntervals: Bool
        public let constrainedAssignment: Bool
        public let warmStartFa: Double
        public let warmStartFb: Double
        public let maximumVBxIterations: Int

        package init(
            knownSpeakerCount: Int?,
            maximumSpeakerCount: Int?,
            minimumGapDurationSeconds: Double,
            minimumSegmentDurationSeconds: Double,
            clusteringThreshold: Double,
            embeddingExcludeOverlap: Bool,
            minimumEmbeddingDurationSeconds: Double,
            segmentationStepRatio: Double,
            preserveOverlappingIntervals: Bool,
            constrainedAssignment: Bool,
            warmStartFa: Double,
            warmStartFb: Double,
            maximumVBxIterations: Int
        ) {
            self.knownSpeakerCount = knownSpeakerCount
            self.maximumSpeakerCount = maximumSpeakerCount
            self.minimumGapDurationSeconds = minimumGapDurationSeconds
            self.minimumSegmentDurationSeconds = minimumSegmentDurationSeconds
            self.clusteringThreshold = clusteringThreshold
            self.embeddingExcludeOverlap = embeddingExcludeOverlap
            self.minimumEmbeddingDurationSeconds = minimumEmbeddingDurationSeconds
            self.segmentationStepRatio = segmentationStepRatio
            self.preserveOverlappingIntervals = preserveOverlappingIntervals
            self.constrainedAssignment = constrainedAssignment
            self.warmStartFa = warmStartFa
            self.warmStartFb = warmStartFb
            self.maximumVBxIterations = maximumVBxIterations
        }
    }

    public struct ClusterOccupancy: Codable, Sendable, Equatable {
        public let clusterID: String
        public let embeddingCount: Int
        public let intervalCount: Int
        public let intervalSeconds: TimeInterval

        package init(
            clusterID: String,
            embeddingCount: Int,
            intervalCount: Int,
            intervalSeconds: TimeInterval
        ) {
            self.clusterID = clusterID
            self.embeddingCount = embeddingCount
            self.intervalCount = intervalCount
            self.intervalSeconds = intervalSeconds
        }
    }

    public struct ClusteringDiagnostics: Codable, Sendable, Equatable {
        public let heuristicVersion: String
        public let embeddingCount: Int
        public let intervalCount: Int
        public let overlapIntervalCount: Int
        public let occupancies: [ClusterOccupancy]
        public let dominantEmbeddingFraction: Double?
        public let dominantIntervalFraction: Double?
        /// This is deliberately a review signal, not an inferred speaker
        /// count. A genuine monologue can be highly imbalanced too.
        public let separationAppearsCollapsed: Bool

        package init(
            heuristicVersion: String,
            embeddingCount: Int,
            intervalCount: Int,
            overlapIntervalCount: Int,
            occupancies: [ClusterOccupancy],
            dominantEmbeddingFraction: Double?,
            dominantIntervalFraction: Double?,
            separationAppearsCollapsed: Bool
        ) {
            self.heuristicVersion = heuristicVersion
            self.embeddingCount = embeddingCount
            self.intervalCount = intervalCount
            self.overlapIntervalCount = overlapIntervalCount
            self.occupancies = occupancies
            self.dominantEmbeddingFraction = dominantEmbeddingFraction
            self.dominantIntervalFraction = dominantIntervalFraction
            self.separationAppearsCollapsed = separationAppearsCollapsed
        }
    }

    public struct SpeakerInterval: Codable, Sendable, Equatable {
        /// Stable only within this recording, assigned in order of appearance.
        public let speakerID: String
        public let startSeconds: TimeInterval
        public let endSeconds: TimeInterval
        public let qualityScore: Float
        public let overlapsAnotherSpeaker: Bool

        package init(
            speakerID: String,
            startSeconds: TimeInterval,
            endSeconds: TimeInterval,
            qualityScore: Float,
            overlapsAnotherSpeaker: Bool
        ) {
            self.speakerID = speakerID
            self.startSeconds = startSeconds
            self.endSeconds = endSeconds
            self.qualityScore = qualityScore
            self.overlapsAnotherSpeaker = overlapsAnotherSpeaker
        }
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

        package init(
            speakerID: String,
            vector: [Float],
            modelID: String,
            modelRevision: String,
            preprocessingVersion: String,
            normalizationVersion: String
        ) {
            self.speakerID = speakerID
            self.vector = vector
            self.modelID = modelID
            self.modelRevision = modelRevision
            self.preprocessingVersion = preprocessingVersion
            self.normalizationVersion = normalizationVersion
        }
    }

    public struct Result: Codable, Sendable, Equatable {
        public let intervals: [SpeakerInterval]
        public let embeddings: [SpeakerEmbedding]
        public let sourceDurationSeconds: TimeInterval
        public let usedDiskBackedAudio: Bool
        public let timings: Timings?
        public let engine: Engine
        public let configuration: AppliedConfiguration
        public let clusteringDiagnostics: ClusteringDiagnostics

        package init(
            intervals: [SpeakerInterval],
            embeddings: [SpeakerEmbedding],
            sourceDurationSeconds: TimeInterval,
            usedDiskBackedAudio: Bool,
            timings: Timings?,
            engine: Engine,
            configuration: AppliedConfiguration,
            clusteringDiagnostics: ClusteringDiagnostics
        ) {
            self.intervals = intervals
            self.embeddings = embeddings
            self.sourceDurationSeconds = sourceDurationSeconds
            self.usedDiskBackedAudio = usedDiskBackedAudio
            self.timings = timings
            self.engine = engine
            self.configuration = configuration
            self.clusteringDiagnostics = clusteringDiagnostics
        }
    }

    public struct Timings: Codable, Sendable, Equatable {
        public let audioLoadingSeconds: TimeInterval
        public let segmentationSeconds: TimeInterval
        public let embeddingExtractionSeconds: TimeInterval
        public let speakerClusteringSeconds: TimeInterval
        public let postProcessingSeconds: TimeInterval
        public let totalProcessingSeconds: TimeInterval

        package init(
            audioLoadingSeconds: TimeInterval,
            segmentationSeconds: TimeInterval,
            embeddingExtractionSeconds: TimeInterval,
            speakerClusteringSeconds: TimeInterval,
            postProcessingSeconds: TimeInterval,
            totalProcessingSeconds: TimeInterval
        ) {
            self.audioLoadingSeconds = audioLoadingSeconds
            self.segmentationSeconds = segmentationSeconds
            self.embeddingExtractionSeconds = embeddingExtractionSeconds
            self.speakerClusteringSeconds = speakerClusteringSeconds
            self.postProcessingSeconds = postProcessingSeconds
            self.totalProcessingSeconds = totalProcessingSeconds
        }
    }

    public enum Error: Swift.Error, LocalizedError, Sendable, Equatable {
        case inputDoesNotExist(String)
        case invalidKnownSpeakerCount(Int)
        case invalidConfiguration(String)
        case noEmbeddings
        case invalidInterval(Int)

        public var errorDescription: String? {
            switch self {
            case let .inputDoesNotExist(path): "Input audio does not exist at \(path)."
            case let .invalidKnownSpeakerCount(count): "knownSpeakerCount must be positive, got \(count)."
            case let .invalidConfiguration(message): message
            case .noEmbeddings: "FluidAudio returned diarization intervals without exported speaker embeddings."
            case let .invalidInterval(index): "FluidAudio returned an invalid diarization interval at index \(index)."
            }
        }
    }

    private static let embeddingModelID = "wespeaker-embedding-coreml"
    public static let fluidAudioVersion = "0.17.4"
    public static let fluidAudioRevision = "21493f8dac5a97e65742e6ff26f42f164c2fda0f"
    /// v0.15.6 fixes the mask-matrix transpose and rejects very low-support
    /// masks before embedding. Those operations change vector semantics even
    /// though the WeSpeaker weights are unchanged, so old voiceprints must not
    /// be compared as if they shared a representation.
    /// The offline diarizer source is unchanged from v0.15.7 to v0.17.4;
    /// retain the representation identifier so existing voiceprints remain valid.
    private static let preprocessingVersion = "fluidaudio-offline-fbank-16khz-mono-v0.15.6"
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

        let diarizerConfiguration = try makeDiarizerConfiguration()

        let sourceResult = try AudioSourceFactory().makeDiskBackedSource(
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
        return try makeResult(rawResult, sourceDuration: duration, diarizerConfiguration: diarizerConfiguration)
    }

    func makeDiarizerConfiguration() throws -> OfflineDiarizerConfig {
        if let count = configuration.maximumSpeakerCount, count <= 0 {
            throw Error.invalidConfiguration("maximumSpeakerCount must be positive")
        }
        guard configuration.knownSpeakerCount == nil || configuration.maximumSpeakerCount == nil else {
            throw Error.invalidConfiguration("Choose either an exact count or a maximum count")
        }
        guard configuration.minimumGapDurationSeconds.isFinite, configuration.minimumGapDurationSeconds >= 0,
              configuration.minimumSegmentDurationSeconds.isFinite, configuration.minimumSegmentDurationSeconds >= 0 else {
            throw Error.invalidConfiguration("Minimum gap and duration must be finite and nonnegative")
        }
        var diarizerConfiguration = OfflineDiarizerConfig.default
        diarizerConfiguration.postProcessing.exclusiveSegments = !configuration.preserveOverlappingIntervals
        diarizerConfiguration.clustering.threshold = configuration.clusteringThreshold
        diarizerConfiguration.embedding.excludeOverlap = configuration.embeddingExcludeOverlap
        diarizerConfiguration.embedding.minSegmentDurationSeconds = configuration.minimumEmbeddingDurationSeconds
        diarizerConfiguration.segmentation.stepRatio = configuration.segmentationStepRatio
        diarizerConfiguration.clustering.maxSpeakers = configuration.maximumSpeakerCount
        diarizerConfiguration.postProcessing.minGapDurationSeconds = configuration.minimumGapDurationSeconds
        diarizerConfiguration.segmentation.minDurationOn = configuration.minimumSegmentDurationSeconds
        diarizerConfiguration.exposeChunkEmbeddings = true
        if let count = configuration.knownSpeakerCount {
            diarizerConfiguration = diarizerConfiguration.withSpeakers(exactly: count)
        }

        return diarizerConfiguration
    }

    /// Kept internal for deterministic tests of labels, overlap preservation,
    /// and vector compatibility without invoking Core ML.
    func makeResult(
        _ rawResult: DiarizationResult,
        sourceDuration: TimeInterval,
        diarizerConfiguration: OfflineDiarizerConfig = .default
    ) throws -> Result {
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

        let configurationSnapshot = AppliedConfiguration(
            knownSpeakerCount: configuration.knownSpeakerCount,
            maximumSpeakerCount: diarizerConfiguration.clustering.maxSpeakers,
            minimumGapDurationSeconds: diarizerConfiguration.postProcessing.minGapDurationSeconds,
            minimumSegmentDurationSeconds: diarizerConfiguration.segmentation.minDurationOn,
            clusteringThreshold: diarizerConfiguration.clustering.threshold,
            embeddingExcludeOverlap: diarizerConfiguration.embedding.excludeOverlap,
            minimumEmbeddingDurationSeconds: diarizerConfiguration.embedding.minSegmentDurationSeconds,
            segmentationStepRatio: diarizerConfiguration.segmentation.stepRatio,
            preserveOverlappingIntervals: !diarizerConfiguration.postProcessing.exclusiveSegments,
            constrainedAssignment: diarizerConfiguration.clustering.constrainedAssignment,
            warmStartFa: diarizerConfiguration.clustering.warmStartFa,
            warmStartFb: diarizerConfiguration.clustering.warmStartFb,
            maximumVBxIterations: diarizerConfiguration.vbx.maxIterations
        )
        let diagnostics = makeDiagnostics(
            rawResult: rawResult,
            intervals: intervals,
            stableIDs: stableIDs
        )

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
            },
            engine: Engine(
                runtime: "FluidAudio \(Self.fluidAudioVersion)",
                runtimeRevision: Self.fluidAudioRevision,
                modelRevision: revision
            ),
            configuration: configurationSnapshot,
            clusteringDiagnostics: diagnostics
        )
    }

    private func makeDiagnostics(
        rawResult: DiarizationResult,
        intervals: [SpeakerInterval],
        stableIDs: [String: String]
    ) -> ClusteringDiagnostics {
        let rawEmbeddingCounts = Dictionary(grouping: rawResult.chunkEmbeddings ?? [], by: \.speakerId)
            .mapValues(\.count)
        let intervalGroups = Dictionary(grouping: intervals, by: \.speakerID)
        let rawIDs = Set(rawEmbeddingCounts.keys).union(stableIDs.keys)
        let unobservedIDs = Dictionary(uniqueKeysWithValues: rawIDs.sorted().enumerated().map {
            ($0.element, "unobserved_cluster_\($0.offset + 1)")
        })
        let occupancies = rawIDs.map { rawID -> ClusterOccupancy in
            let clusterID = stableIDs[rawID] ?? unobservedIDs[rawID]!
            let speakerIntervals = intervalGroups[clusterID] ?? []
            return ClusterOccupancy(
                clusterID: clusterID,
                embeddingCount: rawEmbeddingCounts[rawID, default: 0],
                intervalCount: speakerIntervals.count,
                intervalSeconds: speakerIntervals.reduce(0) { $0 + $1.endSeconds - $1.startSeconds }
            )
        }.sorted { $0.clusterID < $1.clusterID }
        let totalEmbeddings = occupancies.reduce(0) { $0 + $1.embeddingCount }
        let totalIntervalSeconds = occupancies.reduce(0) { $0 + $1.intervalSeconds }
        let dominantEmbeddingFraction = totalEmbeddings > 0
            ? Double(occupancies.map(\.embeddingCount).max() ?? 0) / Double(totalEmbeddings)
            : nil
        let dominantIntervalFraction = totalIntervalSeconds > 0
            ? (occupancies.map(\.intervalSeconds).max() ?? 0) / totalIntervalSeconds
            : nil
        let appearsCollapsed = occupancies.count >= 2
            && (dominantEmbeddingFraction ?? 0) >= 0.95
            && (dominantIntervalFraction ?? 0) >= 0.98
        return ClusteringDiagnostics(
            heuristicVersion: "dominant-occupancy-v1",
            embeddingCount: totalEmbeddings,
            intervalCount: intervals.count,
            overlapIntervalCount: intervals.filter(\.overlapsAnotherSpeaker).count,
            occupancies: occupancies,
            dominantEmbeddingFraction: dominantEmbeddingFraction,
            dominantIntervalFraction: dominantIntervalFraction,
            separationAppearsCollapsed: appearsCollapsed
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
