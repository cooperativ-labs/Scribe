import Foundation

/// Local speaker profile. Embeddings and clip URLs are store-only and must not
/// be copied into transcript or subtitle exports; use `personRef` instead.
public struct SpeakerProfile: Sendable, Equatable, Identifiable {
    public let profileID: UUID
    public let displayName: String
    public let automaticMatchingEnabled: Bool
    public let signatures: [SpeakerSignature]
    public let createdAt: Date
    public let updatedAt: Date

    public var id: UUID { profileID }

    /// Export-safe identity. Other modules should persist this, not the profile.
    public var personRef: SpeakerPersonRef {
        SpeakerPersonRef(profileID: profileID, displayName: displayName)
    }

    /// Automatic matching requires the flag, at least one signature, and a
    /// compatible embedding-model version. Name-only profiles never qualify.
    public var isMatchingEligible: Bool {
        automaticMatchingEnabled && signatures.contains(where: \.isCompatible)
    }

    public init(
        profileID: UUID,
        displayName: String,
        automaticMatchingEnabled: Bool,
        signatures: [SpeakerSignature],
        createdAt: Date,
        updatedAt: Date
    ) {
        self.profileID = profileID
        self.displayName = displayName
        self.automaticMatchingEnabled = automaticMatchingEnabled
        self.signatures = signatures
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct SpeakerSignature: Sendable, Equatable, Identifiable {
    public let signatureID: UUID
    public let embeddingVector: [Float]
    public let embeddingModel: SpeakerEmbeddingModelIdentity
    public let preprocessingVersion: String
    public let normalizationVersion: String
    public let transformVersion: String
    public let usableSpeechDuration: TimeInterval
    public let qualityIndicators: SpeakerSignatureQuality
    public let enrollmentSourceID: String
    public let selectedTimeRanges: [SpeakerTimeRange]
    /// Local file under the speaker store. Never include this URL in exports.
    public let retainedClipURL: URL?
    public let confirmedAt: Date
    public let compatibility: SpeakerSignatureCompatibility

    public var id: UUID { signatureID }

    public var isCompatible: Bool { compatibility == .compatible }

    public init(
        signatureID: UUID,
        embeddingVector: [Float],
        embeddingModel: SpeakerEmbeddingModelIdentity,
        preprocessingVersion: String,
        normalizationVersion: String,
        transformVersion: String,
        usableSpeechDuration: TimeInterval,
        qualityIndicators: SpeakerSignatureQuality,
        enrollmentSourceID: String,
        selectedTimeRanges: [SpeakerTimeRange],
        retainedClipURL: URL?,
        confirmedAt: Date,
        compatibility: SpeakerSignatureCompatibility
    ) {
        self.signatureID = signatureID
        self.embeddingVector = embeddingVector
        self.embeddingModel = embeddingModel
        self.preprocessingVersion = preprocessingVersion
        self.normalizationVersion = normalizationVersion
        self.transformVersion = transformVersion
        self.usableSpeechDuration = usableSpeechDuration
        self.qualityIndicators = qualityIndicators
        self.enrollmentSourceID = enrollmentSourceID
        self.selectedTimeRanges = selectedTimeRanges
        self.retainedClipURL = retainedClipURL
        self.confirmedAt = confirmedAt
        self.compatibility = compatibility
    }
}

public enum SpeakerSignatureCompatibility: String, Sendable, Equatable, Hashable, Codable {
    case compatible
    case needsReenrollment
}

public struct SpeakerSignatureQuality: Codable, Sendable, Equatable, Hashable {
    public var silenceExcluded: Bool
    public var overlapExcluded: Bool
    public var clippingExcluded: Bool
    public var minimumUtteranceDurationMet: Bool

    public init(
        silenceExcluded: Bool = true,
        overlapExcluded: Bool = true,
        clippingExcluded: Bool = true,
        minimumUtteranceDurationMet: Bool = true
    ) {
        self.silenceExcluded = silenceExcluded
        self.overlapExcluded = overlapExcluded
        self.clippingExcluded = clippingExcluded
        self.minimumUtteranceDurationMet = minimumUtteranceDurationMet
    }
}

public struct SpeakerTimeRange: Codable, Sendable, Equatable, Hashable {
    public var startMs: Int
    public var endMs: Int

    public init(startMs: Int, endMs: Int) {
        self.startMs = startMs
        self.endMs = endMs
    }
}

public struct SpeakerProfileDraft: Sendable, Equatable {
    public var displayName: String
    public var automaticMatchingEnabled: Bool
    public var profileID: UUID

    public init(
        displayName: String,
        automaticMatchingEnabled: Bool = true,
        profileID: UUID = UUID()
    ) {
        self.displayName = displayName
        self.automaticMatchingEnabled = automaticMatchingEnabled
        self.profileID = profileID
    }
}

public struct SpeakerSignatureDraft: Sendable, Equatable {
    public var embeddingVector: [Float]
    public var embeddingModel: SpeakerEmbeddingModelIdentity
    public var preprocessingVersion: String
    public var normalizationVersion: String
    public var transformVersion: String
    public var usableSpeechDuration: TimeInterval
    public var qualityIndicators: SpeakerSignatureQuality
    public var enrollmentSourceID: String
    public var selectedTimeRanges: [SpeakerTimeRange]
    public var retainedClipURL: URL?
    public var confirmedAt: Date
    public var signatureID: UUID

    public init(
        embeddingVector: [Float],
        embeddingModel: SpeakerEmbeddingModelIdentity,
        preprocessingVersion: String,
        normalizationVersion: String,
        transformVersion: String,
        usableSpeechDuration: TimeInterval,
        qualityIndicators: SpeakerSignatureQuality = SpeakerSignatureQuality(),
        enrollmentSourceID: String,
        selectedTimeRanges: [SpeakerTimeRange],
        retainedClipURL: URL? = nil,
        confirmedAt: Date = Date(),
        signatureID: UUID = UUID()
    ) {
        self.embeddingVector = embeddingVector
        self.embeddingModel = embeddingModel
        self.preprocessingVersion = preprocessingVersion
        self.normalizationVersion = normalizationVersion
        self.transformVersion = transformVersion
        self.usableSpeechDuration = usableSpeechDuration
        self.qualityIndicators = qualityIndicators
        self.enrollmentSourceID = enrollmentSourceID
        self.selectedTimeRanges = selectedTimeRanges
        self.retainedClipURL = retainedClipURL
        self.confirmedAt = confirmedAt
        self.signatureID = signatureID
    }
}

public enum SpeakerProfileStoreError: Error, Sendable, Equatable {
    case applicationSupportUnavailable
    case profileNotFound(UUID)
    case profileAlreadyExists(UUID)
    case signatureNotFound(UUID)
    case invalidDisplayName
    case emptyEmbeddingVector
    case sqlite(String)
    case io(String)
}
