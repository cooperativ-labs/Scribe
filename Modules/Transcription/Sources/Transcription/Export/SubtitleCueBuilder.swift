import Foundation

/// Turns the canonical turns of one saved revision into the display cues an SRT file writes.
///
/// The builder is a pure transformation of a validated revision. It never removes a word, never
/// moves speech to a timestamp the source does not support, and never extends a cue past the
/// enclosing segment. Where a readability target cannot be met, the cue carries a review flag.
public enum SubtitleCueBuilder {
    /// Builds the numbered, non-overlapping display cues for a revision.
    ///
    /// A recording with no speech produces no cues, which the exporter writes as an empty file.
    public static func cues(
        for transcript: CanonicalTranscript,
        targets: SubtitleReadabilityTargets = .standard
    ) throws -> [SubtitleCue] {
        try TranscriptExporter.validate(transcript)
        let labels = TranscriptSpeakerLabels(transcript)
        let drafts = transcript.segments.flatMap { segment in
            self.drafts(for: segment, label: labels.label(for: segment), targets: targets)
        }
        return finish(merge(drafts), targets: targets)
    }

    /// The canonical `subtitle_cue_mappings` rows for a built cue list.
    ///
    /// A split turn contributes one row per cue, and a merged cue contributes one row per
    /// contributing segment, so JSON can always name the parent segment a cue came from. The row's
    /// interval is the cue's display interval; the segments keep their original timings in
    /// `segments`, which is what a merged overlap needs to stay honest.
    public static func mappings(for cues: [SubtitleCue]) -> [SubtitleCueMapping] {
        cues.flatMap { cue in
            cue.parentSegmentIDs.map {
                SubtitleCueMapping(cueID: cue.id, parentSegmentID: $0, startMs: cue.startMs, endMs: cue.endMs)
            }
        }
    }

    // MARK: - One turn at a time

    /// Splits one canonical turn into as many draft cues as readability requires.
    private static func drafts(for segment: TranscriptSegment, label: String, targets: SubtitleReadabilityTargets) -> [Draft] {
        let text = normalized(segment.text)
        let whole = Draft(
            startMs: segment.startMs,
            endMs: segment.endMs,
            blocks: [DraftBlock(segment: segment, label: label, text: text)],
            flags: []
        )
        guard needsSplitting(text: text, label: label, durationMs: segment.endMs - segment.startMs, targets: targets) else {
            return [whole]
        }
        guard let words = validatedWords(of: segment, matching: text) else {
            // Without trustworthy word times, keep the enclosing interval and ask for a review
            // rather than distributing words evenly as if they had been aligned.
            return [whole.flagged(.wordTimingUnavailable)]
        }
        return split(segment, label: label, words: words, targets: targets)
    }

    private static func split(
        _ segment: TranscriptSegment,
        label: String,
        words: [TimedWord],
        targets: SubtitleReadabilityTargets
    ) -> [Draft] {
        var drafts: [Draft] = []
        var index = 0
        while index < words.count {
            var count = 1
            // Take one more word while the cue would still read comfortably. A first word that
            // already breaks the targets is still taken: dropping it would remove speech.
            while index + count < words.count {
                let candidate = Array(words[index..<(index + count + 1)])
                let duration = candidate[candidate.count - 1].endMs - candidate[0].startMs
                guard duration <= targets.maximumDurationMs,
                      fits(text: joined(candidate), label: label, targets: targets) else { break }
                count += 1
            }
            let chunk = Array(words[index..<(index + count)])
            let isFirst = index == 0
            let isLast = index + count == words.count
            drafts.append(Draft(
                // The outer edges stay the segment's own, so the cues cover the turn exactly and
                // never reach past it; the interior boundaries are the validated word times.
                startMs: isFirst ? segment.startMs : chunk[0].startMs,
                endMs: isLast ? segment.endMs : chunk[chunk.count - 1].endMs,
                blocks: [DraftBlock(segment: segment, label: label, text: joined(chunk))],
                flags: []
            ))
            index += count
        }
        return drafts
    }

    /// The segment's words when they can be trusted as split points.
    ///
    /// They must come from decoder-derived timing, run forward without overlapping each other, and
    /// reproduce the segment text exactly, so that splitting on them cannot alter what is said.
    private static func validatedWords(of segment: TranscriptSegment, matching text: String) -> [TimedWord]? {
        guard segment.timingQuality != .segmentOnly, let words = segment.words, !words.isEmpty else { return nil }
        var previousEnd = Int.min
        for word in words {
            guard word.startMs < word.endMs, word.startMs >= previousEnd else { return nil }
            previousEnd = word.endMs
        }
        guard joined(words) == text else { return nil }
        return words
    }

    // MARK: - Colliding cues

    /// Merges cues that would be on screen at the same time into one cue spanning their union.
    ///
    /// Sorting by start time and folding each cue into the previous one when it starts before that
    /// cue ends resolves whole chains of collisions in a single pass: the running cue's end only
    /// grows, so a third cue colliding with the merged pair is absorbed too.
    private static func merge(_ drafts: [Draft]) -> [Draft] {
        let ordered = drafts.enumerated()
            .sorted { left, right in
                if left.element.startMs != right.element.startMs { return left.element.startMs < right.element.startMs }
                if left.element.endMs != right.element.endMs { return left.element.endMs < right.element.endMs }
                return left.offset < right.offset
            }
            .map(\.element)

        var merged: [Draft] = []
        for draft in ordered {
            guard var running = merged.last, draft.startMs < running.endMs else {
                merged.append(draft)
                continue
            }
            running.endMs = max(running.endMs, draft.endMs)
            running.blocks = combine(running.blocks, with: draft.blocks)
            running.flags.formUnion(draft.flags)
            running.flags.insert(.overlapMerged)
            merged[merged.count - 1] = running
        }
        return merged
    }

    /// Folds incoming blocks into the running cue, one block per speaker in order of first
    /// appearance, so each speaker in a collision is prefixed exactly once.
    private static func combine(_ blocks: [DraftBlock], with incoming: [DraftBlock]) -> [DraftBlock] {
        var combined = blocks
        for block in incoming {
            if let existing = combined.firstIndex(where: { $0.speakerKey == block.speakerKey }) {
                combined[existing].append(block)
            } else {
                combined.append(block)
            }
        }
        return combined
    }

    // MARK: - Numbering and review flags

    private static func finish(_ drafts: [Draft], targets: SubtitleReadabilityTargets) -> [SubtitleCue] {
        drafts.enumerated().map { index, draft in
            let blocks = draft.blocks.map { block -> SubtitleCueBlock in
                let text = block.texts.joined(separator: " ")
                return SubtitleCueBlock(
                    speakerLabel: block.label,
                    text: text,
                    lines: SubtitleTextWrapper.lines(for: prefixed(text, label: block.label), width: targets.maximumCharactersPerLine),
                    parentSegmentIDs: block.parentSegmentIDs
                )
            }
            var flags = draft.flags
            let lines = blocks.flatMap(\.lines)
            if lines.count > targets.maximumLines { flags.insert(.tooManyLines) }
            if lines.contains(where: { $0.count > targets.maximumCharactersPerLine }) { flags.insert(.lineTooLong) }
            let duration = draft.endMs - draft.startMs
            if duration < targets.minimumDurationMs { flags.insert(.durationBelowTarget) }
            if duration > targets.maximumDurationMs { flags.insert(.durationAboveTarget) }
            return SubtitleCue(
                number: index + 1,
                startMs: draft.startMs,
                endMs: draft.endMs,
                blocks: blocks,
                reviewFlags: flags.sorted()
            )
        }
    }

    // MARK: - Measuring

    private static func needsSplitting(text: String, label: String, durationMs: Int, targets: SubtitleReadabilityTargets) -> Bool {
        durationMs > targets.maximumDurationMs || !fits(text: text, label: label, targets: targets)
    }

    /// Whether one speaker's text reads within the line targets once it carries its prefix.
    private static func fits(text: String, label: String, targets: SubtitleReadabilityTargets) -> Bool {
        let lines = SubtitleTextWrapper.lines(for: prefixed(text, label: label), width: targets.maximumCharactersPerLine)
        return lines.count <= targets.maximumLines && !lines.contains { $0.count > targets.maximumCharactersPerLine }
    }

    /// SRT has no speaker field, so the label is part of the text on every cue.
    private static func prefixed(_ text: String, label: String) -> String { "\(label): \(text)" }

    private static func joined(_ words: [TimedWord]) -> String {
        normalized(words.map(\.text).joined(separator: " "))
    }

    /// Collapses the whitespace a cue cannot show, without touching the words themselves.
    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: - Work in progress

    private struct DraftBlock {
        /// Groups a speaker's turns within one merged cue. Unassignable speech has no speaker id,
        /// so it groups by the label the assembler gave it.
        let speakerKey: String
        let label: String
        var texts: [String]
        var parentSegmentIDs: [String]

        init(segment: TranscriptSegment, label: String, text: String) {
            speakerKey = segment.speakerID.map { "id:" + $0 } ?? "label:" + label
            self.label = label
            texts = [text]
            parentSegmentIDs = [segment.id]
        }

        mutating func append(_ other: DraftBlock) {
            texts.append(contentsOf: other.texts)
            for id in other.parentSegmentIDs where !parentSegmentIDs.contains(id) {
                parentSegmentIDs.append(id)
            }
        }
    }

    private struct Draft {
        var startMs: Int
        var endMs: Int
        var blocks: [DraftBlock]
        var flags: Set<SubtitleReviewFlag>

        func flagged(_ flag: SubtitleReviewFlag) -> Draft {
            var copy = self
            copy.flags.insert(flag)
            return copy
        }
    }
}
