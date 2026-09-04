import Foundation

/// Stable person identity shared with other modules and transcript exports.
///
/// This is the only speaker representation that may appear on an export path.
/// It carries a profile ID and display name, and never embeddings or clips.
public struct SpeakerPersonRef: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let profileID: UUID
    public let displayName: String

    public var id: UUID { profileID }

    public init(profileID: UUID, displayName: String) {
        self.profileID = profileID
        self.displayName = displayName
    }
}

/// Monotonic library revision. Every store write produces a new value so a
/// matcher can pin a snapshot and detect later enrollment changes.
public struct SpeakerLibraryRevision: Codable, Sendable, Equatable, Hashable, Comparable {
    public let sequence: Int64

    public init(sequence: Int64) {
        self.sequence = sequence
    }

    /// String form used by `TranscriptionRequest.speakerLibraryRevision`.
    public var snapshotValue: String { String(sequence) }

    public static func < (lhs: SpeakerLibraryRevision, rhs: SpeakerLibraryRevision) -> Bool {
        lhs.sequence < rhs.sequence
    }
}

/// Pinned embedding-model identity. Signatures from a different model ID or
/// revision are marked incompatible and need reenrollment.
public struct SpeakerEmbeddingModelIdentity: Codable, Sendable, Equatable, Hashable {
    public var modelID: String
    public var revision: String

    public init(modelID: String, revision: String) {
        self.modelID = modelID
        self.revision = revision
    }
}

/// Profiles plus the revision they were read under. Matchers should copy this
/// rather than reading the live store while a job runs.
public struct SpeakerLibrarySnapshot: Sendable, Equatable {
    public let revision: SpeakerLibraryRevision
    public let profiles: [SpeakerProfile]

    public init(revision: SpeakerLibraryRevision, profiles: [SpeakerProfile]) {
        self.revision = revision
        self.profiles = profiles
    }

    public var people: [SpeakerPersonRef] {
        profiles.map(\.personRef)
    }

    public var matchingEligibleProfiles: [SpeakerProfile] {
        profiles.filter(\.isMatchingEligible)
    }
}
