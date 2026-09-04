import Foundation
import Testing

@testable import Speakers

private let matchModel = SpeakerEmbeddingModelIdentity(modelID: "wespeaker", revision: "1")
private let otherMatchModel = SpeakerEmbeddingModelIdentity(modelID: "wespeaker", revision: "2")
private let matchFormat = SpeakerEmbeddingFormat(model: matchModel, preprocessingVersion: "prep", normalizationVersion: "norm", transformVersion: "transform")

private func matchingSignature(_ vector: [Float], format: SpeakerEmbeddingFormat = matchFormat) -> SpeakerSignature {
    SpeakerSignature(
        signatureID: UUID(), embeddingVector: vector, embeddingModel: format.model,
        preprocessingVersion: format.preprocessingVersion, normalizationVersion: format.normalizationVersion,
        transformVersion: format.transformVersion, usableSpeechDuration: 20,
        qualityIndicators: SpeakerSignatureQuality(), enrollmentSourceID: "enrollment",
        selectedTimeRanges: [], retainedClipURL: nil, confirmedAt: .now, compatibility: .compatible
    )
}

private func matchingProfile(_ name: String, signatures: [SpeakerSignature], enabled: Bool = true) -> SpeakerProfile {
    SpeakerProfile(profileID: UUID(), displayName: name, automaticMatchingEnabled: enabled, signatures: signatures, createdAt: .now, updatedAt: .now)
}

private func matcherSnapshot(_ profiles: [SpeakerProfile]) -> SpeakerLibrarySnapshot {
    SpeakerLibrarySnapshot(revision: SpeakerLibraryRevision(sequence: 42), profiles: profiles)
}

private func excerpts(_ vectors: [[Float]], format: SpeakerEmbeddingFormat = matchFormat, clean: Bool = true) -> [SpeakerEmbeddingExcerpt] {
    vectors.enumerated().map { index, vector in
        SpeakerEmbeddingExcerpt(excerptID: "excerpt-\(index)", vector: vector, format: format, isClean: clean)
    }
}

private func testMatcher(automatic: Float = 0.85, suggested: Float = 0.70, margin: Float = 0.05, excerpts: Int = 2) -> SpeakerIdentityMatcher {
    SpeakerIdentityMatcher(configuration: .init(automaticThreshold: automatic, suggestionThreshold: suggested, minimumMargin: margin, minimumConsistentExcerpts: excerpts, matcherVersion: "test-matcher/1"))
}

@Test
func matcherReturnsMatchedWhenThresholdMarginAndCleanExcerptConsistencyPass() {
    let alex = matchingProfile("Alex", signatures: [matchingSignature([1, 0]), matchingSignature([0.98, 0.02])])
    let sam = matchingProfile("Sam", signatures: [matchingSignature([0, 1])])
    let assignment = testMatcher().match(
        RecordingLocalSpeaker(speakerID: "speaker-1", excerpts: excerpts([[1, 0], [0.99, 0.01]])),
        against: matcherSnapshot([alex, sam])
    )

    #expect(assignment.outcome == .matched)
    #expect(assignment.assignmentMethod == .automatic)
    #expect(assignment.person == alex.personRef)
    #expect(assignment.evidence.libraryRevision == SpeakerLibraryRevision(sequence: 42))
    #expect(assignment.evidence.matcherVersion == "test-matcher/1")
    #expect(assignment.evidence.candidates.count == 2)
    #expect(assignment.evidence.candidates[0].supportingExcerptCount == 2)
}

@Test
func matcherReturnsSuggestedForPromisingButInsufficientlyConsistentEvidence() {
    let alex = matchingProfile("Alex", signatures: [matchingSignature([1, 0])])
    let assignment = testMatcher().match(
        RecordingLocalSpeaker(speakerID: "speaker-1", excerpts: excerpts([[1, 0]])),
        against: matcherSnapshot([alex])
    )

    #expect(assignment.outcome == .suggested)
    #expect(assignment.assignmentMethod == .suggestedForReview)
    #expect(assignment.person == alex.personRef)
    #expect(assignment.evidence.cleanExcerptCount == 1)
}

@Test
func matcherReturnsUnmatchedBelowAbsoluteThresholdEvenForOnlyProfile() {
    let alex = matchingProfile("Alex", signatures: [matchingSignature([1, 0])])
    let assignment = testMatcher().match(
        RecordingLocalSpeaker(speakerID: "speaker-1", excerpts: excerpts([[0.2, 0.98], [0.1, 0.99]])),
        against: matcherSnapshot([alex])
    )

    #expect(assignment.outcome == .unmatched)
    #expect(assignment.assignmentMethod == .unmatched)
    #expect(assignment.person == nil)
}

@Test
func matcherSuggestsInsteadOfForcingAnAmbiguousCloseCandidate() {
    let alex = matchingProfile("Alex", signatures: [matchingSignature([1, 0])])
    let sam = matchingProfile("Sam", signatures: [matchingSignature([0.99, 0.1])])
    let assignment = testMatcher(margin: 0.10).match(
        RecordingLocalSpeaker(speakerID: "speaker-1", excerpts: excerpts([[1, 0], [1, 0]])),
        against: matcherSnapshot([alex, sam])
    )

    #expect(assignment.outcome == .suggested)
    #expect(assignment.person == alex.personRef)
}

@Test
func matcherExcludesIncompatibleAndUncleanVectors() {
    let alex = matchingProfile("Alex", signatures: [matchingSignature([1, 0])])
    let incompatibleFormat = SpeakerEmbeddingFormat(model: otherMatchModel, preprocessingVersion: "prep", normalizationVersion: "norm", transformVersion: "transform")
    let assignment = testMatcher().match(
        RecordingLocalSpeaker(speakerID: "speaker-1", excerpts: [
            SpeakerEmbeddingExcerpt(vector: [1, 0], format: incompatibleFormat),
            SpeakerEmbeddingExcerpt(vector: [1, 0], format: matchFormat, isClean: false),
        ]),
        against: matcherSnapshot([alex])
    )

    #expect(assignment.outcome == .unmatched)
    #expect(assignment.evidence.cleanExcerptCount == 1)
    #expect(assignment.evidence.candidates.isEmpty)
}

@Test
func matcherDoesNotEnforceOneToOneMappingOrMergeClusters() {
    let alex = matchingProfile("Alex", signatures: [matchingSignature([1, 0])])
    let matcher = testMatcher()
    let library = matcherSnapshot([alex])

    let first = matcher.match(RecordingLocalSpeaker(speakerID: "speaker-1", excerpts: excerpts([[1, 0], [1, 0]])), against: library)
    let second = matcher.match(RecordingLocalSpeaker(speakerID: "speaker-2", excerpts: excerpts([[1, 0], [1, 0]])), against: library)

    #expect(first.outcome == .matched)
    #expect(second.outcome == .matched)
    #expect(first.person == second.person)
    #expect(first.recordingSpeakerID != second.recordingSpeakerID)
}

@Test
func calibrationHarnessReportsThresholdSweepsAndDoesNotAbstainOnEverything() throws {
    let alex = UUID()
    let sam = UUID()
    let enrollment = [
        LabeledSpeakerEmbedding(sessionID: "enroll-a", profileID: alex, vector: [1, 0], format: matchFormat),
        LabeledSpeakerEmbedding(sessionID: "enroll-b", profileID: sam, vector: [0, 1], format: matchFormat),
    ]
    let evaluation = [
        LabeledSpeakerEmbedding(sessionID: "held-out-1", profileID: alex, vector: [0.9, 0.43589], format: matchFormat),
        LabeledSpeakerEmbedding(sessionID: "held-out-2", profileID: sam, vector: [0.43589, 0.9], format: matchFormat),
        LabeledSpeakerEmbedding(sessionID: "held-out-3", profileID: nil, vector: [-1, 0], format: matchFormat),
    ]
    let report = try SpeakerIdentityCalibrationHarness(matcherVersion: "calibration-test/1").run(
        enrollment: enrollment,
        evaluation: evaluation,
        thresholds: [
            SpeakerCalibrationThreshold(automaticThreshold: 0.80, suggestionThreshold: 0.70, minimumMargin: 0.05, minimumConsistentExcerpts: 1),
            SpeakerCalibrationThreshold(automaticThreshold: 0.99, suggestionThreshold: 0.70, minimumMargin: 0.05, minimumConsistentExcerpts: 1),
        ]
    )

    #expect(report.enrollmentSampleCount == 2)
    #expect(report.evaluationSampleCount == 3)
    #expect(report.enrollmentSessionIDs.isDisjoint(with: report.evaluationSessionIDs))
    #expect(report.sweeps.count == 2)
    #expect(report.sweeps[0].precision == 1)
    #expect(report.sweeps[0].coverage == 1)
    #expect(report.sweeps[0].unknownSpeakerFalseAcceptCount == 0)
    #expect(report.sweeps[0].automaticAssignmentCount == 2)
    // A threshold sweep can reveal the release-gate failure mode where a
    // matcher avoids mistakes only by abstaining on every known speaker.
    #expect(report.sweeps[1].automaticAssignmentCount == 0)
    #expect(report.sweeps[1].precision == nil)
    #expect(report.sweeps[1].coverage == 0)
}

@Test
func calibrationHarnessRejectsSameSessionEvaluation() {
    let profile = UUID()
    #expect(throws: SpeakerCalibrationError.sessionsAreNotDisjoint(["same-session"])) {
        try SpeakerIdentityCalibrationHarness().run(
            enrollment: [LabeledSpeakerEmbedding(sessionID: "same-session", profileID: profile, vector: [1, 0], format: matchFormat)],
            evaluation: [LabeledSpeakerEmbedding(sessionID: "same-session", profileID: profile, vector: [1, 0], format: matchFormat)],
            thresholds: [SpeakerCalibrationThreshold(automaticThreshold: 0.8, suggestionThreshold: 0.7, minimumMargin: 0.05, minimumConsistentExcerpts: 1)]
        )
    }
}
