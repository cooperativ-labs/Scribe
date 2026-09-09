import Foundation

/// Groups already-attributed words into readable display paragraphs.
///
/// Speaker identity is an input, not a decision this type makes. Subtitle cue
/// generation is a later, independent pass over the resulting canonical
/// segments. A new row is required for a speaker or unknown transition, a real
/// pause, a hard length/duration cap, or an unknown sentence boundary. For a
/// known speaker, sentence-final punctuation is only a preferred break once a
/// paragraph is already long enough.
public struct TranscriptDisplayGrouper: Sendable {
    public struct Configuration: Sendable, Equatable {
        /// A gap this long is a real pause and always starts a new paragraph.
        public var pauseSplitMs: Int
        /// Once a paragraph reaches this duration, the next sentence boundary is
        /// a preferred row break.
        public var preferredSegmentDurationMs: Int
        /// Once a paragraph reaches this many words, the next sentence boundary
        /// is a preferred row break.
        public var preferredWordCount: Int
        /// A hard cap: even mid-sentence speech splits at a word boundary here.
        public var maximumSegmentDurationMs: Int
        /// A hard cap on words in one display paragraph.
        public var maximumWordCount: Int

        public init(
            pauseSplitMs: Int = 1_000,
            preferredSegmentDurationMs: Int = 12_000,
            preferredWordCount: Int = 40,
            maximumSegmentDurationMs: Int = 30_000,
            maximumWordCount: Int = 80
        ) {
            self.pauseSplitMs = pauseSplitMs
            self.preferredSegmentDurationMs = preferredSegmentDurationMs
            self.preferredWordCount = preferredWordCount
            self.maximumSegmentDurationMs = maximumSegmentDurationMs
            self.maximumWordCount = maximumWordCount
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public var isValid: Bool {
        configuration.pauseSplitMs >= 0
            && configuration.preferredSegmentDurationMs > 0
            && configuration.preferredWordCount > 0
            && configuration.maximumSegmentDurationMs > 0
            && configuration.maximumWordCount > 0
            && configuration.preferredSegmentDurationMs <= configuration.maximumSegmentDurationMs
            && configuration.preferredWordCount <= configuration.maximumWordCount
    }

    /// Whether `next` may continue the open display paragraph.
    ///
    /// A known speaker never joins an unknown span. Consecutive unknown words may
    /// group only while they look like one unattributed fragment: a sentence
    /// boundary is treated as a missing-identity split, because `nil == nil` is
    /// not evidence that two unknown sentences were the same person.
    public func shouldContinue(
        currentSpeakerID: String?,
        currentStartMs: Int,
        currentEndMs: Int,
        currentWordCount: Int,
        lastText: String,
        nextSpeakerID: String?,
        nextStartMs: Int,
        nextEndMs: Int
    ) -> Bool {
        guard currentSpeakerID == nextSpeakerID else { return false }
        guard nextStartMs - currentEndMs < configuration.pauseSplitMs else { return false }
        guard nextEndMs - currentStartMs <= configuration.maximumSegmentDurationMs else { return false }
        guard currentWordCount < configuration.maximumWordCount else { return false }
        if endsSentence(lastText) {
            if currentSpeakerID == nil { return false }
            let currentDuration = currentEndMs - currentStartMs
            if currentDuration >= configuration.preferredSegmentDurationMs
                || currentWordCount >= configuration.preferredWordCount {
                return false
            }
        }
        return true
    }

    public func endsSentence(_ text: String) -> Bool {
        let terminalCharacters = CharacterSet(charactersIn: ".?!")
        return text.unicodeScalars.reversed().first.map { terminalCharacters.contains($0) } ?? false
    }
}
