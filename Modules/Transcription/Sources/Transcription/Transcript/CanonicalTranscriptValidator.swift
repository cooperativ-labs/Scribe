import Foundation

/// Semantic checks that JSON Schema cannot express, such as speaker references and stable ordering.
public enum CanonicalTranscriptValidator {
    public static func validate(_ transcript: CanonicalTranscript) throws {
        guard transcript.schemaVersion == CanonicalTranscript.currentSchemaVersion else {
            throw Error.unsupportedSchemaVersion(transcript.schemaVersion)
        }
        guard !transcript.transcriptID.isEmpty else { throw Error.emptyTranscriptID }
        guard transcript.revision > 0 else { throw Error.invalidRevision(transcript.revision) }
        guard transcript.source.durationMs >= 0 else { throw Error.invalidSourceDuration(transcript.source.durationMs) }
        guard transcript.timestampUnit == .milliseconds, transcript.timestampOrigin == .sourceStart else {
            throw Error.unsupportedTimestampBasis
        }

        let speakerIDs = Set(transcript.speakers.map(\.id))
        guard speakerIDs.count == transcript.speakers.count, !transcript.speakers.contains(where: { $0.id.isEmpty || $0.labelSnapshot.isEmpty }) else {
            throw Error.invalidSpeakerTable
        }

        var segmentIDs = Set<String>()
        var previous: TranscriptSegment?
        for segment in transcript.segments {
            guard !segment.id.isEmpty, segmentIDs.insert(segment.id).inserted else { throw Error.duplicateOrEmptySegmentID(segment.id) }
            guard !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Error.emptySegmentText(segment.id) }
            guard segment.startMs >= 0, segment.startMs < segment.endMs, segment.endMs <= transcript.source.durationMs else {
                throw Error.invalidSegmentBounds(id: segment.id, startMs: segment.startMs, endMs: segment.endMs, durationMs: transcript.source.durationMs)
            }
            if let speakerID = segment.speakerID, !speakerIDs.contains(speakerID) {
                throw Error.unknownSpeakerReference(segmentID: segment.id, speakerID: speakerID)
            }
            if let previous, !isSorted(previous, before: segment) {
                throw Error.unsortedSegments(previousID: previous.id, nextID: segment.id)
            }
            for word in segment.words ?? [] {
                guard !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      word.startMs >= segment.startMs,
                      word.startMs < word.endMs,
                      word.endMs <= segment.endMs else {
                    throw Error.invalidWordBounds(segmentID: segment.id)
                }
            }
            previous = segment
        }

        for cue in transcript.subtitleCueMappings ?? [] {
            guard segmentIDs.contains(cue.parentSegmentID) else { throw Error.unknownCueParent(cueID: cue.cueID, parentSegmentID: cue.parentSegmentID) }
            guard cue.startMs >= 0, cue.startMs < cue.endMs, cue.endMs <= transcript.source.durationMs else {
                throw Error.invalidCueBounds(cueID: cue.cueID)
            }
        }
    }

    private static func isSorted(_ lhs: TranscriptSegment, before rhs: TranscriptSegment) -> Bool {
        if lhs.startMs != rhs.startMs { return lhs.startMs < rhs.startMs }
        if lhs.endMs != rhs.endMs { return lhs.endMs < rhs.endMs }
        return lhs.id <= rhs.id
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case unsupportedSchemaVersion(Int)
        case emptyTranscriptID
        case invalidRevision(Int)
        case invalidSourceDuration(Int)
        case unsupportedTimestampBasis
        case invalidSpeakerTable
        case duplicateOrEmptySegmentID(String)
        case emptySegmentText(String)
        case invalidSegmentBounds(id: String, startMs: Int, endMs: Int, durationMs: Int)
        case unknownSpeakerReference(segmentID: String, speakerID: String)
        case unsortedSegments(previousID: String, nextID: String)
        case invalidWordBounds(segmentID: String)
        case unknownCueParent(cueID: String, parentSegmentID: String)
        case invalidCueBounds(cueID: String)
    }
}
