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
    /// Brief interjections by another speaker. Their text and source IDs remain
    /// separate from the main speaker's text, words, and editing targets.
    /// The grouper emits leaf paragraphs here (never nested asides).
    public let asides: [TranscriptParagraph]

    public var allSourceSegmentIDs: [TranscriptSegment.ID] {
        sourceSegmentIDs + asides.flatMap(\.allSourceSegmentIDs)
    }

    public var sourceSegmentCount: Int { sourceSegmentIDs.count }

    public var hasLowSpeakerConfidence: Bool {
        guard let speakerConfidence else { return false }
        return speakerConfidence < TranscriptSegment.lowSpeakerConfidence
    }

    public var needsReview: Bool {
        speakerID == nil || containsInferredAttribution || hasLowSpeakerConfidence || overlap || timingQuality == .segmentOnly
            || asides.contains(where: \.needsReview)
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
        containsInferredAttribution: Bool = false,
        asides: [TranscriptParagraph] = []
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
        self.asides = asides
    }
}

/// Groups consecutive canonical segments into reading paragraphs.
///
/// Paragraph boundaries are a reading decision, not the canonical segmentation
/// decision. `TranscriptDisplayGrouper` still owns canonical rows and subtitle
/// timing; this type only chooses where a reader wants a break inside one
/// continuous speaker turn.
///
/// Speaker identity is an input: speaker changes start a new paragraph except
/// for bounded backchannels, retained as separate-speaker asides. Unknown spans are not treated as
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
        var index = 0
        while index < chronological.count {
            let segment = chronological[index]
            // Consume the aside and the returning row together: an alternating
            // run cannot accidentally classify the same row twice.
            if index > 0, index + 1 < chronological.count,
               isBackchannel(segment, between: chronological[index - 1], and: chronological[index + 1]),
               var current = drafts.last,
               segment.endMs - current.startMs <= configuration.maximumDurationMs,
               canBridge(chronological[index + 1], to: current) {
                current.asides.append(Draft(segment: segment).paragraph())
                current.append(chronological[index + 1])
                drafts[drafts.count - 1] = current
                index += 2
                continue
            }
            if var current = drafts.last, canAppend(segment, to: current) {
                current.append(segment)
                drafts[drafts.count - 1] = current
            } else {
                drafts.append(Draft(segment: segment))
            }
            index += 1
        }
        return drafts.map { $0.paragraph() }
    }

    private static let backchannels: Set<String> = [
        "yeah", "yes", "yep", "yup", "right", "okay", "ok", "mmhmm", "mmhm",
        "mhm", "uhhuh", "sure", "got it", "exactly", "absolutely", "alright", "all right",
    ]

    private func isBackchannel(_ row: TranscriptSegment, between previous: TranscriptSegment, and next: TranscriptSegment) -> Bool {
        guard let speaker = row.effectiveSpeakerID,
              let surroundingSpeaker = previous.effectiveSpeakerID,
              next.effectiveSpeakerID == surroundingSpeaker, speaker != surroundingSpeaker,
              (1...3).contains(row.storedWordCount),
              (0...1_200).contains(row.endMs - row.startMs),
              row.startMs - previous.endMs < configuration.hardPauseMs,
              next.startMs - row.endMs < configuration.hardPauseMs,
              next.startMs - previous.endMs < configuration.hardPauseMs else { return false }
        let normalized = row.text.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
        }
        let key = String(String.UnicodeScalarView(normalized)).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return row.overlap || Self.backchannels.contains(key)
    }

    /// A backchannel suppresses a soft sentence break, but never a hard cap or
    /// overlap transition in the main speaker's speech.
    private func canBridge(_ next: TranscriptSegment, to current: Draft) -> Bool {
        current.groupingSpeakerID == next.effectiveSpeakerID
            && current.overlap == next.overlap
            && current.wordCount + next.storedWordCount <= configuration.maximumWordCount
            && next.endMs - current.startMs <= configuration.maximumDurationMs
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
        var asides: [TranscriptParagraph] = []

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
                endMs: max(endMs, asides.map(\.endMs).max() ?? endMs),
                text: sources.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " "),
                overlap: overlap,
                timingQuality: Self.timingQuality(of: sources),
                speakerConfidence: confidences.min(),
                words: Self.joinedWords(from: sources),
                sourceSegmentIDs: sourceIDs,
                containsInferredAttribution: containsInferred,
                asides: asides
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
