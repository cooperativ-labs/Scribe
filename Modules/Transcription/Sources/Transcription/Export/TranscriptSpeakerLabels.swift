import Foundation

/// Resolves the display name every export format prints for a segment.
///
/// The transcript's speaker table owns resolved display names, so exports read that revision's
/// `label_snapshot` rather than a segment's possibly older inline label. Segments with no speaker
/// reference keep their own label, which the assembler sets to the unknown-speaker wording.
public struct TranscriptSpeakerLabels: Sendable {
    private let snapshots: [String: String]

    public init(_ transcript: CanonicalTranscript) {
        snapshots = Dictionary(transcript.speakers.map { ($0.id, $0.labelSnapshot) }, uniquingKeysWith: { first, _ in first })
    }

    public func label(for segment: TranscriptSegment) -> String {
        guard let speakerID = segment.speakerID, let snapshot = snapshots[speakerID] else {
            return segment.speakerLabel
        }
        return snapshot
    }
}
