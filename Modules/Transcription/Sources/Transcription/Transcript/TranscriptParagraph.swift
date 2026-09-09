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
    public let containsInferredAttribution: Bool

    public var sourceSegmentCount: Int { sourceSegmentIDs.count }

    public var hasLowSpeakerConfidence: Bool {
        guard let speakerConfidence else { return false }
        return speakerConfidence < TranscriptSegment.lowSpeakerConfidence
    }

    public var needsReview: Bool {
        speakerID == nil || containsInferredAttribution || hasLowSpeakerConfidence || overlap || timingQuality == .segmentOnly
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
        sourceSegmentIDs: [TranscriptSegment.ID],
        containsInferredAttribution: Bool = false
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
        self.containsInferredAttribution = containsInferredAttribution
    }
}

/// Groups consecutive canonical segments into reading paragraphs.
///
/// Paragraph boundaries are a reading decision, not the canonical segmentation
/// decision. `TranscriptDisplayGrouper` still owns canonical rows and subtitle
/// timing; this type only chooses where a reader wants a break inside one
/// continuous speaker turn.
///
/// Speaker identity is an input: a speaker change, including a known/unknown
/// transition, always starts a new paragraph. Unknown spans are not treated as
/// one speaker — `nil == nil` is not evidence of identity, so an unknown
/// sentence boundary still splits, and unknown fragments keep the tighter pause
/// limit. An overlap transition also splits, so overlapping speech stays
/// visible instead of being absorbed into clean speech.
public struct TranscriptParagraphGrouper: Sendable {
    /// Where a reading paragraph is allowed to end.
    ///
    /// Within a continuous turn the preference order is: a sentence ending, then
    /// a meaningful pause, then a hard cap. Short connected sentences below
    /// `minimumWordCount` stay together; a long passage breaks at the first
    /// sentence ending past it, so paragraphs normally land in the 40-80 word
    /// reading range.
    public struct Configuration: Sendable, Equatable {
        /// A pause at a sentence ending that closes the paragraph.
        public var sentencePauseMs: Int
        /// Any gap this long closes the paragraph, even mid-sentence.
        public var hardPauseMs: Int
        /// The pause limit for an unresolved span. Unknown fragments only join
        /// while they read as one interrupted phrase.
        public var unknownPauseMs: Int
        /// A sentence ending below this many words is not a break, so short
        /// connected sentences stay in one paragraph.
        public var minimumWordCount: Int
        /// A hard cap: speech splits at a segment boundary here even mid-sentence.
        public var maximumWordCount: Int
        /// A hard cap on paragraph duration.
        public var maximumDurationMs: Int

        public init(
            sentencePauseMs: Int = 1_500,
            hardPauseMs: Int = 2_500,
            unknownPauseMs: Int = 1_000,
            minimumWordCount: Int = 40,
            maximumWordCount: Int = 110,
            maximumDurationMs: Int = 60_000
        ) {
            self.sentencePauseMs = sentencePauseMs
            self.hardPauseMs = hardPauseMs
            self.unknownPauseMs = unknownPauseMs
            self.minimumWordCount = minimumWordCount
            self.maximumWordCount = maximumWordCount
            self.maximumDurationMs = maximumDurationMs
        }
    }

    public let configuration: Configuration
    private let sentences: TranscriptDisplayGrouper

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        sentences = TranscriptDisplayGrouper()
    }

    public var isValid: Bool {
        configuration.sentencePauseMs >= 0
            && configuration.hardPauseMs >= configuration.sentencePauseMs
            && configuration.unknownPauseMs >= 0
            && configuration.minimumWordCount > 0
            && configuration.maximumWordCount >= configuration.minimumWordCount
            && configuration.maximumDurationMs > 0
    }

    public func paragraphs(from segments: [TranscriptSegment]) -> [TranscriptParagraph] {
        let chronological = segments.sorted { ($0.startMs, $0.endMs, $0.id) < ($1.startMs, $1.endMs, $1.id) }
        var drafts: [Draft] = []
        for segment in chronological {
            if var current = drafts.last, canAppend(segment, to: current) {
                current.append(segment)
                drafts[drafts.count - 1] = current
            } else {
                drafts.append(Draft(segment: segment))
            }
        }
        return drafts.map { $0.paragraph() }
    }

    /// Whether `next` may continue the open paragraph.
    private func canAppend(_ next: TranscriptSegment, to current: Draft) -> Bool {
        // Identity is never a paragraph decision.
        guard current.groupingSpeakerID == next.effectiveSpeakerID else { return false }
        // Overlapping speech stays its own paragraph so the marker keeps meaning.
        guard current.overlap == next.overlap else { return false }
        // Hard caps apply to every span.
        guard current.wordCount + next.storedWordCount <= configuration.maximumWordCount else { return false }
        guard next.endMs - current.startMs <= configuration.maximumDurationMs else { return false }

        let gap = next.startMs - current.endMs
        let endsSentence = sentences.endsSentence(current.lastText)

        guard current.groupingSpeakerID != nil else {
            // An unresolved span is not one speaker. Fragments of a single
            // interrupted phrase may join; a finished sentence never does.
            if endsSentence { return false }
            return gap < configuration.unknownPauseMs
        }

        guard gap < configuration.hardPauseMs else { return false }
        if endsSentence {
            if gap >= configuration.sentencePauseMs { return false }
            if current.wordCount >= configuration.minimumWordCount { return false }
        }
        return true
    }

    private struct Draft {
        var groupingSpeakerID: String?
        var startMs: Int
        var endMs: Int
        var wordCount: Int
        var lastText: String
        var overlap: Bool
        var sources: [TranscriptSegment]

        init(segment: TranscriptSegment) {
            groupingSpeakerID = segment.effectiveSpeakerID
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
            let confirmed = sources.first { $0.speakerID != nil }
            let inferred = sources.first { $0.hasInferredSpeaker }?.speakerInference
            let containsInferred = sources.contains { $0.hasInferredSpeaker }
            return TranscriptParagraph(
                id: "paragraph:" + sourceIDs.joined(separator: "+"),
                speakerID: confirmed?.speakerID ?? inferred?.speakerID,
                speakerLabel: confirmed?.speakerLabel ?? inferred?.speakerLabel ?? sources[0].speakerLabel,
                startMs: startMs,
                endMs: endMs,
                text: sources.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " "),
                overlap: overlap,
                timingQuality: Self.timingQuality(of: sources),
                speakerConfidence: confidences.min(),
                words: Self.joinedWords(from: sources),
                sourceSegmentIDs: sourceIDs,
                containsInferredAttribution: containsInferred
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
