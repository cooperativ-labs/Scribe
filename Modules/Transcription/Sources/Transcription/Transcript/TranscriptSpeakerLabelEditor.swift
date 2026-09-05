import Foundation
import Speakers

/// What a label edit applies to.
///
/// A cluster edit renames a recording-local speaker everywhere it appears. A
/// turn edit re-attributes one segment, which is the correction for a turn
/// diarization placed under the wrong cluster.
public enum TranscriptSpeakerScope: Equatable, Sendable {
    case cluster(speakerID: String)
    case turn(segmentID: String)
}

public enum TranscriptSpeakerLabelError: Error, Equatable, Sendable, LocalizedError {
    case unknownSpeaker(String)
    case unknownSegment(String)
    case sameSpeaker(String)

    public var errorDescription: String? {
        switch self {
        case let .unknownSpeaker(id): "This transcript has no speaker \(id)."
        case let .unknownSegment(id): "This transcript has no segment \(id)."
        case let .sameSpeaker(id): "\(id) cannot be merged into itself."
        }
    }
}

/// Applies label decisions to a saved transcript by producing the next revision.
///
/// Every edit here is a relabeling of an existing recognition result: words,
/// timings, and diarization boundaries are untouched, so corrections never
/// require rerunning ASR. Exports read the speaker table's `labelSnapshot`
/// (see `TranscriptSpeakerLabels`), so a revision produced here is the one the
/// next export writes.
public enum TranscriptSpeakerLabelEditor {
    public static let unknownSpeakerLabel = "Unknown speaker"

    /// The generic label a recording-local speaker falls back to, following the
    /// turn builder's `speaker_N` → "Speaker N" convention.
    public static func genericLabel(for speaker: TranscriptSpeaker, at index: Int) -> String {
        let prefix = "speaker_"
        if speaker.id.hasPrefix(prefix) {
            let suffix = speaker.id.dropFirst(prefix.count)
            if !suffix.isEmpty, suffix.allSatisfy(\.isNumber) { return "Speaker \(suffix)" }
        }
        return "Speaker \(index + 1)"
    }

    /// Assigns `person` (or clears the assignment when nil) and returns the next revision.
    ///
    /// - Parameter assignment: how the label was decided. A confirmed suggestion
    ///   is `.manual`, because a person approved it; only the matcher writes `.automatic`.
    public static func assigning(
        person: SpeakerPersonRef?,
        scope: TranscriptSpeakerScope,
        assignment: SpeakerIdentityAssignment = .manual,
        in transcript: CanonicalTranscript
    ) throws -> CanonicalTranscript {
        switch scope {
        case let .cluster(speakerID):
            return try assigningCluster(person: person, speakerID: speakerID, assignment: assignment, in: transcript)
        case let .turn(segmentID):
            return try assigningTurn(person: person, segmentID: segmentID, assignment: assignment, in: transcript)
        }
    }

    /// Refreshes saved labels from current library names, returning the next
    /// revision, or nil when nothing changed.
    ///
    /// A profile missing from `people` was deleted: its transcript keeps the
    /// label the revision already recorded rather than reverting to generic.
    public static func refreshingLabels(
        using people: [SpeakerPersonRef],
        in transcript: CanonicalTranscript
    ) -> CanonicalTranscript? {
        let names = Dictionary(people.map { ($0.profileID.uuidString, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        var changed = false
        let speakers = transcript.speakers.map { speaker -> TranscriptSpeaker in
            guard let profileID = speaker.profileID,
                  let name = names[profileID],
                  name != speaker.labelSnapshot else { return speaker }
            changed = true
            return TranscriptSpeaker(
                id: speaker.id,
                profileID: speaker.profileID,
                identityAssignment: speaker.identityAssignment,
                labelSnapshot: name
            )
        }
        guard changed else { return nil }
        return transcript.nextRevision(speakers: speakers, segments: relabeledSegments(transcript.segments, from: speakers))
    }

    /// Moves one turn under another speaker this recording already has, named
    /// or not. This is the fix for a turn diarization filed under the wrong
    /// cluster when neither cluster is matched to a saved person yet.
    public static func moving(
        segmentID: String,
        toSpeakerID speakerID: String,
        in transcript: CanonicalTranscript
    ) throws -> CanonicalTranscript {
        guard let segmentIndex = transcript.segments.firstIndex(where: { $0.id == segmentID }) else {
            throw TranscriptSpeakerLabelError.unknownSegment(segmentID)
        }
        guard let speaker = transcript.speakers.first(where: { $0.id == speakerID }) else {
            throw TranscriptSpeakerLabelError.unknownSpeaker(speakerID)
        }
        var segments = transcript.segments
        segments[segmentIndex] = segments[segmentIndex].withSpeaker(id: speaker.id, label: speaker.labelSnapshot)
        return transcript.nextRevision(segments: segments)
    }

    /// Folds every turn of `speakerID` into `targetSpeakerID` and drops the
    /// emptied speaker from the table. This is the fix for diarization that
    /// split one person into two clusters; the target keeps its own name and
    /// assignment.
    public static func merging(
        speakerID: String,
        into targetSpeakerID: String,
        in transcript: CanonicalTranscript
    ) throws -> CanonicalTranscript {
        guard speakerID != targetSpeakerID else { throw TranscriptSpeakerLabelError.sameSpeaker(speakerID) }
        guard transcript.speakers.contains(where: { $0.id == speakerID }) else {
            throw TranscriptSpeakerLabelError.unknownSpeaker(speakerID)
        }
        guard let target = transcript.speakers.first(where: { $0.id == targetSpeakerID }) else {
            throw TranscriptSpeakerLabelError.unknownSpeaker(targetSpeakerID)
        }
        let segments = transcript.segments.map { segment in
            segment.speakerID == speakerID ? segment.withSpeaker(id: target.id, label: target.labelSnapshot) : segment
        }
        let speakers = transcript.speakers.filter { $0.id != speakerID }
        return transcript.nextRevision(speakers: speakers, segments: segments)
    }

    private static func assigningCluster(
        person: SpeakerPersonRef?,
        speakerID: String,
        assignment: SpeakerIdentityAssignment,
        in transcript: CanonicalTranscript
    ) throws -> CanonicalTranscript {
        guard let index = transcript.speakers.firstIndex(where: { $0.id == speakerID }) else {
            throw TranscriptSpeakerLabelError.unknownSpeaker(speakerID)
        }
        var speakers = transcript.speakers
        speakers[index] = TranscriptSpeaker(
            id: speakerID,
            profileID: person?.profileID.uuidString,
            identityAssignment: person == nil ? .unmatched : assignment,
            labelSnapshot: person?.displayName ?? genericLabel(for: speakers[index], at: index)
        )
        return transcript.nextRevision(speakers: speakers, segments: relabeledSegments(transcript.segments, from: speakers))
    }

    private static func assigningTurn(
        person: SpeakerPersonRef?,
        segmentID: String,
        assignment: SpeakerIdentityAssignment,
        in transcript: CanonicalTranscript
    ) throws -> CanonicalTranscript {
        guard let segmentIndex = transcript.segments.firstIndex(where: { $0.id == segmentID }) else {
            throw TranscriptSpeakerLabelError.unknownSegment(segmentID)
        }
        var speakers = transcript.speakers
        var targetSpeakerID: String?

        if let person {
            // Reuse this person's existing entry when the transcript already has
            // one, so a corrected turn joins that speaker rather than splitting
            // the same person across two entries.
            if let existing = speakers.first(where: { $0.profileID == person.profileID.uuidString }) {
                targetSpeakerID = existing.id
            } else {
                let newID = manualSpeakerID(for: person, in: speakers)
                speakers.append(
                    TranscriptSpeaker(
                        id: newID,
                        profileID: person.profileID.uuidString,
                        identityAssignment: assignment,
                        labelSnapshot: person.displayName
                    )
                )
                targetSpeakerID = newID
            }
        }

        var segments = transcript.segments
        let segment = segments[segmentIndex]
        segments[segmentIndex] = TranscriptSegment(
            id: segment.id,
            speakerID: targetSpeakerID,
            speakerLabel: person?.displayName ?? unknownSpeakerLabel,
            startMs: segment.startMs,
            endMs: segment.endMs,
            text: segment.text,
            overlap: segment.overlap,
            timingQuality: segment.timingQuality,
            speakerConfidence: segment.speakerConfidence,
            words: segment.words
        )
        return transcript.nextRevision(speakers: speakers, segments: relabeledSegments(segments, from: speakers))
    }

    private static func manualSpeakerID(for person: SpeakerPersonRef, in speakers: [TranscriptSpeaker]) -> String {
        let candidate = "speaker_manual_\(person.profileID.uuidString.lowercased())"
        guard speakers.contains(where: { $0.id == candidate }) else { return candidate }
        return "\(candidate)_\(speakers.count + 1)"
    }

    /// Keeps every segment's inline label in step with its speaker's snapshot.
    private static func relabeledSegments(
        _ segments: [TranscriptSegment],
        from speakers: [TranscriptSpeaker]
    ) -> [TranscriptSegment] {
        let snapshots = Dictionary(speakers.map { ($0.id, $0.labelSnapshot) }, uniquingKeysWith: { first, _ in first })
        return segments.map { segment in
            guard let speakerID = segment.speakerID,
                  let snapshot = snapshots[speakerID],
                  snapshot != segment.speakerLabel else { return segment }
            return TranscriptSegment(
                id: segment.id,
                speakerID: segment.speakerID,
                speakerLabel: snapshot,
                startMs: segment.startMs,
                endMs: segment.endMs,
                text: segment.text,
                overlap: segment.overlap,
                timingQuality: segment.timingQuality,
                speakerConfidence: segment.speakerConfidence,
                words: segment.words
            )
        }
    }
}

extension TranscriptSegment {
    /// The same words and timing under another speaker.
    func withSpeaker(id speakerID: String?, label: String) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            speakerID: speakerID,
            speakerLabel: label,
            startMs: startMs,
            endMs: endMs,
            text: text,
            overlap: overlap,
            timingQuality: timingQuality,
            speakerConfidence: speakerConfidence,
            words: words
        )
    }
}

extension CanonicalTranscript {
    /// Copies this transcript at the next revision, replacing only what an edit
    /// changed. A structural edit passes `subtitleCueMappings: nil` because the
    /// cues it carried described segments that no longer exist; export rebuilds
    /// them from the segments that do.
    func nextRevision(
        title: String?? = nil,
        speakers: [TranscriptSpeaker]? = nil,
        segments: [TranscriptSegment]? = nil,
        subtitleCueMappings: [SubtitleCueMapping]?? = nil
    ) -> CanonicalTranscript {
        CanonicalTranscript(
            schemaVersion: schemaVersion,
            transcriptID: transcriptID,
            revision: revision + 1,
            title: title ?? self.title,
            status: status,
            createdAt: createdAt,
            source: source,
            language: language,
            languageSource: languageSource,
            timestampUnit: timestampUnit,
            timestampOrigin: timestampOrigin,
            speakers: speakers ?? self.speakers,
            segments: segments ?? self.segments,
            subtitleCueMappings: subtitleCueMappings ?? self.subtitleCueMappings,
            processingOptions: processingOptions,
            engineRevisions: engineRevisions,
            warnings: warnings
        )
    }
}
