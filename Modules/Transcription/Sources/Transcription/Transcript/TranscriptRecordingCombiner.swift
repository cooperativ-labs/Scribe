import Foundation

/// Joins the transcripts of two recordings of the same call into one, as if
/// the second had been recorded straight after the first.
///
/// This is for a meeting whose recording was cut off and restarted: same call,
/// same people. Nothing is transcribed again. The second transcript's times
/// move by the length of the first recording, its turns follow the first's,
/// and its speakers are folded into the first's speaker table:
///
/// - a speaker the library recognised as the same person (same profile) in
///   both recordings becomes one speaker;
/// - a speaker a person or the library named, whose name matches a named
///   speaker in the first recording, becomes that speaker;
/// - anyone else stays a separate speaker under a fresh `speaker_N` id, so two
///   unrelated "Speaker 2" clusters are never silently treated as one person.
///   Review's existing "merge speakers" action joins them if they are.
///
/// Edits made in review are kept on both sides, because the inputs are the
/// saved revisions.
public enum TranscriptRecordingCombiner {
    /// Provenance recorded in `processing_options` under this key.
    public static let processingOptionKey = "combined_recordings"

    public struct Result: Equatable, Sendable {
        public let transcript: CanonicalTranscript
        public let suggestions: [TranscriptSpeakerSuggestion]
        /// The second recording's speaker ids mapped to the combined table's.
        public let speakerIDMap: [String: String]
    }

    /// - Parameters:
    ///   - first: The recording that comes first. Its identity, title, and
    ///     creation date are kept.
    ///   - second: The recording appended after it.
    ///   - offsetMs: Where the second recording starts in the combined audio,
    ///     which is the measured length of the first.
    ///   - source: The combined audio the result describes.
    public static func combine(
        first: CanonicalTranscript,
        firstSuggestions: [TranscriptSpeakerSuggestion] = [],
        second: CanonicalTranscript,
        secondSuggestions: [TranscriptSpeakerSuggestion] = [],
        offsetMs: Int,
        source: TranscriptSource
    ) -> Result {
        let speakerMap = speakerIDMap(first: first.speakers, second: second.speakers)
        let speakers = combinedSpeakers(first: first.speakers, second: second.speakers, map: speakerMap)
        let labels = Dictionary(speakers.map { ($0.id, $0.labelSnapshot) }, uniquingKeysWith: { lhs, _ in lhs })

        var takenSegmentIDs = Set(first.segments.map(\.id))
        var segmentIDMap: [String: String] = [:]
        var nextNumber = first.segments.count + 1
        for segment in second.segments {
            var candidate = segment.id
            while takenSegmentIDs.contains(candidate) {
                candidate = String(format: "segment_%03d", nextNumber)
                nextNumber += 1
            }
            takenSegmentIDs.insert(candidate)
            segmentIDMap[segment.id] = candidate
        }

        // Clamped so that rounding in either recording's measured length can
        // never push a turn past the end of the combined audio.
        let endLimit = max(source.durationMs, 1)
        let firstSegments = first.segments.map { clamp($0, toEnd: endLimit) }
        let secondSegments = second.segments.map { segment in
            clamp(
                shifted(segment, by: offsetMs, id: segmentIDMap[segment.id] ?? segment.id, speakerMap: speakerMap, labels: labels),
                toEnd: endLimit
            )
        }
        let segments = TranscriptSegmentEditor.sorted(firstSegments + secondSegments)

        let warnings = first.warnings + second.warnings.map { warning in
            TranscriptWarning(code: warning.code, message: warning.message, segmentID: warning.segmentID.map { segmentIDMap[$0] ?? $0 })
        }

        var options = first.processingOptions
        options[processingOptionKey] = .array([
            part(first.source, offsetMs: 0, transcriptID: first.transcriptID),
            part(second.source, offsetMs: offsetMs, transcriptID: second.transcriptID),
        ])

        var engineRevisions = second.engineRevisions
        engineRevisions.merge(first.engineRevisions) { _, firstValue in firstValue }

        let transcript = CanonicalTranscript(
            transcriptID: first.transcriptID,
            revision: max(first.revision, second.revision) + 1,
            title: first.title ?? second.title,
            status: combinedStatus(first.status, second.status),
            createdAt: first.createdAt,
            source: source,
            language: first.language,
            languageSource: first.languageSource,
            timestampUnit: first.timestampUnit,
            timestampOrigin: first.timestampOrigin,
            speakers: speakers,
            segments: segments,
            // Cues described the separate recordings; export rebuilds them.
            subtitleCueMappings: nil,
            processingOptions: options,
            engineRevisions: engineRevisions,
            warnings: warnings
        )

        var suggestions = firstSuggestions
        var suggested = Set(firstSuggestions.map(\.speakerID))
        for suggestion in secondSuggestions {
            let speakerID = speakerMap[suggestion.speakerID] ?? suggestion.speakerID
            guard suggested.insert(speakerID).inserted else { continue }
            suggestions.append(TranscriptSpeakerSuggestion(
                speakerID: speakerID,
                person: suggestion.person,
                score: suggestion.score,
                matcherVersion: suggestion.matcherVersion,
                appliedAutomatically: suggestion.appliedAutomatically
            ))
        }

        return Result(transcript: transcript, suggestions: suggestions, speakerIDMap: speakerMap)
    }

    // MARK: - Speakers

    /// Where each of the second recording's speakers goes in the combined table.
    static func speakerIDMap(first: [TranscriptSpeaker], second: [TranscriptSpeaker]) -> [String: String] {
        var map: [String: String] = [:]
        var claimed = Set<String>()
        let byProfile = Dictionary(
            first.compactMap { speaker in speaker.profileID.map { ($0, speaker.id) } },
            uniquingKeysWith: { lhs, _ in lhs }
        )
        let byName = Dictionary(
            first.filter(isNamed).map { (normalized($0.labelSnapshot), $0.id) },
            uniquingKeysWith: { lhs, _ in lhs }
        )

        for speaker in second {
            if let profileID = speaker.profileID, let target = byProfile[profileID], !claimed.contains(target) {
                map[speaker.id] = target
                claimed.insert(target)
            }
        }
        for speaker in second where map[speaker.id] == nil && isNamed(speaker) {
            if let target = byName[normalized(speaker.labelSnapshot)], !claimed.contains(target) {
                map[speaker.id] = target
                claimed.insert(target)
            }
        }

        var taken = Set(first.map(\.id))
        var nextNumber = (first.compactMap(speakerNumber).max() ?? first.count) + 1
        for speaker in second where map[speaker.id] == nil {
            var candidate = "speaker_\(nextNumber)"
            while taken.contains(candidate) {
                nextNumber += 1
                candidate = "speaker_\(nextNumber)"
            }
            nextNumber += 1
            taken.insert(candidate)
            map[speaker.id] = candidate
        }
        return map
    }

    private static func combinedSpeakers(
        first: [TranscriptSpeaker],
        second: [TranscriptSpeaker],
        map: [String: String]
    ) -> [TranscriptSpeaker] {
        let firstIDs = Set(first.map(\.id))
        var labels = Set(first.map { normalized($0.labelSnapshot) })
        var speakers = first
        for speaker in second {
            guard let id = map[speaker.id], !firstIDs.contains(id) else { continue }
            // A generic label follows the new id, so the second recording's
            // "Speaker 2" does not read as the first recording's "Speaker 2".
            var label = isNamed(speaker)
                ? speaker.labelSnapshot
                : TranscriptSpeakerLabelEditor.genericLabel(
                    for: TranscriptSpeaker(id: id, identityAssignment: .unmatched, labelSnapshot: speaker.labelSnapshot),
                    at: speakers.count
                )
            if labels.contains(normalized(label)) {
                label = TranscriptSpeakerLabelEditor.genericLabel(
                    for: TranscriptSpeaker(id: id, identityAssignment: .unmatched, labelSnapshot: label),
                    at: speakers.count
                )
            }
            labels.insert(normalized(label))
            speakers.append(TranscriptSpeaker(
                id: id,
                profileID: speaker.profileID,
                identityAssignment: speaker.identityAssignment,
                labelSnapshot: label
            ))
        }
        return speakers
    }

    /// A speaker someone put a name to: assigned by hand, matched from the
    /// library, or given a label other than the generic "Speaker N".
    private static func isNamed(_ speaker: TranscriptSpeaker) -> Bool {
        if speaker.identityAssignment != .unmatched || speaker.profileID != nil { return true }
        return !isGenericLabel(speaker.labelSnapshot)
    }

    private static func isGenericLabel(_ label: String) -> Bool {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("Speaker ") else {
            return trimmed.caseInsensitiveCompare(TranscriptSpeakerLabelEditor.unknownSpeakerLabel) == .orderedSame
        }
        let suffix = trimmed.dropFirst("Speaker ".count)
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }

    private static func speakerNumber(_ speaker: TranscriptSpeaker) -> Int? {
        guard speaker.id.hasPrefix("speaker_") else { return nil }
        return Int(speaker.id.dropFirst("speaker_".count))
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - Segments

    private static func shifted(
        _ segment: TranscriptSegment,
        by offsetMs: Int,
        id: String,
        speakerMap: [String: String],
        labels: [String: String]
    ) -> TranscriptSegment {
        let speakerID = segment.speakerID.map { speakerMap[$0] ?? $0 }
        let inference = segment.speakerInference.map { inference in
            let inferredID = speakerMap[inference.speakerID] ?? inference.speakerID
            return TranscriptSpeakerInference(
                speakerID: inferredID,
                speakerLabel: labels[inferredID] ?? inference.speakerLabel,
                evidence: inference.evidence,
                provenance: inference.provenance,
                diarizationHoleMs: inference.diarizationHoleMs,
                overlapMs: inference.overlapMs
            )
        }
        return TranscriptSegment(
            id: id,
            speakerID: speakerID,
            speakerLabel: speakerID.flatMap { labels[$0] } ?? segment.speakerLabel,
            startMs: segment.startMs + offsetMs,
            endMs: segment.endMs + offsetMs,
            text: segment.text,
            overlap: segment.overlap,
            timingQuality: segment.timingQuality,
            speakerConfidence: segment.speakerConfidence,
            words: segment.words?.map { TimedWord(text: $0.text, startMs: $0.startMs + offsetMs, endMs: $0.endMs + offsetMs) },
            attributionSource: segment.attributionSource,
            speakerInference: inference,
            unresolvedSpeakerEvidence: segment.unresolvedSpeakerEvidence
        )
    }

    /// Keeps a turn inside the combined audio. Only a turn ending within a
    /// few milliseconds of a recording's end is ever affected.
    private static func clamp(_ segment: TranscriptSegment, toEnd end: Int) -> TranscriptSegment {
        guard segment.endMs > end else { return segment }
        let endMs = end
        let startMs = min(segment.startMs, endMs - 1)
        let words = segment.words?.compactMap { word -> TimedWord? in
            let wordEnd = min(word.endMs, endMs)
            let wordStart = max(min(word.startMs, wordEnd - 1), startMs)
            guard wordStart < wordEnd else { return nil }
            return TimedWord(text: word.text, startMs: wordStart, endMs: wordEnd)
        }
        return TranscriptSegment(
            id: segment.id,
            speakerID: segment.speakerID,
            speakerLabel: segment.speakerLabel,
            startMs: max(startMs, 0),
            endMs: endMs,
            text: segment.text,
            overlap: segment.overlap,
            timingQuality: segment.timingQuality,
            speakerConfidence: segment.speakerConfidence,
            words: words,
            attributionSource: segment.attributionSource,
            speakerInference: segment.speakerInference,
            unresolvedSpeakerEvidence: segment.unresolvedSpeakerEvidence
        )
    }

    // MARK: - Metadata

    private static func combinedStatus(_ lhs: TranscriptStatus, _ rhs: TranscriptStatus) -> TranscriptStatus {
        if lhs == .completeWithWarnings || rhs == .completeWithWarnings { return .completeWithWarnings }
        if lhs == .noSpeech && rhs == .noSpeech { return .noSpeech }
        return .complete
    }

    private static func part(_ source: TranscriptSource, offsetMs: Int, transcriptID: String) -> TranscriptJSONValue {
        .object([
            "transcript_id": .string(transcriptID),
            "filename": .string(source.filename),
            "checksum": .string(source.checksum),
            "duration_ms": .number(Double(source.durationMs)),
            "offset_ms": .number(Double(offsetMs)),
        ])
    }
}
