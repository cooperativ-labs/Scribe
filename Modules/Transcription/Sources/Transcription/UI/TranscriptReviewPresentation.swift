import Foundation
import Speakers

/// One recording-local speaker as the review window presents it.
public struct TranscriptSpeakerRow: Identifiable, Equatable, Sendable {
    public let speakerID: String
    public let label: String
    public let assignment: SpeakerIdentityAssignment
    public let profileID: String?
    public let segmentCount: Int
    public let suggestion: TranscriptSpeakerSuggestion?

    public var id: String { speakerID }

    public var statusDescription: String {
        if let suggestion {
            return "Suggested: \(suggestion.person.displayName) (\(suggestion.scoreDescription)) — confirm to apply"
        }
        return switch assignment {
        case .manual: "Assigned by you"
        case .automatic: "Matched from your speaker library"
        case .unmatched: "Not matched to a saved person"
        }
    }

    public init(
        speakerID: String,
        label: String,
        assignment: SpeakerIdentityAssignment,
        profileID: String?,
        segmentCount: Int,
        suggestion: TranscriptSpeakerSuggestion?
    ) {
        self.speakerID = speakerID
        self.label = label
        self.assignment = assignment
        self.profileID = profileID
        self.segmentCount = segmentCount
        self.suggestion = suggestion
    }
}

/// Result of an assignment, enrollment, or label-refresh action.
public struct TranscriptSpeakerActionMessage: Equatable, Sendable {
    public let text: String
    public let isFailure: Bool

    public init(text: String, isFailure: Bool) {
        self.text = text
        self.isFailure = isFailure
    }
}

/// Result of copying or saving a transcript export.
public struct TranscriptExportMessage: Equatable, Sendable {
    public let text: String
    public let isFailure: Bool

    public init(text: String, isFailure: Bool) {
        self.text = text
        self.isFailure = isFailure
    }
}

/// What the transport bar shows while the selected source is playing.
public struct TranscriptPlaybackStatus: Equatable, Sendable {
    /// The turn whose words are being spoken, or the last one that started
    /// when the play head is in a pause between turns.
    public let segment: TranscriptSegment
    public let isPlaying: Bool

    public init(segment: TranscriptSegment, isPlaying: Bool) {
        self.segment = segment
        self.isPlaying = isPlaying
    }

    public var speakerLabel: String { segment.speakerLabel }

    public var timestamp: String {
        "\(TranscriptTimecode.string(fromMilliseconds: segment.startMs)) – \(TranscriptTimecode.string(fromMilliseconds: segment.endMs))"
    }
}

/// How the transcript list is laid out. Canonical segments are unchanged.
public enum TranscriptReviewLayout: String, CaseIterable, Identifiable, Sendable {
    case segments
    case paragraphs

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .segments: "Segments"
        case .paragraphs: "Paragraphs"
        }
    }
}

/// Which turns the transcript list shows.
public enum TranscriptReviewFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case needsReview
    case unknownSpeaker
    case overlap
    case estimatedTiming

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all: "All turns"
        case .needsReview: "Needs review"
        case .unknownSpeaker: "Unknown speaker"
        case .overlap: "Overlapping speech"
        case .estimatedTiming: "Estimated timing"
        }
    }

    public func matches(_ segment: TranscriptSegment) -> Bool {
        switch self {
        case .all: true
        case .needsReview: segment.needsReview
        case .unknownSpeaker: segment.speakerID == nil
        case .overlap: segment.overlap
        case .estimatedTiming: segment.timingQuality == .segmentOnly
        }
    }

    public func matches(_ paragraph: TranscriptParagraph) -> Bool {
        if paragraph.asides.contains(where: { matches($0) }) { return true }
        return switch self {
        case .all: true
        case .needsReview: paragraph.needsReview
        case .unknownSpeaker: paragraph.speakerID == nil
        case .overlap: paragraph.overlap
        case .estimatedTiming: paragraph.timingQuality == .segmentOnly
        }
    }
}

public extension TranscriptSegment {
    /// Below this the diarizer was guessing, which is worth a second listen.
    static let lowSpeakerConfidence = 0.5

    var hasLowSpeakerConfidence: Bool {
        guard let speakerConfidence else { return false }
        return speakerConfidence < Self.lowSpeakerConfidence
    }

    /// A turn a reviewer should look at: no speaker, an uncertain one,
    /// overlapping speech, or timing that was estimated rather than measured.
    var needsReview: Bool {
        speakerID == nil || hasLowSpeakerConfidence || overlap || timingQuality == .segmentOnly
    }
}
