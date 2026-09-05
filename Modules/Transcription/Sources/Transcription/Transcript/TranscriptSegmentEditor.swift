import Foundation

public enum TranscriptSegmentEditError: Error, Equatable, Sendable, LocalizedError {
    case unknownSegment(String)
    case emptyText(String)
    case invalidSplitPoint(segmentID: String, tokenCount: Int)
    case notAdjacent(String, String)
    case emptyTitle

    public var errorDescription: String? {
        switch self {
        case let .unknownSegment(id): "This transcript has no segment \(id)."
        case let .emptyText(id): "Segment \(id) cannot be left without any words."
        case let .invalidSplitPoint(id, count): "Segment \(id) can only be split between its \(count) words."
        case let .notAdjacent(a, b): "Only neighbouring turns can be combined (\(a) and \(b) are not)."
        case .emptyTitle: "A transcript name cannot be blank."
        }
    }
}

/// One unit a segment can be split between: a word with its own timing when the
/// recognizer aligned words, or a whitespace-delimited token with an estimated
/// time otherwise.
public struct TranscriptSplitToken: Identifiable, Equatable, Sendable {
    public let index: Int
    public let text: String
    public let startMs: Int
    public let endMs: Int
    /// False when the token's time is interpolated from its position in the text.
    public let isTimed: Bool

    public var id: Int { index }
}

/// Structural edits to a saved transcript: splitting a turn, combining
/// neighbours, correcting words, and naming the transcript.
///
/// Like the label editor, every operation produces the next revision and
/// leaves the recognition run alone. Segment timing is preserved wherever the
/// recognizer gave word times, and marked `segment_only` wherever the editor
/// had to estimate a boundary instead. Cue mappings are dropped by structural
/// edits because they named segments that no longer exist; export rebuilds them.
public enum TranscriptSegmentEditor {
    // MARK: - Naming

    public static func renaming(to title: String?, in transcript: CanonicalTranscript) throws -> CanonicalTranscript {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, trimmed.isEmpty { throw TranscriptSegmentEditError.emptyTitle }
        return transcript.nextRevision(title: .some(trimmed))
    }

    // MARK: - Words

    /// Replaces a segment's words. Word timings are dropped because they
    /// described the words that were there before; the segment's own bounds
    /// still come from the recognizer.
    public static func replacingText(
        of segmentID: String,
        with text: String,
        in transcript: CanonicalTranscript
    ) throws -> CanonicalTranscript {
        guard let index = transcript.segments.firstIndex(where: { $0.id == segmentID }) else {
            throw TranscriptSegmentEditError.unknownSegment(segmentID)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranscriptSegmentEditError.emptyText(segmentID) }
        let segment = transcript.segments[index]
        guard trimmed != segment.text else { return transcript }
        var segments = transcript.segments
        segments[index] = TranscriptSegment(
            id: segment.id,
            speakerID: segment.speakerID,
            speakerLabel: segment.speakerLabel,
            startMs: segment.startMs,
            endMs: segment.endMs,
            text: trimmed,
            overlap: segment.overlap,
            timingQuality: segment.timingQuality,
            speakerConfidence: segment.speakerConfidence,
            words: nil
        )
        return transcript.nextRevision(segments: segments, subtitleCueMappings: .some(nil))
    }

    // MARK: - Splitting

    /// The units a segment can be split between, in reading order.
    ///
    /// Recognizer word timings are used when they cover the text; otherwise the
    /// text is tokenised on whitespace and each token is given a share of the
    /// segment's duration proportional to its length.
    public static func splitTokens(for segment: TranscriptSegment) -> [TranscriptSplitToken] {
        let textTokens = segment.text.split(whereSeparator: \.isWhitespace).map(String.init)
        if let words = segment.words, !words.isEmpty, words.count == textTokens.count,
           zip(words, textTokens).allSatisfy({ normalized($0.text) == normalized($1) }) {
            return words.enumerated().map { index, word in
                TranscriptSplitToken(index: index, text: textTokens[index], startMs: word.startMs, endMs: word.endMs, isTimed: true)
            }
        }
        let totalCharacters = max(1, textTokens.reduce(0) { $0 + $1.count })
        let duration = segment.endMs - segment.startMs
        var cursor = segment.startMs
        var consumed = 0
        return textTokens.enumerated().map { index, token in
            consumed += token.count
            let end = index == textTokens.count - 1
                ? segment.endMs
                : segment.startMs + Int((Double(duration) * Double(consumed) / Double(totalCharacters)).rounded())
            defer { cursor = end }
            return TranscriptSplitToken(index: index, text: token, startMs: cursor, endMs: max(cursor + 1, end), isTimed: false)
        }
    }

    /// Splits a segment into two before the token at `tokenIndex`.
    ///
    /// The first half ends where its last token ends and the second begins
    /// where its first token begins; the gap between them, if any, is the
    /// silence the recognizer measured. Both halves keep the speaker and the
    /// flags. When tokens carry estimated times, both halves are marked
    /// `segment_only` so exports say the boundary was not measured.
    public static func splitting(
        segmentID: String,
        beforeToken tokenIndex: Int,
        in transcript: CanonicalTranscript
    ) throws -> CanonicalTranscript {
        guard let index = transcript.segments.firstIndex(where: { $0.id == segmentID }) else {
            throw TranscriptSegmentEditError.unknownSegment(segmentID)
        }
        let segment = transcript.segments[index]
        let tokens = splitTokens(for: segment)
        guard tokenIndex > 0, tokenIndex < tokens.count else {
            throw TranscriptSegmentEditError.invalidSplitPoint(segmentID: segmentID, tokenCount: tokens.count)
        }
        let head = Array(tokens[..<tokenIndex])
        let tail = Array(tokens[tokenIndex...])
        let estimated = tokens.contains { !$0.isTimed }
        let quality: TranscriptTimingQuality = estimated ? .segmentOnly : segment.timingQuality
        let existingIDs = Set(transcript.segments.map(\.id))
        let ids = uniqueIDs(from: segment.id, count: 2, avoiding: existingIDs)

        // Halves never extend past the parent: a first token that starts after
        // the parent (estimation rounding) is pulled back to the parent's start.
        let headStart = segment.startMs
        let headEnd = min(segment.endMs, max(headStart + 1, head[head.count - 1].endMs))
        let tailStart = max(headEnd, min(tail[0].startMs, segment.endMs - 1))
        let tailEnd = segment.endMs

        func half(id: String, tokens: [TranscriptSplitToken], startMs: Int, endMs: Int) -> TranscriptSegment {
            let words: [TimedWord]? = estimated || segment.words == nil ? nil : tokens.map {
                TimedWord(text: $0.text, startMs: max(startMs, $0.startMs), endMs: min(endMs, $0.endMs))
            }
            return TranscriptSegment(
                id: id,
                speakerID: segment.speakerID,
                speakerLabel: segment.speakerLabel,
                startMs: startMs,
                endMs: endMs,
                text: tokens.map(\.text).joined(separator: " "),
                overlap: segment.overlap,
                timingQuality: quality,
                speakerConfidence: segment.speakerConfidence,
                words: words
            )
        }

        var segments = transcript.segments
        segments.replaceSubrange(index...index, with: [
            half(id: ids[0], tokens: head, startMs: headStart, endMs: headEnd),
            half(id: ids[1], tokens: tail, startMs: tailStart, endMs: tailEnd),
        ])
        return transcript.nextRevision(segments: sorted(segments), subtitleCueMappings: .some(nil))
    }

    // MARK: - Combining

    /// Combines two neighbouring turns into one that spans both.
    ///
    /// The earlier turn's identity, speaker, and confidence are kept; the words
    /// are joined in order. Word timings survive when both halves had them.
    /// Timing quality is the weaker of the two, and the overlap flag is set if
    /// either half carried it.
    public static func merging(
        segmentID: String,
        with otherID: String,
        in transcript: CanonicalTranscript
    ) throws -> CanonicalTranscript {
        let ordered = sorted(transcript.segments)
        guard let first = ordered.firstIndex(where: { $0.id == segmentID }) else {
            throw TranscriptSegmentEditError.unknownSegment(segmentID)
        }
        guard let second = ordered.firstIndex(where: { $0.id == otherID }) else {
            throw TranscriptSegmentEditError.unknownSegment(otherID)
        }
        guard abs(first - second) == 1 else { throw TranscriptSegmentEditError.notAdjacent(segmentID, otherID) }
        let earlier = ordered[min(first, second)]
        let later = ordered[max(first, second)]

        let words: [TimedWord]? = if let a = earlier.words, let b = later.words { a + b } else { nil }
        let quality: TranscriptTimingQuality = earlier.timingQuality == .segmentOnly || later.timingQuality == .segmentOnly
            ? .segmentOnly
            : earlier.timingQuality
        let merged = TranscriptSegment(
            id: earlier.id,
            speakerID: earlier.speakerID,
            speakerLabel: earlier.speakerLabel,
            startMs: min(earlier.startMs, later.startMs),
            endMs: max(earlier.endMs, later.endMs),
            text: [earlier.text, later.text].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: " "),
            overlap: earlier.overlap || later.overlap,
            timingQuality: quality,
            speakerConfidence: earlier.speakerConfidence,
            words: words
        )
        var segments = ordered
        segments.removeAll { $0.id == earlier.id || $0.id == later.id }
        segments.append(merged)
        return transcript.nextRevision(segments: sorted(segments), subtitleCueMappings: .some(nil))
    }

    // MARK: - Helpers

    /// The order the validator requires: start, end, then id.
    static func sorted(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.sorted { ($0.startMs, $0.endMs, $0.id) < ($1.startMs, $1.endMs, $1.id) }
    }

    /// Child ids that sort beside their parent and never collide with an
    /// existing one, however many times the same turn is split.
    static func uniqueIDs(from parentID: String, count: Int, avoiding existing: Set<String>) -> [String] {
        var ids: [String] = []
        var taken = existing
        var suffix = 1
        while ids.count < count {
            let candidate = "\(parentID).\(suffix)"
            suffix += 1
            guard !taken.contains(candidate) else { continue }
            taken.insert(candidate)
            ids.append(candidate)
        }
        return ids
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

extension CanonicalTranscript {
    /// This content, saved as revision `revision`. Undo restores an earlier
    /// state as a newer revision rather than rewinding the number, so the store
    /// and every window still see revisions only ever go up.
    func asRevision(_ revision: Int) -> CanonicalTranscript {
        CanonicalTranscript(
            schemaVersion: schemaVersion,
            transcriptID: transcriptID,
            revision: revision,
            title: title,
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
