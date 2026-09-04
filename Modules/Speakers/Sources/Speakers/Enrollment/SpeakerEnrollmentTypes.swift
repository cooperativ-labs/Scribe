import Foundation

public enum SpeakerEnrollmentOrigin: String, Sendable, Equatable, Codable {
    case transcriptSelection
    case selectedAudioFile
}

/// How the excerpts were approved. Only explicit user confirmation may write
/// signatures; automatic matches and unconfirmed suggestions must not train.
public enum SpeakerEnrollmentConfirmation: String, Sendable, Equatable, Codable {
    case userConfirmedExcerpts
    case unconfirmed
    case automaticMatch
}

public enum SpeakerEnrollmentTarget: Sendable, Equatable {
    case existingProfile(UUID)
    case newProfile(displayName: String)
}

/// A candidate excerpt from a transcript selection or a selected audio file.
/// Quality flags are supplied by the caller (review UI, diarizer overlap, or
/// waveform inspection); the selector never infers them from the audio bytes.
public struct SpeakerEnrollmentExcerpt: Sendable, Equatable, Identifiable {
    public let excerptID: String
    public let timeRanges: [SpeakerTimeRange]
    public let containsSilence: Bool
    public let containsOverlap: Bool
    public let containsClipping: Bool
    public let isConfirmed: Bool

    public var id: String { excerptID }

    public var duration: TimeInterval {
        timeRanges.reduce(0) { $0 + Double(max(0, $1.endMs - $1.startMs)) / 1000 }
    }

    public var isCleanIgnoringDuration: Bool {
        !containsSilence && !containsOverlap && !containsClipping && !timeRanges.isEmpty
    }

    public init(
        excerptID: String = UUID().uuidString,
        timeRanges: [SpeakerTimeRange],
        containsSilence: Bool = false,
        containsOverlap: Bool = false,
        containsClipping: Bool = false,
        isConfirmed: Bool
    ) {
        self.excerptID = excerptID
        self.timeRanges = timeRanges
        self.containsSilence = containsSilence
        self.containsOverlap = containsOverlap
        self.containsClipping = containsClipping
        self.isConfirmed = isConfirmed
    }
}

public struct SpeakerEnrollmentConfiguration: Sendable, Equatable {
    public let minimumUtteranceDuration: TimeInterval
    public let targetMinimumUsableSpeech: TimeInterval
    public let targetMaximumUsableSpeech: TimeInterval
    public let minimumExcerptCount: Int
    /// When set, extracted vectors must carry this exact compatibility tuple.
    public let expectedFormat: SpeakerEmbeddingFormat?

    public init(
        minimumUtteranceDuration: TimeInterval = 1,
        targetMinimumUsableSpeech: TimeInterval = 20,
        targetMaximumUsableSpeech: TimeInterval = 60,
        minimumExcerptCount: Int = 2,
        expectedFormat: SpeakerEmbeddingFormat? = SpeakerPinnedEmbeddingFormat.current
    ) {
        self.minimumUtteranceDuration = minimumUtteranceDuration
        self.targetMinimumUsableSpeech = targetMinimumUsableSpeech
        self.targetMaximumUsableSpeech = targetMaximumUsableSpeech
        self.minimumExcerptCount = minimumExcerptCount
        self.expectedFormat = expectedFormat
    }
}

public struct SpeakerEnrollmentRequest: Sendable, Equatable {
    public let origin: SpeakerEnrollmentOrigin
    public let confirmation: SpeakerEnrollmentConfirmation
    public let target: SpeakerEnrollmentTarget
    public let sourceID: String
    public let audioFileURL: URL
    public let excerpts: [SpeakerEnrollmentExcerpt]
    public let retainClips: Bool

    public init(
        origin: SpeakerEnrollmentOrigin,
        confirmation: SpeakerEnrollmentConfirmation,
        target: SpeakerEnrollmentTarget,
        sourceID: String,
        audioFileURL: URL,
        excerpts: [SpeakerEnrollmentExcerpt],
        retainClips: Bool = false
    ) {
        self.origin = origin
        self.confirmation = confirmation
        self.target = target
        self.sourceID = sourceID
        self.audioFileURL = audioFileURL
        self.excerpts = excerpts
        self.retainClips = retainClips
    }

    public static func transcriptSelection(
        sourceID: String,
        audioFileURL: URL,
        target: SpeakerEnrollmentTarget,
        excerpts: [SpeakerEnrollmentExcerpt],
        confirmation: SpeakerEnrollmentConfirmation,
        retainClips: Bool = false
    ) -> SpeakerEnrollmentRequest {
        SpeakerEnrollmentRequest(
            origin: .transcriptSelection,
            confirmation: confirmation,
            target: target,
            sourceID: sourceID,
            audioFileURL: audioFileURL,
            excerpts: excerpts,
            retainClips: retainClips
        )
    }

    public static func selectedAudioFile(
        sourceID: String,
        audioFileURL: URL,
        target: SpeakerEnrollmentTarget,
        excerpts: [SpeakerEnrollmentExcerpt],
        confirmation: SpeakerEnrollmentConfirmation,
        retainClips: Bool = false
    ) -> SpeakerEnrollmentRequest {
        SpeakerEnrollmentRequest(
            origin: .selectedAudioFile,
            confirmation: confirmation,
            target: target,
            sourceID: sourceID,
            audioFileURL: audioFileURL,
            excerpts: excerpts,
            retainClips: retainClips
        )
    }
}

public struct SpeakerEnrollmentResult: Sendable, Equatable {
    public let origin: SpeakerEnrollmentOrigin
    public let profile: SpeakerProfile
    public let selectedExcerpts: [SpeakerEnrollmentExcerpt]
    public let usableSpeechDuration: TimeInterval
    public let libraryRevision: SpeakerLibraryRevision

    public init(
        origin: SpeakerEnrollmentOrigin,
        profile: SpeakerProfile,
        selectedExcerpts: [SpeakerEnrollmentExcerpt],
        usableSpeechDuration: TimeInterval,
        libraryRevision: SpeakerLibraryRevision
    ) {
        self.origin = origin
        self.profile = profile
        self.selectedExcerpts = selectedExcerpts
        self.usableSpeechDuration = usableSpeechDuration
        self.libraryRevision = libraryRevision
    }
}

public enum SpeakerEnrollmentError: Error, Sendable, Equatable, LocalizedError {
    case unconfirmedExamples
    case automaticMatchCannotUpdateSignatures
    case noCleanExcerpts
    case insufficientExcerpts(selected: Int, required: Int)
    case insufficientUsableSpeech(seconds: TimeInterval, required: TimeInterval)
    case incompatibleEmbeddingFormat(String)
    case extractorReturnedNoEmbedding(String)
    case extractorReturnedMultipleSpeakers(String)

    public var errorDescription: String? {
        switch self {
        case .unconfirmedExamples:
            "Enrollment requires the user to confirm clean excerpts; unconfirmed examples are ignored."
        case .automaticMatchCannotUpdateSignatures:
            "Automatic identity matches must not update enrolled signatures."
        case .noCleanExcerpts:
            "No confirmed excerpts remained after excluding silence, overlap, clipping, and very short utterances."
        case let .insufficientExcerpts(selected, required):
            "Enrollment needs several excerpts; selected \(selected), required \(required)."
        case let .insufficientUsableSpeech(seconds, required):
            "Usable speech is \(String(format: "%.1f", seconds))s; target at least \(String(format: "%.0f", required))s across several excerpts."
        case let .incompatibleEmbeddingFormat(reason):
            "Extractor returned an incompatible embedding format: \(reason)."
        case let .extractorReturnedNoEmbedding(excerptID):
            "The worker returned no embedding for excerpt \(excerptID)."
        case let .extractorReturnedMultipleSpeakers(excerptID):
            "Excerpt \(excerptID) is not a single-speaker example; refusing to enroll an inconsistent cluster."
        }
    }
}
