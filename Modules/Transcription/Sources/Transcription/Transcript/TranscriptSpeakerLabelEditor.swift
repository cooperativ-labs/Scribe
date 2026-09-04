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

    public var errorDescription: String? {
        switch self {
        case let .unknownSpeaker(id): "This transcript has no speaker \(id)."
        case let .unknownSegment(id): "This transcript has no segment \(id)."
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

extension CanonicalTranscript {
    /// Copies this transcript with a new speaker table and segments at the next revision.
    func nextRevision(speakers: [TranscriptSpeaker], segments: [TranscriptSegment]) -> CanonicalTranscript {
        CanonicalTranscript(
            schemaVersion: schemaVersion,
            transcriptID: transcriptID,
            revision: revision + 1,
            status: status,
            createdAt: createdAt,
            source: source,
            language: language,
            languageSource: languageSource,
            timestampUnit: timestampUnit,
            timestampOrigin: timestampOrigin,
            speakers: speakers,
            segments: segments,
            subtitleCueMappings: subtitleCueMappings,
            processingOptions: processingOptions,
            engineRevisions: engineRevisions,
            warnings: warnings
        )
    }
}
