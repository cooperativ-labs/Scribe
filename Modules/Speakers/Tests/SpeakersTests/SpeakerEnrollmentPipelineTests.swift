import Foundation
import Testing

@testable import Speakers

private struct Workspace: ~Copyable {
    let url: URL

    init(_ name: String) throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SpeakersEnrollment-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

private let enrollFormat = SpeakerEmbeddingFormat(
    model: SpeakerEmbeddingModelIdentity(modelID: "wespeaker-embedding-coreml", revision: "test"),
    preprocessingVersion: "prep",
    normalizationVersion: "norm",
    transformVersion: "identity-v1"
)

private struct StubExtractor: SpeakerEmbeddingExtracting {
    var vectors: [String: [Float]]
    var format: SpeakerEmbeddingFormat = enrollFormat
    var multipleFor: String?

    func extract(_ request: SpeakerEmbeddingExtractionRequest) async throws -> [ExtractedSpeakerEmbedding] {
        if request.excerptID == multipleFor {
            return [
                ExtractedSpeakerEmbedding(vector: [1, 0], format: format, usableSpeechDuration: 10),
                ExtractedSpeakerEmbedding(vector: [0, 1], format: format, usableSpeechDuration: 10),
            ]
        }
        guard let vector = vectors[request.excerptID] else { return [] }
        return [
            ExtractedSpeakerEmbedding(
                vector: vector,
                format: format,
                usableSpeechDuration: Double(request.ranges.reduce(0) { $0 + ($1.endMs - $1.startMs) }) / 1000
            )
        ]
    }
}

private func excerpt(
    _ id: String,
    startMs: Int,
    endMs: Int,
    confirmed: Bool = true,
    silence: Bool = false,
    overlap: Bool = false,
    clipping: Bool = false
) -> SpeakerEnrollmentExcerpt {
    SpeakerEnrollmentExcerpt(
        excerptID: id,
        timeRanges: [SpeakerTimeRange(startMs: startMs, endMs: endMs)],
        containsSilence: silence,
        containsOverlap: overlap,
        containsClipping: clipping,
        isConfirmed: confirmed
    )
}

private func pipeline() -> SpeakerEnrollmentPipeline {
    SpeakerEnrollmentPipeline(configuration: SpeakerEnrollmentConfiguration(expectedFormat: enrollFormat))
}

private func audioURL(_ workspace: borrowing Workspace) -> URL {
    workspace.url.appendingPathComponent("source.wav")
}

@Test
func transcriptSelectionEnrollsSeveralVerifiedSignatures() async throws {
    let workspace = try Workspace("transcript")
    try Data().write(to: audioURL(workspace))
    let store = try SpeakerProfileStore(directoryURL: workspace.url)
    let extractor = StubExtractor(vectors: ["a": [1, 0], "b": [0.98, 0.02], "c": [0.95, 0.05]])

    let result = try await pipeline().enroll(
        request: .transcriptSelection(
            sourceID: "transcript-1",
            audioFileURL: audioURL(workspace),
            target: .newProfile(displayName: "Jake"),
            excerpts: [
                excerpt("a", startMs: 0, endMs: 12_000),
                excerpt("b", startMs: 13_000, endMs: 25_000),
                excerpt("c", startMs: 26_000, endMs: 38_000),
            ],
            confirmation: .userConfirmedExcerpts
        ),
        into: store,
        using: extractor
    )

    #expect(result.profile.displayName == "Jake")
    #expect(result.profile.signatures.count == 3)
    #expect(result.origin == .transcriptSelection)
    #expect(result.selectedExcerpts.map(\.excerptID) == ["a", "b", "c"])
    #expect((20...60).contains(result.usableSpeechDuration))
    #expect(result.profile.signatures.allSatisfy { $0.enrollmentSourceID == "transcript-1" })
    #expect(result.profile.signatures.allSatisfy { $0.isCompatible })
    #expect(try await store.currentEmbeddingModel() == enrollFormat.model)
    #expect(result.libraryRevision.sequence >= 3)
}

@Test
func selectedAudioFileEnrollmentUsesTheSameQualityPath() async throws {
    let workspace = try Workspace("audio-file")
    try Data().write(to: audioURL(workspace))
    let store = try SpeakerProfileStore(directoryURL: workspace.url)
    let extractor = StubExtractor(vectors: ["one": [0, 1], "two": [0.02, 0.98]])

    let result = try await pipeline().enroll(
        request: .selectedAudioFile(
            sourceID: "file:interview.wav",
            audioFileURL: audioURL(workspace),
            target: .newProfile(displayName: "Sarah"),
            excerpts: [
                excerpt("one", startMs: 0, endMs: 20_000),
                excerpt("two", startMs: 21_000, endMs: 41_000),
            ],
            confirmation: .userConfirmedExcerpts
        ),
        into: store,
        using: extractor
    )

    #expect(result.origin == .selectedAudioFile)
    #expect(result.profile.signatures.count == 2)
    #expect(result.profile.signatures.map(\.enrollmentSourceID).allSatisfy { $0 == "file:interview.wav" })
}

@Test
func automaticMatchNeverWritesSignatures() async throws {
    let workspace = try Workspace("auto")
    try Data().write(to: audioURL(workspace))
    let store = try SpeakerProfileStore(directoryURL: workspace.url)
    let profile = try await store.createProfile(SpeakerProfileDraft(displayName: "Alex"))

    await #expect(throws: SpeakerEnrollmentError.automaticMatchCannotUpdateSignatures) {
        try await pipeline().enroll(
            request: .transcriptSelection(
                sourceID: "auto-1",
                audioFileURL: audioURL(workspace),
                target: .existingProfile(profile.profileID),
                excerpts: [
                    excerpt("a", startMs: 0, endMs: 20_000),
                    excerpt("b", startMs: 20_000, endMs: 40_000),
                ],
                confirmation: .automaticMatch
            ),
            into: store,
            using: StubExtractor(vectors: ["a": [1, 0], "b": [1, 0]])
        )
    }
    #expect(try await store.profile(id: profile.profileID)?.signatures.isEmpty == true)
}

@Test
func unconfirmedExamplesAreRejectedBeforeExtraction() async throws {
    let workspace = try Workspace("unconfirmed")
    try Data().write(to: audioURL(workspace))
    let store = try SpeakerProfileStore(directoryURL: workspace.url)

    await #expect(throws: SpeakerEnrollmentError.unconfirmedExamples) {
        try await pipeline().enroll(
            request: .transcriptSelection(
                sourceID: "t",
                audioFileURL: audioURL(workspace),
                target: .newProfile(displayName: "Riley"),
                excerpts: [
                    excerpt("a", startMs: 0, endMs: 20_000, confirmed: false),
                    excerpt("b", startMs: 20_000, endMs: 40_000, confirmed: false),
                ],
                confirmation: .unconfirmed
            ),
            into: store,
            using: StubExtractor(vectors: [:])
        )
    }
    #expect(try await store.profiles().isEmpty)
}

@Test
func selectorDropsSilenceOverlapClippingAndShortUtterances() async throws {
    let workspace = try Workspace("quality")
    try Data().write(to: audioURL(workspace))
    let store = try SpeakerProfileStore(directoryURL: workspace.url)
    let extractor = StubExtractor(vectors: ["keep-a": [1, 0], "keep-b": [0.9, 0.1]])

    let result = try await pipeline().enroll(
        request: .transcriptSelection(
            sourceID: "t",
            audioFileURL: audioURL(workspace),
            target: .newProfile(displayName: "Morgan"),
            excerpts: [
                excerpt("silence", startMs: 0, endMs: 20_000, silence: true),
                excerpt("overlap", startMs: 0, endMs: 20_000, overlap: true),
                excerpt("clip", startMs: 0, endMs: 20_000, clipping: true),
                excerpt("short", startMs: 0, endMs: 400),
                excerpt("keep-a", startMs: 0, endMs: 15_000),
                excerpt("keep-b", startMs: 16_000, endMs: 31_000),
            ],
            confirmation: .userConfirmedExcerpts
        ),
        into: store,
        using: extractor
    )

    #expect(result.selectedExcerpts.map(\.excerptID) == ["keep-a", "keep-b"])
    #expect(result.profile.signatures.count == 2)
}

@Test
func enrollmentFailsWhenConfirmedSpeechIsBelowTheCollectionTarget() async throws {
    let workspace = try Workspace("short-total")
    try Data().write(to: audioURL(workspace))
    let store = try SpeakerProfileStore(directoryURL: workspace.url)

    await #expect(throws: SpeakerEnrollmentError.self) {
        try await pipeline().enroll(
            request: .selectedAudioFile(
                sourceID: "short.wav",
                audioFileURL: audioURL(workspace),
                target: .newProfile(displayName: "Casey"),
                excerpts: [
                    excerpt("a", startMs: 0, endMs: 5_000),
                    excerpt("b", startMs: 5_000, endMs: 10_000),
                ],
                confirmation: .userConfirmedExcerpts
            ),
            into: store,
            using: StubExtractor(vectors: ["a": [1, 0], "b": [1, 0]])
        )
    }
}

@Test
func extractorReturningMultipleSpeakersIsRefused() async throws {
    let workspace = try Workspace("cluster")
    try Data().write(to: audioURL(workspace))
    let store = try SpeakerProfileStore(directoryURL: workspace.url)

    await #expect(throws: SpeakerEnrollmentError.extractorReturnedMultipleSpeakers("a")) {
        try await pipeline().enroll(
            request: .transcriptSelection(
                sourceID: "t",
                audioFileURL: audioURL(workspace),
                target: .newProfile(displayName: "Jordan"),
                excerpts: [
                    excerpt("a", startMs: 0, endMs: 20_000),
                    excerpt("b", startMs: 20_000, endMs: 40_000),
                ],
                confirmation: .userConfirmedExcerpts
            ),
            into: store,
            using: StubExtractor(vectors: ["a": [1, 0], "b": [1, 0]], multipleFor: "a")
        )
    }
    #expect(try await store.profiles().isEmpty)
}

@Test
func incompatibleExtractorFormatIsRejected() async throws {
    let workspace = try Workspace("format")
    try Data().write(to: audioURL(workspace))
    let store = try SpeakerProfileStore(directoryURL: workspace.url)
    let other = SpeakerEmbeddingFormat(
        model: SpeakerEmbeddingModelIdentity(modelID: "other", revision: "1"),
        preprocessingVersion: "prep",
        normalizationVersion: "norm",
        transformVersion: "identity-v1"
    )

    await #expect(throws: SpeakerEnrollmentError.self) {
        try await pipeline().enroll(
            request: .transcriptSelection(
                sourceID: "t",
                audioFileURL: audioURL(workspace),
                target: .newProfile(displayName: "Pat"),
                excerpts: [
                    excerpt("a", startMs: 0, endMs: 20_000),
                    excerpt("b", startMs: 20_000, endMs: 40_000),
                ],
                confirmation: .userConfirmedExcerpts
            ),
            into: store,
            using: StubExtractor(vectors: ["a": [1, 0], "b": [1, 0]], format: other)
        )
    }
}

@Test
func calibrationOperatingPointPrefersCoverageInsideTheWrongNameBudget() throws {
    let alex = UUID()
    let sam = UUID()
    let format = enrollFormat
    let enrollment = [
        LabeledSpeakerEmbedding(sessionID: "enroll-a", profileID: alex, vector: [1, 0], format: format),
        LabeledSpeakerEmbedding(sessionID: "enroll-b", profileID: sam, vector: [0, 1], format: format),
    ]
    let evaluation = [
        LabeledSpeakerEmbedding(sessionID: "held-out-1", clusterID: "alex", profileID: alex, vector: [0.99, 0.01], format: format),
        LabeledSpeakerEmbedding(sessionID: "held-out-1", clusterID: "alex", profileID: alex, vector: [0.98, 0.02], format: format),
        LabeledSpeakerEmbedding(sessionID: "held-out-2", clusterID: "sam", profileID: sam, vector: [0.02, 0.98], format: format),
        LabeledSpeakerEmbedding(sessionID: "held-out-2", clusterID: "sam", profileID: sam, vector: [0.01, 0.99], format: format),
        LabeledSpeakerEmbedding(sessionID: "held-out-3", clusterID: "unknown", profileID: nil, vector: [-1, 0], format: format),
        LabeledSpeakerEmbedding(sessionID: "held-out-3", clusterID: "unknown", profileID: nil, vector: [-0.99, 0.01], format: format),
    ]
    let harness = SpeakerIdentityCalibrationHarness(matcherVersion: "enrollment-cal/1")
    let report = try harness.run(
        enrollment: enrollment,
        evaluation: evaluation,
        thresholds: [
            SpeakerCalibrationThreshold(automaticThreshold: 0.50, suggestionThreshold: 0.40, minimumMargin: 0.05, minimumConsistentExcerpts: 2),
            SpeakerCalibrationThreshold(automaticThreshold: 0.80, suggestionThreshold: 0.60, minimumMargin: 0.05, minimumConsistentExcerpts: 2),
        ]
    )
    #expect(report.evaluationClusterCount == 3)
    let point = try #require(harness.chooseOperatingPoint(from: report, maximumWrongNameRate: 0.01))
    #expect(point.meetsWrongNameTarget)
    #expect(point.sweep.unknownSpeakerFalseAcceptCount == 0)
    #expect(point.sweep.coverage == 1)
    #expect(point.threshold.automaticThreshold == 0.80)
}
