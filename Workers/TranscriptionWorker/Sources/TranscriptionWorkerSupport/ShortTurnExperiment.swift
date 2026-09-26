import FluidAudio
import Foundation

/// Explicit benchmark surface. The production diarize(fileURL:) path is unchanged.
/// Audited against FluidAudio 21493f8: cluster(_:) does not use the embedding
/// duration outside reconstruction when zeroVoteReembed is disabled.
extension OfflineDiarizationAdapter {
    public struct ShortTurnVariant: Encodable, Sendable {
        public let id: String
        public let preparationEmbeddingFloorSeconds: Double
        public let outputFloorSeconds: Double
        public let result: Result
        /// Private acoustic provenance; never include these vectors in public reports.
        public let chunkEmbeddings: [ChunkEmbedding]
        public let rawClusterIDsByStableID: [String: String]
    }

    static func shortTurnReconstructionConfiguration(
        _ preparation: OfflineDiarizerConfig, outputFloor: Double
    ) throws -> OfflineDiarizerConfig {
        guard outputFloor.isFinite, outputFloor >= 0 else {
            throw Error.invalidConfiguration("Output floor must be finite and nonnegative")
        }
        guard !preparation.zeroVoteReembed.enabled,
              !preparation.postProcessing.exclusiveSegments,
              preparation.segmentation.minDurationOn == 0 else {
            throw Error.invalidConfiguration("Short-turn isolation requires no re-embedding, nonexclusive output and zero segmentation floor")
        }
        var reconstruction = preparation
        reconstruction.embedding.minSegmentDurationSeconds = outputFloor
        return reconstruction
    }

    /// Runs model inference once, then serial clustering/reconstruction for each floor.
    /// Call on separate adapters for embedding floors 1.0 and 0.5; do not reuse a
    /// prepared value across those two experiments.
    public func shortTurnVariants(fileURL: URL, outputFloors: [Double]) async throws -> [ShortTurnVariant] {
        let preparation = try makeDiarizerConfiguration()
        guard configuration.minimumEmbeddingDurationSeconds.isFinite,
              configuration.minimumEmbeddingDurationSeconds >= 0 else {
            throw Error.invalidConfiguration("Embedding floor must be finite and nonnegative")
        }
        // Validate before opening models/audio.
        for floor in outputFloors {
            _ = try Self.shortTurnReconstructionConfiguration(preparation, outputFloor: floor)
        }
        let source = try AudioSourceFactory().makeDiskBackedSource(
            from: fileURL, targetSampleRate: preparation.segmentation.sampleRate)
        defer { source.source.cleanup() }
        let models = try OfflineModelLoader.loadDiarization(
            manifest: manifest, modelsDirectory: modelsDirectory,
            computeUnits: configuration.computeUnits,
            allowLowPrecisionAccumulationOnGPU: configuration.allowLowPrecisionAccumulationOnGPU)
        let extractor = OfflineDiarizerManager(config: preparation)
        extractor.initialize(models: models)
        let prepared = try await extractor.prepare(
            audioSource: source.source, audioLoadingSeconds: source.loadDuration)
        let duration = Double(source.source.sampleCount) / Double(preparation.segmentation.sampleRate)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var clusterControl: Data?
        var variants: [ShortTurnVariant] = []
        for floor in outputFloors {
            let reconstruction = try Self.shortTurnReconstructionConfiguration(preparation, outputFloor: floor)
            let manager = OfflineDiarizerManager(config: reconstruction)
            manager.initialize(models: models)
            let raw = try manager.cluster(prepared)
            guard let chunks = raw.chunkEmbeddings, !chunks.isEmpty else { throw Error.noEmbeddings }
            let encoded = try encoder.encode(chunks)
            if let clusterControl, clusterControl != encoded {
                throw Error.invalidConfiguration("Output-floor experiment changed chunk embeddings or cluster assignments")
            }
            clusterControl = encoded
            let result = try makeResult(raw, sourceDuration: duration, diarizerConfiguration: preparation)
            // Match makeResult's chronological renaming, including database-only IDs.
            var rawIDs: [String] = []
            for segment in raw.segments.sorted(by: {
                $0.startTimeSeconds == $1.startTimeSeconds
                    ? $0.endTimeSeconds < $1.endTimeSeconds : $0.startTimeSeconds < $1.startTimeSeconds
            }) where min(Double(segment.endTimeSeconds), duration) > max(0, Double(segment.startTimeSeconds)) {
                if !rawIDs.contains(segment.speakerId) { rawIDs.append(segment.speakerId) }
            }
            for id in (raw.speakerDatabase ?? [:]).keys.sorted() where !rawIDs.contains(id) { rawIDs.append(id) }
            variants.append(ShortTurnVariant(
                id: "embedding-\(configuration.minimumEmbeddingDurationSeconds)-output-\(floor)",
                preparationEmbeddingFloorSeconds: configuration.minimumEmbeddingDurationSeconds,
                outputFloorSeconds: floor, result: result, chunkEmbeddings: chunks,
                rawClusterIDsByStableID: Dictionary(uniqueKeysWithValues: rawIDs.enumerated().map {
                    ("speaker_\($0.offset + 1)", $0.element)
                })))
        }
        return variants
    }
}
