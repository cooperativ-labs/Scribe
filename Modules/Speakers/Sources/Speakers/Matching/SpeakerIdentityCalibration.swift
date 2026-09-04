import Foundation

/// A labeled embedding from a known enrollment or held-out evaluation session.
/// `profileID == nil` represents a speaker deliberately absent from the library.
public struct LabeledSpeakerEmbedding: Sendable, Equatable, Identifiable {
    public let sampleID: String
    public let sessionID: String
    /// Groups several clean excerpts of one recording-local speaker. Defaults
    /// to `sampleID` so a lone embedding is still one evaluation cluster.
    public let clusterID: String
    public let profileID: UUID?
    public let vector: [Float]
    public let format: SpeakerEmbeddingFormat
    public let isClean: Bool

    public var id: String { sampleID }

    public init(
        sampleID: String = UUID().uuidString,
        sessionID: String,
        clusterID: String? = nil,
        profileID: UUID?,
        vector: [Float],
        format: SpeakerEmbeddingFormat,
        isClean: Bool = true
    ) {
        self.sampleID = sampleID
        self.sessionID = sessionID
        self.clusterID = clusterID ?? sampleID
        self.profileID = profileID
        self.vector = vector
        self.format = format
        self.isClean = isClean
    }
}

public struct SpeakerCalibrationThreshold: Sendable, Equatable, Hashable {
    public let automaticThreshold: Float
    public let suggestionThreshold: Float
    public let minimumMargin: Float
    public let minimumConsistentExcerpts: Int

    public init(automaticThreshold: Float, suggestionThreshold: Float, minimumMargin: Float, minimumConsistentExcerpts: Int) {
        self.automaticThreshold = automaticThreshold
        self.suggestionThreshold = suggestionThreshold
        self.minimumMargin = minimumMargin
        self.minimumConsistentExcerpts = minimumConsistentExcerpts
    }
}

public struct SpeakerCalibrationSweepResult: Sendable, Equatable {
    public let threshold: SpeakerCalibrationThreshold
    public let totalSampleCount: Int
    public let knownSpeakerSampleCount: Int
    public let unknownSpeakerSampleCount: Int
    public let automaticAssignmentCount: Int
    public let correctAutomaticAssignmentCount: Int
    public let unknownSpeakerFalseAcceptCount: Int
    /// Correct automatic names / all automatic names. Nil when nothing was named.
    public let precision: Double?
    /// Correct automatic names / known-speaker samples.
    public let coverage: Double
    /// Unknown automatic names / unknown-speaker samples.
    public let unknownSpeakerFalseAcceptRate: Double
}

public struct SpeakerCalibrationReport: Sendable, Equatable {
    public let enrollmentSampleCount: Int
    public let evaluationSampleCount: Int
    public let evaluationClusterCount: Int
    public let enrollmentSessionIDs: Set<String>
    public let evaluationSessionIDs: Set<String>
    public let sweeps: [SpeakerCalibrationSweepResult]
}

/// Chosen matcher thresholds after a sweep. `meetsWrongNameTarget` is true
/// when automatic-name precision is at least `1 - maximumWrongNameRate`.
public struct SpeakerCalibrationOperatingPoint: Sendable, Equatable {
    public let threshold: SpeakerCalibrationThreshold
    public let sweep: SpeakerCalibrationSweepResult
    public let wrongNameRate: Double?
    public let meetsWrongNameTarget: Bool
    public let maximumWrongNameRate: Double
}

public enum SpeakerCalibrationError: Error, Sendable, Equatable {
    case enrollmentSampleWithoutProfile(String)
    case sessionsAreNotDisjoint(Set<String>)
}

/// Deterministic calibration harness. It creates its library only from labeled
/// enrollment sessions and evaluates held-out sessions, making accidental
/// same-session measurement invalid rather than silently optimistic.
public struct SpeakerIdentityCalibrationHarness: Sendable {
    public let matcherVersion: String

    public init(matcherVersion: String = "speaker-identity-matcher/1") {
        self.matcherVersion = matcherVersion
    }

    public func run(
        enrollment: [LabeledSpeakerEmbedding],
        evaluation: [LabeledSpeakerEmbedding],
        thresholds: [SpeakerCalibrationThreshold]
    ) throws -> SpeakerCalibrationReport {
        for sample in enrollment where sample.profileID == nil {
            throw SpeakerCalibrationError.enrollmentSampleWithoutProfile(sample.sampleID)
        }
        let enrollmentSessions = Set(enrollment.map(\.sessionID))
        let evaluationSessions = Set(evaluation.map(\.sessionID))
        let overlap = enrollmentSessions.intersection(evaluationSessions)
        guard overlap.isEmpty else { throw SpeakerCalibrationError.sessionsAreNotDisjoint(overlap) }

        let library = makeLibrary(from: enrollment)
        let clusters = Dictionary(grouping: evaluation, by: \.clusterID)
        let knownClusters = clusters.values.filter { $0.contains { $0.profileID != nil } }.count
        let unknownClusters = clusters.count - knownClusters
        let results = thresholds.map { threshold in
            let matcher = SpeakerIdentityMatcher(configuration: .init(
                automaticThreshold: threshold.automaticThreshold,
                suggestionThreshold: threshold.suggestionThreshold,
                minimumMargin: threshold.minimumMargin,
                minimumConsistentExcerpts: threshold.minimumConsistentExcerpts,
                matcherVersion: matcherVersion
            ))
            var automatic = 0
            var correct = 0
            var falseAccepts = 0
            for (clusterID, samples) in clusters {
                let local = RecordingLocalSpeaker(
                    speakerID: clusterID,
                    excerpts: samples.map { sample in
                        SpeakerEmbeddingExcerpt(
                            excerptID: sample.sampleID,
                            vector: sample.vector,
                            format: sample.format,
                            isClean: sample.isClean
                        )
                    }
                )
                let assignment = matcher.match(local, against: library)
                guard assignment.outcome == .matched else { continue }
                automatic += 1
                let expectedID = samples.first(where: { $0.profileID != nil })?.profileID
                if assignment.person?.profileID == expectedID, expectedID != nil {
                    correct += 1
                }
                if samples.allSatisfy({ $0.profileID == nil }) { falseAccepts += 1 }
            }
            return SpeakerCalibrationSweepResult(
                threshold: threshold,
                totalSampleCount: evaluation.count,
                knownSpeakerSampleCount: knownClusters,
                unknownSpeakerSampleCount: unknownClusters,
                automaticAssignmentCount: automatic,
                correctAutomaticAssignmentCount: correct,
                unknownSpeakerFalseAcceptCount: falseAccepts,
                precision: automatic == 0 ? nil : Double(correct) / Double(automatic),
                coverage: knownClusters == 0 ? 0 : Double(correct) / Double(knownClusters),
                unknownSpeakerFalseAcceptRate: unknownClusters == 0 ? 0 : Double(falseAccepts) / Double(unknownClusters)
            )
        }
        return SpeakerCalibrationReport(
            enrollmentSampleCount: enrollment.count,
            evaluationSampleCount: evaluation.count,
            evaluationClusterCount: clusters.count,
            enrollmentSessionIDs: enrollmentSessions,
            evaluationSessionIDs: evaluationSessions,
            sweeps: results
        )
    }

    /// Prefers the highest-coverage sweep that stays inside the wrong-name
    /// budget and still names someone. Returns the highest-precision named
    /// sweep when the budget cannot be met, so a shortfall is visible.
    public func chooseOperatingPoint(
        from report: SpeakerCalibrationReport,
        maximumWrongNameRate: Double = 0.01
    ) -> SpeakerCalibrationOperatingPoint? {
        func operatingPoint(_ sweep: SpeakerCalibrationSweepResult, meets: Bool) -> SpeakerCalibrationOperatingPoint {
            SpeakerCalibrationOperatingPoint(
                threshold: sweep.threshold,
                sweep: sweep,
                wrongNameRate: sweep.precision.map { 1 - $0 },
                meetsWrongNameTarget: meets,
                maximumWrongNameRate: maximumWrongNameRate
            )
        }
        let named = report.sweeps.filter { $0.automaticAssignmentCount > 0 }
        let meeting = named.filter { sweep in
            guard let precision = sweep.precision else { return false }
            return (1 - precision) <= maximumWrongNameRate + 1e-12
        }
        if let best = meeting.max(by: { lhs, rhs in
            if lhs.coverage != rhs.coverage { return lhs.coverage < rhs.coverage }
            if lhs.threshold.automaticThreshold != rhs.threshold.automaticThreshold {
                return lhs.threshold.automaticThreshold < rhs.threshold.automaticThreshold
            }
            if lhs.threshold.minimumConsistentExcerpts != rhs.threshold.minimumConsistentExcerpts {
                return lhs.threshold.minimumConsistentExcerpts < rhs.threshold.minimumConsistentExcerpts
            }
            return lhs.threshold.minimumMargin < rhs.threshold.minimumMargin
        }) {
            return operatingPoint(best, meets: true)
        }
        if let fallback = named.max(by: { lhs, rhs in
            let lp = lhs.precision ?? -1
            let rp = rhs.precision ?? -1
            if lp != rp { return lp < rp }
            return lhs.coverage < rhs.coverage
        }) {
            return operatingPoint(fallback, meets: false)
        }
        return nil
    }

    private func makeLibrary(from enrollment: [LabeledSpeakerEmbedding]) -> SpeakerLibrarySnapshot {
        let grouped = Dictionary(grouping: enrollment, by: { $0.profileID! })
        let epoch = Date(timeIntervalSince1970: 0)
        let profiles = grouped.map { profileID, samples in
            SpeakerProfile(
                profileID: profileID,
                displayName: profileID.uuidString,
                automaticMatchingEnabled: true,
                signatures: samples.map { sample in
                    SpeakerSignature(
                        signatureID: UUID(), embeddingVector: sample.vector, embeddingModel: sample.format.model,
                        preprocessingVersion: sample.format.preprocessingVersion, normalizationVersion: sample.format.normalizationVersion,
                        transformVersion: sample.format.transformVersion, usableSpeechDuration: 1,
                        qualityIndicators: SpeakerSignatureQuality(), enrollmentSourceID: sample.sessionID,
                        selectedTimeRanges: [], retainedClipURL: nil, confirmedAt: epoch, compatibility: .compatible
                    )
                },
                createdAt: epoch, updatedAt: epoch
            )
        }
        return SpeakerLibrarySnapshot(revision: SpeakerLibraryRevision(sequence: 0), profiles: profiles)
    }
}
