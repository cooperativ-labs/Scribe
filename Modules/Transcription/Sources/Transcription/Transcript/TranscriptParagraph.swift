import Foundation

/// A reading-oriented paragraph derived from canonical segments.
///
/// Paragraphs are a presentation grouping only. They do not replace, rewrite, or
/// persist canonical segments, speaker assignments, words, timestamps, or edits.
/// Each paragraph keeps an ordered mapping back to the source segment IDs it
/// was built from.
public struct TranscriptParagraph: Identifiable, Equatable, Sendable {
    public let id: String
    public let speakerID: String?
    public let speakerLabel: String
    public let startMs: Int
    public let endMs: Int
    public let text: String
    public let overlap: Bool
    public let timingQuality: TranscriptTimingQuality
    public let speakerConfidence: Double?
    public let words: [TimedWord]?
    public let sourceSegmentIDs: [TranscriptSegment.ID]

    public var sourceSegmentCount: Int { sourceSegmentIDs.count }

    public var hasLowSpeakerConfidence: Bool {
        guard let speakerConfidence else { return false }
        return speakerConfidence < TranscriptSegment.lowSpeakerConfidence
    }

    public var needsReview: Bool {
        speakerID == nil || hasLowSpeakerConfidence || overlap || timingQuality == .segmentOnly
    }

    public init(
        id: String,
        speakerID: String?,
        speakerLabel: String,
        startMs: Int,
        endMs: Int,
        text: String,
        overlap: Bool,
        timingQuality: TranscriptTimingQuality,
        speakerConfidence: Double?,
        words: [TimedWord]?,
        sourceSegmentIDs: [TranscriptSegment.ID]
    ) {
        self.id = id
        self.speakerID = speakerID
        self.speakerLabel = speakerLabel
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.overlap = overlap
        self.timingQuality = timingQuality
        self.speakerConfidence = speakerConfidence
        self.words = words
        self.sourceSegmentIDs = sourceSegmentIDs
    }
}

/// Groups consecutive canonical segments into reading paragraphs.
///
/// Uses the same sentence-aware pause and length limits as
/// `TranscriptDisplayGrouper`. Speaker identity is an input: a speaker change,
/// including a known/unknown transition, always starts a new paragraph. Unknown
/// spans are not treated as one speaker — `nil == nil` is not evidence of
/// identity, so an unknown sentence boundary still splits.
public struct TranscriptParagraphGrouper: Sendable {
    public let configuration: TranscriptDisplayGrouper.Configuration

    public init(configuration: TranscriptDisplayGrouper.Configuration = TranscriptDisplayGrouper.Configuration()) {
        self.configuration = configuration
    }

    public func paragraphs(from segments: [TranscriptSegment]) -> [TranscriptParagraph] {
        let chronological = segments.sorted { ($0.startMs, $0.endMs, $0.id) < ($1.startMs, $1.endMs, $1.id) }
        var drafts: [Draft] = []
        let displayGrouper = TranscriptDisplayGrouper(configuration: configuration)
        for segment in chronological {
            if var current = drafts.last, canAppend(segment, to: current, using: displayGrouper) {
                current.append(segment)
                drafts[drafts.count - 1] = current
            } else {
                drafts.append(Draft(segment: segment))
            }
        }
        return drafts.map { $0.paragraph() }
    }

    private func canAppend(
        _ next: TranscriptSegment,
        to current: Draft,
        using displayGrouper: TranscriptDisplayGrouper
    ) -> Bool {
        let nextWordCount = next.storedWordCount
        guard current.wordCount + nextWordCount <= configuration.maximumWordCount else { return false }
        return displayGrouper.shouldContinue(
            currentSpeakerID: current.speakerID,
            currentStartMs: current.startMs,
            currentEndMs: current.endMs,
            currentWordCount: current.wordCount,
            lastText: current.lastText,
            nextSpeakerID: next.speakerID,
            nextStartMs: next.startMs,
            nextEndMs: next.endMs
        )
    }

    private struct Draft {
        var speakerID: String?
        var speakerLabel: String
        var startMs: Int
        var endMs: Int
        var wordCount: Int
        var lastText: String
        var overlap: Bool
        var sources: [TranscriptSegment]

        init(segment: TranscriptSegment) {
            speakerID = segment.speakerID
            speakerLabel = segment.speakerLabel
            startMs = segment.startMs
            endMs = segment.endMs
            wordCount = segment.storedWordCount
            lastText = segment.lastStoredWordText
            overlap = segment.overlap
            sources = [segment]
        }

        mutating func append(_ segment: TranscriptSegment) {
            endMs = max(endMs, segment.endMs)
            wordCount += segment.storedWordCount
            lastText = segment.lastStoredWordText
            overlap = overlap || segment.overlap
            sources.append(segment)
        }

        func paragraph() -> TranscriptParagraph {
            let sourceIDs = sources.map(\.id)
            let confidences = sources.compactMap(\.speakerConfidence)
            return TranscriptParagraph(
                id: "paragraph:" + sourceIDs.joined(separator: "+"),
                speakerID: speakerID,
                speakerLabel: speakerLabel,
                startMs: startMs,
                endMs: endMs,
                text: sources.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " "),
                overlap: overlap,
                timingQuality: Self.timingQuality(of: sources),
                speakerConfidence: confidences.min(),
                words: Self.joinedWords(from: sources),
                sourceSegmentIDs: sourceIDs
            )
        }

        private static func joinedWords(from sources: [TranscriptSegment]) -> [TimedWord]? {
            let timed = sources.flatMap { $0.words ?? [] }
            guard !timed.isEmpty else { return nil }
            return timed
        }

        private static func timingQuality(of sources: [TranscriptSegment]) -> TranscriptTimingQuality {
            if sources.contains(where: { $0.timingQuality == .segmentOnly }) { return .segmentOnly }
            if sources.contains(where: { $0.timingQuality == .forcedAligned }) { return .forcedAligned }
            return .asrWord
        }
    }
}

extension TranscriptSegment {
    /// Count of stored word timings, or whitespace tokens when timings were dropped.
    var storedWordCount: Int {
        if let words, !words.isEmpty { return words.count }
        return text.split(whereSeparator: \.isWhitespace).count
    }

    var lastStoredWordText: String {
        if let words, let last = words.last { return last.text }
        return text.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? text
    }
}
