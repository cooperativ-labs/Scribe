import Foundation
import Speakers

/// The review window's view of the speaker library.
///
/// Review needs three things from the library — who exists, adding a person,
/// and enrolling confirmed excerpts — so it depends on this narrow contract
/// instead of the SQLite store. Person IDs are the library's own
/// `SpeakerPersonRef`, so both modules name the same people.
public protocol TranscriptSpeakerDirectory: Sendable {
    func people() async throws -> [SpeakerPersonRef]
    /// Creates a name-only person. Never enrolls a voice: a profile without
    /// confirmed signatures is not eligible for automatic matching.
    func createPerson(named name: String) async throws -> SpeakerPersonRef
    func enroll(_ request: SpeakerEnrollmentRequest) async throws -> SpeakerEnrollmentResult
}

/// Binds the review window to the real speaker library and enrollment pipeline.
public struct SpeakerLibraryTranscriptDirectory: TranscriptSpeakerDirectory {
    private let store: SpeakerProfileStore
    private let pipeline: SpeakerEnrollmentPipeline
    private let extractor: any SpeakerEmbeddingExtracting

    public init(
        store: SpeakerProfileStore,
        extractor: any SpeakerEmbeddingExtracting,
        pipeline: SpeakerEnrollmentPipeline = SpeakerEnrollmentPipeline()
    ) {
        self.store = store
        self.extractor = extractor
        self.pipeline = pipeline
    }

    public func people() async throws -> [SpeakerPersonRef] {
        try await store.people()
    }

    public func createPerson(named name: String) async throws -> SpeakerPersonRef {
        try await store.createProfile(SpeakerProfileDraft(displayName: name)).personRef
    }

    public func enroll(_ request: SpeakerEnrollmentRequest) async throws -> SpeakerEnrollmentResult {
        try await pipeline.enroll(request: request, into: store, using: extractor)
    }
}

/// Similarity evidence for a recognized speaker, persisted alongside the run.
public struct TranscriptSpeakerSuggestion: Identifiable, Codable, Equatable, Sendable {
    public let speakerID: String
    public let person: SpeakerPersonRef
    public let score: Float
    public let matcherVersion: String
    /// Nil for older records whose suggestions were not applied.
    public let appliedAutomatically: Bool?

    public var id: String { speakerID }

    public init(speakerID: String, person: SpeakerPersonRef, score: Float, matcherVersion: String, appliedAutomatically: Bool? = nil) {
        self.speakerID = speakerID
        self.person = person
        self.score = score
        self.matcherVersion = matcherVersion
        self.appliedAutomatically = appliedAutomatically
    }

    /// Lifts a recognized matcher result into review state.
    public init?(_ assignment: Speakers.SpeakerIdentityAssignment) {
        guard assignment.outcome != .unmatched, let person = assignment.person else { return nil }
        self.init(
            speakerID: assignment.recordingSpeakerID,
            person: person,
            score: assignment.evidence.candidates.first?.score ?? 0,
            matcherVersion: assignment.evidence.matcherVersion,
            appliedAutomatically: true
        )
    }

    /// Similarity is evidence for review, not a probability of identity.
    public var scoreDescription: String {
        "similarity \(String(format: "%.2f", score))"
    }

    /// The similarity as a whole percentage, for the compact chip badge.
    public var percentDescription: String {
        "\(Int((min(max(score, 0), 1) * 100).rounded()))%"
    }

    /// Compact similarity indicator; the name is already on the chip.
    public var chipBadgeTitle: String {
        "Auto · \(percentDescription)"
    }
}
