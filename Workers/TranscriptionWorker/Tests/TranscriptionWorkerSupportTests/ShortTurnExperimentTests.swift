@testable import FluidAudio
import Foundation
import Testing
@testable import TranscriptionWorkerSupport

@Test("output-floor configuration leaves preparation and clustering unchanged")
func shortTurnConfigurationIsolation() throws {
    var original = OfflineDiarizerConfig.default
    original.postProcessing.exclusiveSegments = false
    for floor in [0.0, 0.25, 0.5, 0.75, 1.0] {
        let candidate = try OfflineDiarizationAdapter.shortTurnReconstructionConfiguration(original, outputFloor: floor)
        #expect(original.embedding.minSegmentDurationSeconds == 1)
        #expect(candidate.embedding.minSegmentDurationSeconds == floor)
        #expect(candidate.clustering.threshold == original.clustering.threshold)
        #expect(candidate.postProcessing.minGapDurationSeconds == 0.1)
        #expect(candidate.segmentation.minDurationOn == 0)
        #expect(!candidate.postProcessing.exclusiveSegments)
        #expect(!candidate.zeroVoteReembed.enabled)
    }
}

@Test("reject invalid floors and configurations that invalidate output-only isolation")
func shortTurnIsolationGuards() throws {
    var config = OfflineDiarizerConfig.default
    config.postProcessing.exclusiveSegments = false
    for floor in [-1.0, .infinity, .nan] {
        #expect(throws: OfflineDiarizationAdapter.Error.self) {
            try OfflineDiarizationAdapter.shortTurnReconstructionConfiguration(config, outputFloor: floor)
        }
    }
    config.zeroVoteReembed.enabled = true
    #expect(throws: OfflineDiarizationAdapter.Error.self) {
        try OfflineDiarizationAdapter.shortTurnReconstructionConfiguration(config, outputFloor: 0.5)
    }
    config.zeroVoteReembed.enabled = false
    config.postProcessing.exclusiveSegments = true
    #expect(throws: OfflineDiarizationAdapter.Error.self) {
        try OfflineDiarizationAdapter.shortTurnReconstructionConfiguration(config, outputFloor: 0.5)
    }
    config.postProcessing.exclusiveSegments = false
    config.segmentation.minDurationOn = 0.2
    #expect(throws: OfflineDiarizationAdapter.Error.self) {
        try OfflineDiarizationAdapter.shortTurnReconstructionConfiguration(config, outputFloor: 0.5)
    }
}

@Test("pinned reconstruction retains short overlap at independent output floors")
func shortTurnPinnedReconstruction() throws {
    var preparation = OfflineDiarizerConfig.default
    preparation.postProcessing.exclusiveSegments = false
    // Speaker 0 lasts 1.2 s; speaker 1 overlaps for exactly 0.5 s.
    // A later isolated 0.4 s response checks the floor independently of overlap.
    let weights: [[Float]] = (0..<20).map { frame in
        [frame < 12 ? 1 : 0, (5..<10).contains(frame) || (16..<20).contains(frame) ? 1 : 0]
    }
    let segmentation = SegmentationOutput(logProbs: [], speakerWeights: [weights],
        numChunks: 1, numFrames: 20, numSpeakers: 2, chunkOffsets: [0], frameDuration: 0.1)
    func reconstruct(_ floor: Double) throws -> [TimedSpeakerSegment] {
        let config = try OfflineDiarizationAdapter.shortTurnReconstructionConfiguration(preparation, outputFloor: floor)
        return OfflineReconstruction(config: config).buildSegments(
            segmentation: segmentation, hardClusters: [[0, 1]], centroids: [[1, 0], [0, 1]])
    }
    let baseline = try reconstruct(1)
    let half = try reconstruct(0.5)
    let quarter = try reconstruct(0.25)
    #expect(baseline.count == 1)
    #expect(half.count == 2)
    #expect(quarter.count == 3)
    #expect(half[1].speakerId == "S2")
    #expect(half[1].startTimeSeconds == 0.5)
    #expect(half[1].endTimeSeconds == 1)
    #expect(half[0].endTimeSeconds == baseline[0].endTimeSeconds)
    #expect(half[1].embedding == [0, 1])
    #expect(preparation.embedding.minSegmentDurationSeconds == 1)
}

@Test("latest recording's recovered overlapping subsecond intervals survive adapter export")
func shortTurnRealOverlapGeometry() throws {
    let manifest = try ModelManifest.load(from: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "model_manifest.json"))
    let adapter = OfflineDiarizationAdapter(manifest: manifest,
        modelsDirectory: URL(fileURLWithPath: "/unused"))
    // Observed latest-run geometry; synthetic vectors, no private words or audio.
    let raw = DiarizationResult(segments: [
        TimedSpeakerSegment(speakerId: "S1", embedding: [1, 0],
            startTimeSeconds: 43.00509262084961, endTimeSeconds: 43.65025329589844, qualityScore: 1),
        TimedSpeakerSegment(speakerId: "S2", embedding: [0, 1],
            startTimeSeconds: 43.07300567626953, endTimeSeconds: 43.667232513427734, qualityScore: 1),
    ], speakerDatabase: ["S1": [1, 0], "S2": [0, 1]])
    let result = try adapter.makeResult(raw, sourceDuration: 100)
    #expect(result.intervals.count == 2)
    #expect(result.intervals.allSatisfy { $0.overlapsAnotherSpeaker })
    #expect(result.intervals.map(\.speakerID) == ["speaker_1", "speaker_2"])
    #expect(result.intervals[0].startSeconds == Double(raw.segments[0].startTimeSeconds))
    #expect(result.intervals[1].endSeconds == Double(raw.segments[1].endTimeSeconds))
    #expect(result.configuration.minimumEmbeddingDurationSeconds == 1)
}
