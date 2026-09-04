import Foundation
import Speakers

/// One transcript segment offered as an enrollment excerpt.
///
/// The user listens to each candidate and confirms it; nothing here is
/// enrolled implicitly. Ineligible segments stay visible with their reason so
/// a short or overlapping turn is explained rather than silently dropped.
public struct TranscriptEnrollmentCandidate: Identifiable, Equatable, Sendable {
    public let segmentID: String
    public let speakerID: String
    public let startMs: Int
    public let endMs: Int
    public let text: String
    public let exclusionReason: String?
    public var isConfirmed: Bool

    public var id: String { segmentID }
    public var isEligible: Bool { exclusionReason == nil }
    public var duration: TimeInterval { Double(max(0, endMs - startMs)) / 1_000 }

    public init(
        segmentID: String,
        speakerID: String,
        startMs: Int,
        endMs: Int,
        text: String,
        exclusionReason: String?,
        isConfirmed: Bool = false
    ) {
        self.segmentID = segmentID
        self.speakerID = speakerID
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.exclusionReason = exclusionReason
        self.isConfirmed = isConfirmed
    }
}

/// Builds "Remember this voice" excerpts from a transcript.
///
/// Only a single recording-local cluster contributes, and overlapping,
/// estimated-timing, and very short turns are excluded, because enrolling a
/// whole cluster blindly can teach the library a merged speaker.
public enum TranscriptEnrollmentCandidates {
    public static func candidates(
        forSpeakerID speakerID: String,
        in transcript: CanonicalTranscript,
        minimumUtteranceDuration: TimeInterval = SpeakerEnrollmentConfiguration().minimumUtteranceDuration
    ) -> [TranscriptEnrollmentCandidate] {
        transcript.segments
            .filter { $0.speakerID == speakerID }
            .sorted { ($0.startMs, $0.id) < ($1.startMs, $1.id) }
            .map { segment in
                TranscriptEnrollmentCandidate(
                    segmentID: segment.id,
                    speakerID: speakerID,
                    startMs: segment.startMs,
                    endMs: segment.endMs,
                    text: segment.text,
                    exclusionReason: exclusionReason(for: segment, minimumUtteranceDuration: minimumUtteranceDuration)
                )
            }
    }

    /// Converts confirmed candidates into enrollment excerpts. Ineligible or
    /// unconfirmed candidates are dropped rather than downgraded.
    public static func excerpts(from candidates: [TranscriptEnrollmentCandidate]) -> [SpeakerEnrollmentExcerpt] {
        candidates
            .filter { $0.isConfirmed && $0.isEligible }
            .map { candidate in
                SpeakerEnrollmentExcerpt(
                    excerptID: candidate.segmentID,
                    timeRanges: [SpeakerTimeRange(startMs: candidate.startMs, endMs: candidate.endMs)],
                    containsSilence: false,
                    containsOverlap: false,
                    containsClipping: false,
                    isConfirmed: true
                )
            }
    }

    public static func confirmedSpeechDuration(of candidates: [TranscriptEnrollmentCandidate]) -> TimeInterval {
        candidates.filter { $0.isConfirmed && $0.isEligible }.reduce(0) { $0 + $1.duration }
    }

    private static func exclusionReason(
        for segment: TranscriptSegment,
        minimumUtteranceDuration: TimeInterval
    ) -> String? {
        if segment.overlap { return "Overlapping speech" }
        if segment.timingQuality == .segmentOnly { return "Estimated timing" }
        if Double(max(0, segment.endMs - segment.startMs)) / 1_000 < minimumUtteranceDuration {
            return "Shorter than \(String(format: "%.0f", minimumUtteranceDuration))s"
        }
        return nil
    }
}
