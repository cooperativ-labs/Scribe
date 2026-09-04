import Foundation

/// Pinned representation of a recording-local embedding. Matching never
/// crosses model, preprocessing, normalization, or transform boundaries.
public struct SpeakerEmbeddingFormat: Sendable, Equatable, Hashable {
    public let model: SpeakerEmbeddingModelIdentity
    public let preprocessingVersion: String
    public let normalizationVersion: String
    public let transformVersion: String

    public init(
        model: SpeakerEmbeddingModelIdentity,
        preprocessingVersion: String,
        normalizationVersion: String,
        transformVersion: String
    ) {
        self.model = model
        self.preprocessingVersion = preprocessingVersion
        self.normalizationVersion = normalizationVersion
        self.transformVersion = transformVersion
    }

    init(signature: SpeakerSignature) {
        self.init(
            model: signature.embeddingModel,
            preprocessingVersion: signature.preprocessingVersion,
            normalizationVersion: signature.normalizationVersion,
            transformVersion: signature.transformVersion
        )
    }
}

public struct SpeakerEmbeddingExcerpt: Sendable, Equatable, Identifiable {
    public let excerptID: String
    public let vector: [Float]
    public let format: SpeakerEmbeddingFormat
    /// The diarizer/enrollment quality gate has already excluded overlap,
    /// clipping, silence, and too-short speech before this reaches matching.
    public let isClean: Bool

    public var id: String { excerptID }

    public init(excerptID: String = UUID().uuidString, vector: [Float], format: SpeakerEmbeddingFormat, isClean: Bool = true) {
        self.excerptID = excerptID
        self.vector = vector
        self.format = format
        self.isClean = isClean
    }
}

public struct RecordingLocalSpeaker: Sendable, Equatable, Identifiable {
    public let speakerID: String
    public let excerpts: [SpeakerEmbeddingExcerpt]

    public var id: String { speakerID }

    public init(speakerID: String, excerpts: [SpeakerEmbeddingExcerpt]) {
        self.speakerID = speakerID
        self.excerpts = excerpts
    }
}

public struct SpeakerIdentityMatcherConfiguration: Sendable, Equatable {
    public let automaticThreshold: Float
    public let suggestionThreshold: Float
    public let minimumMargin: Float
    public let minimumConsistentExcerpts: Int
    public let matcherVersion: String

    public init(
        automaticThreshold: Float = 0.85,
        suggestionThreshold: Float = 0.70,
        minimumMargin: Float = 0.05,
        minimumConsistentExcerpts: Int = 2,
        matcherVersion: String = "speaker-identity-matcher/1"
    ) {
        precondition((-1...1).contains(automaticThreshold))
        precondition((-1...1).contains(suggestionThreshold))
        precondition(automaticThreshold >= suggestionThreshold)
        precondition(minimumMargin >= 0)
        precondition(minimumConsistentExcerpts > 0)
        self.automaticThreshold = automaticThreshold
        self.suggestionThreshold = suggestionThreshold
        self.minimumMargin = minimumMargin
        self.minimumConsistentExcerpts = minimumConsistentExcerpts
        self.matcherVersion = matcherVersion
    }

    /// Strictest local-synthesis point that still named anyone (see
    /// `docs/feasibility/speaker-identity-calibration.md`). Not a consented-speech lock.
    public static let localSynthesisStandIn = SpeakerIdentityMatcherConfiguration(
        automaticThreshold: 0.80,
        suggestionThreshold: 0.65,
        minimumMargin: 0.08,
        minimumConsistentExcerpts: 1,
        matcherVersion: "speaker-identity-matcher/1"
    )
}

public enum SpeakerIdentityAssignmentMethod: String, Sendable, Equatable, Codable {
    case automatic
    case suggestedForReview
    case unmatched
}

public enum SpeakerIdentityMatchOutcome: String, Sendable, Equatable, Codable {
    case matched
    case suggested
    case unmatched
}

public struct SpeakerIdentityCandidateScore: Sendable, Equatable {
    public let profile: SpeakerPersonRef
    /// Mean of the best compatible signature similarity for each clean excerpt.
    public let score: Float
    public let supportingExcerptCount: Int

    public init(profile: SpeakerPersonRef, score: Float, supportingExcerptCount: Int) {
        self.profile = profile
        self.score = score
        self.supportingExcerptCount = supportingExcerptCount
    }
}

/// Evidence persisted beside a transcript assignment. Scores are similarities,
/// not probabilities, and profile vectors are deliberately absent.
public struct SpeakerIdentityScoreEvidence: Sendable, Equatable {
    public let candidates: [SpeakerIdentityCandidateScore]
    public let cleanExcerptCount: Int
    public let libraryRevision: SpeakerLibraryRevision
    public let matcherVersion: String
    public let automaticThreshold: Float
    public let suggestionThreshold: Float
    public let minimumMargin: Float
    public let minimumConsistentExcerpts: Int

    public init(
        candidates: [SpeakerIdentityCandidateScore],
        cleanExcerptCount: Int,
        libraryRevision: SpeakerLibraryRevision,
        matcherVersion: String,
        automaticThreshold: Float,
        suggestionThreshold: Float,
        minimumMargin: Float,
        minimumConsistentExcerpts: Int
    ) {
        self.candidates = candidates
        self.cleanExcerptCount = cleanExcerptCount
        self.libraryRevision = libraryRevision
        self.matcherVersion = matcherVersion
        self.automaticThreshold = automaticThreshold
        self.suggestionThreshold = suggestionThreshold
        self.minimumMargin = minimumMargin
        self.minimumConsistentExcerpts = minimumConsistentExcerpts
    }
}

public struct SpeakerIdentityAssignment: Sendable, Equatable {
    public let recordingSpeakerID: String
    public let outcome: SpeakerIdentityMatchOutcome
    public let assignmentMethod: SpeakerIdentityAssignmentMethod
    /// Non-nil for a match or suggestion. Suggestions must retain the generic
    /// transcript label until a person confirms them.
    public let person: SpeakerPersonRef?
    public let evidence: SpeakerIdentityScoreEvidence

    public init(
        recordingSpeakerID: String,
        outcome: SpeakerIdentityMatchOutcome,
        assignmentMethod: SpeakerIdentityAssignmentMethod,
        person: SpeakerPersonRef?,
        evidence: SpeakerIdentityScoreEvidence
    ) {
        self.recordingSpeakerID = recordingSpeakerID
        self.outcome = outcome
        self.assignmentMethod = assignmentMethod
        self.person = person
        self.evidence = evidence
    }
}

/// Stateless, unknown-aware matcher for one recording-local diarization
/// cluster. Calls are independent, deliberately allowing one enrolled person
/// to match more than one cluster and never merging clusters.
public struct SpeakerIdentityMatcher: Sendable {
    public let configuration: SpeakerIdentityMatcherConfiguration

    public init(configuration: SpeakerIdentityMatcherConfiguration = .init()) {
        self.configuration = configuration
    }

    public func match(
        _ localSpeaker: RecordingLocalSpeaker,
        against library: SpeakerLibrarySnapshot
    ) -> SpeakerIdentityAssignment {
        let cleanExcerpts = localSpeaker.excerpts.filter(\.isClean).filter { !$0.vector.isEmpty }
        let candidates = library.matchingEligibleProfiles.compactMap { profile -> SpeakerIdentityCandidateScore? in
            let scores = cleanExcerpts.compactMap { excerpt -> Float? in
                let compatible = profile.signatures.filter { $0.isCompatible && SpeakerEmbeddingFormat(signature: $0) == excerpt.format }
                let similarities = compatible.compactMap { cosineSimilarity(excerpt.vector, $0.embeddingVector) }
                return similarities.max()
            }
            guard !scores.isEmpty else { return nil }
            let score = scores.reduce(0, +) / Float(scores.count)
            // Consistency is measured per excerpt against the candidate's
            // absolute-quality gate, rather than merely counting available
            // vectors. This makes poor/noisy excerpts unable to force a name.
            let support = scores.filter { $0 >= configuration.automaticThreshold }.count
            return SpeakerIdentityCandidateScore(profile: profile.personRef, score: score, supportingExcerptCount: support)
        }.sorted { lhs, rhs in
            lhs.score == rhs.score ? lhs.profile.profileID.uuidString < rhs.profile.profileID.uuidString : lhs.score > rhs.score
        }

        let evidence = SpeakerIdentityScoreEvidence(
            candidates: candidates,
            cleanExcerptCount: cleanExcerpts.count,
            libraryRevision: library.revision,
            matcherVersion: configuration.matcherVersion,
            automaticThreshold: configuration.automaticThreshold,
            suggestionThreshold: configuration.suggestionThreshold,
            minimumMargin: configuration.minimumMargin,
            minimumConsistentExcerpts: configuration.minimumConsistentExcerpts
        )
        guard let best = candidates.first else {
            return SpeakerIdentityAssignment(recordingSpeakerID: localSpeaker.speakerID, outcome: .unmatched, assignmentMethod: .unmatched, person: nil, evidence: evidence)
        }

        let secondScore = candidates.dropFirst().first?.score ?? -1
        let hasMargin = best.score - secondScore >= configuration.minimumMargin
        let isAutomatic = best.score >= configuration.automaticThreshold
            && hasMargin
            && best.supportingExcerptCount >= configuration.minimumConsistentExcerpts

        if isAutomatic {
            return SpeakerIdentityAssignment(recordingSpeakerID: localSpeaker.speakerID, outcome: .matched, assignmentMethod: .automatic, person: best.profile, evidence: evidence)
        }
        if best.score >= configuration.suggestionThreshold {
            return SpeakerIdentityAssignment(recordingSpeakerID: localSpeaker.speakerID, outcome: .suggested, assignmentMethod: .suggestedForReview, person: best.profile, evidence: evidence)
        }
        return SpeakerIdentityAssignment(recordingSpeakerID: localSpeaker.speakerID, outcome: .unmatched, assignmentMethod: .unmatched, person: nil, evidence: evidence)
    }

    private func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float? {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return nil }
        var dot: Float = 0
        var lhsMagnitude: Float = 0
        var rhsMagnitude: Float = 0
        for (a, b) in zip(lhs, rhs) {
            dot += a * b
            lhsMagnitude += a * a
            rhsMagnitude += b * b
        }
        guard lhsMagnitude > 0, rhsMagnitude > 0 else { return nil }
        return dot / (lhsMagnitude.squareRoot() * rhsMagnitude.squareRoot())
    }
}
