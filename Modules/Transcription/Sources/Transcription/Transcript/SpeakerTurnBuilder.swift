import Foundation

/// Converts recognized words and recording-wide diarization intervals into chronological transcript turns.
///
/// The diarizer's speaker IDs are intentionally only an input detail. The resulting canonical IDs are
/// assigned as `speaker_1`, `speaker_2`, and so on when a diarized speaker first receives text.
public struct SpeakerTurnBuilder: Sendable {
    public struct Configuration: Sendable, Equatable {
        /// A candidate needs both this many milliseconds and this fraction of the word interval.
        public var minimumOverlapMs: Int
        public var minimumOverlapRatio: Double
        /// A tie (or near tie) is ambiguous and is represented as the unknown speaker.
        public var minimumLeadMs: Int
        public var pauseSplitMs: Int
        public var maximumSegmentDurationMs: Int

        public init(
            minimumOverlapMs: Int = 50,
            minimumOverlapRatio: Double = 0.5,
            minimumLeadMs: Int = 1,
            pauseSplitMs: Int = 1_000,
            maximumSegmentDurationMs: Int = 30_000
        ) {
            self.minimumOverlapMs = minimumOverlapMs
            self.minimumOverlapRatio = minimumOverlapRatio
            self.minimumLeadMs = minimumLeadMs
            self.pauseSplitMs = pauseSplitMs
            self.maximumSegmentDurationMs = maximumSegmentDurationMs
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func build(
        words: [RecognizedWord],
        diarizedTurns: [DiarizedSpeakerTurn],
        untranscribedSpeech: [UntranscribedSpeechInterval] = []
    ) throws -> SpeakerTurnBuildResult {
        try validateConfiguration()
        let normalizedTurns = try diarizedTurns.map { turn in
            guard !turn.speakerID.isEmpty, turn.startMs >= 0, turn.startMs < turn.endMs else {
                throw Error.invalidDiarizedTurn(turn.speakerID)
            }
            return turn
        }
        let normalizedWords = try words.enumerated().map { index, word in
            guard !word.id.isEmpty, !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  word.enclosingStartMs >= 0, word.enclosingStartMs < word.enclosingEndMs else {
                throw Error.invalidRecognizedWord(word.id)
            }
            switch (word.startMs, word.endMs) {
            case let (.some(start), .some(end)):
                guard word.enclosingStartMs <= start, start < end, end <= word.enclosingEndMs else {
                    throw Error.invalidRecognizedWord(word.id)
                }
                return NormalizedWord(index: index, word: word, startMs: start, endMs: end, hasWordTiming: true)
            case (.none, .none):
                return NormalizedWord(index: index, word: word, startMs: word.enclosingStartMs, endMs: word.enclosingEndMs, hasWordTiming: false)
            default:
                throw Error.invalidRecognizedWord(word.id)
            }
        }
        guard Set(normalizedWords.map(\.word.id)).count == normalizedWords.count else {
            throw Error.duplicateWordID
        }
        try untranscribedSpeech.forEach {
            guard $0.startMs >= 0, $0.startMs < $0.endMs else { throw Error.invalidUntranscribedSpeechInterval }
        }

        let chronologicalWords = normalizedWords.sorted { lhs, rhs in
            if lhs.startMs != rhs.startMs { return lhs.startMs < rhs.startMs }
            if lhs.endMs != rhs.endMs { return lhs.endMs < rhs.endMs }
            return lhs.index < rhs.index
        }
        let attributions = chronologicalWords.map { word in
            attribute(word, using: normalizedTurns)
        }

        // Number clusters from the diarizer's own source-relative timeline, not its arbitrary IDs
        // and not ASR arrival order. A speaker with no recognized words still retains a stable table entry.
        var canonicalSpeakerIDs: [String: String] = [:]
        var speakers: [TranscriptSpeaker] = []
        for (_, turn) in normalizedTurns.enumerated().sorted(by: { lhs, rhs in
            if lhs.element.startMs != rhs.element.startMs { return lhs.element.startMs < rhs.element.startMs }
            if lhs.element.endMs != rhs.element.endMs { return lhs.element.endMs < rhs.element.endMs }
            return lhs.offset < rhs.offset
        }) {
            let diarizedSpeakerID = turn.speakerID
            guard canonicalSpeakerIDs[diarizedSpeakerID] == nil else { continue }
            let ordinal = speakers.count + 1
            let canonicalID = "speaker_\(ordinal)"
            canonicalSpeakerIDs[diarizedSpeakerID] = canonicalID
            speakers.append(TranscriptSpeaker(
                id: canonicalID,
                identityAssignment: .unmatched,
                labelSnapshot: "Speaker \(ordinal)"
            ))
        }

        var drafts: [DraftSegment] = []
        for attribution in attributions {
            let canonicalSpeakerID = attribution.diarizedSpeakerID.flatMap { canonicalSpeakerIDs[$0] }
            if var current = drafts.last, canAppend(attribution, to: current, canonicalSpeakerID: canonicalSpeakerID) {
                current.append(attribution)
                drafts[drafts.count - 1] = current
            } else {
                drafts.append(DraftSegment(attribution: attribution, canonicalSpeakerID: canonicalSpeakerID))
            }
        }

        var assignments: [SpeakerTurnWordAssignment] = []
        let segments = drafts.enumerated().map { index, draft -> TranscriptSegment in
            let segmentID = String(format: "segment_%03d", index + 1)
            assignments.append(contentsOf: draft.attributions.map {
                SpeakerTurnWordAssignment(
                    wordID: $0.word.word.id,
                    segmentID: segmentID,
                    speakerID: draft.canonicalSpeakerID
                )
            })
            return draft.makeSegment(id: segmentID)
        }
        let diagnostics = untranscribedSpeech.map {
            SpeakerTurnDiagnostic.untranscribedSpeech(startMs: $0.startMs, endMs: $0.endMs)
        }
        return SpeakerTurnBuildResult(speakers: speakers, segments: segments, diagnostics: diagnostics, wordAssignments: assignments)
    }

    private func validateConfiguration() throws {
        guard configuration.minimumOverlapMs >= 0,
              (0...1).contains(configuration.minimumOverlapRatio),
              configuration.minimumLeadMs >= 0,
              configuration.pauseSplitMs >= 0,
              configuration.maximumSegmentDurationMs > 0 else { throw Error.invalidConfiguration }
    }

    private func attribute(_ word: NormalizedWord, using turns: [DiarizedSpeakerTurn]) -> Attribution {
        var overlapBySpeaker: [String: Int] = [:]
        for turn in turns {
            let overlap = max(0, min(word.endMs, turn.endMs) - max(word.startMs, turn.startMs))
            guard overlap > 0 else { continue }
            // Multiple overlapping diarizer windows for one cluster must not make it look stronger.
            overlapBySpeaker[turn.speakerID] = max(overlapBySpeaker[turn.speakerID] ?? 0, overlap)
        }
        let orderedCandidates = overlapBySpeaker.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }
        guard let strongest = orderedCandidates.first else {
            return Attribution(word: word, diarizedSpeakerID: nil, overlap: false)
        }
        let requiredOverlap = max(configuration.minimumOverlapMs, Int(ceil(Double(word.endMs - word.startMs) * configuration.minimumOverlapRatio)))
        let runnerUpOverlap = orderedCandidates.dropFirst().first?.value ?? 0
        let hasAdequateEvidence = strongest.value >= requiredOverlap
        // Even when callers allow a zero additional margin, equal evidence remains ambiguous.
        let hasClearWinner = orderedCandidates.count == 1 || strongest.value - runnerUpOverlap > configuration.minimumLeadMs
        return Attribution(
            word: word,
            diarizedSpeakerID: hasAdequateEvidence && hasClearWinner ? strongest.key : nil,
            overlap: orderedCandidates.count > 1
        )
    }

    private func canAppend(_ next: Attribution, to current: DraftSegment, canonicalSpeakerID: String?) -> Bool {
        guard current.canonicalSpeakerID == canonicalSpeakerID,
              !endsSentence(current.attributions.last!.word.word.text),
              next.word.startMs - current.endMs < configuration.pauseSplitMs,
              next.word.endMs - current.startMs <= configuration.maximumSegmentDurationMs else { return false }
        return true
    }

    private func endsSentence(_ text: String) -> Bool {
        let terminalCharacters = CharacterSet(charactersIn: ".?!")
        return text.unicodeScalars.reversed().first.map { terminalCharacters.contains($0) } ?? false
    }

    private struct NormalizedWord: Sendable {
        let index: Int
        let word: RecognizedWord
        let startMs: Int
        let endMs: Int
        let hasWordTiming: Bool
    }

    private struct Attribution: Sendable {
        let word: NormalizedWord
        let diarizedSpeakerID: String?
        let overlap: Bool
    }

    private struct DraftSegment: Sendable {
        let canonicalSpeakerID: String?
        var attributions: [Attribution]
        var startMs: Int
        var endMs: Int

        init(attribution: Attribution, canonicalSpeakerID: String?) {
            self.canonicalSpeakerID = canonicalSpeakerID
            self.attributions = [attribution]
            self.startMs = attribution.word.startMs
            self.endMs = attribution.word.endMs
        }

        mutating func append(_ attribution: Attribution) {
            attributions.append(attribution)
            endMs = max(endMs, attribution.word.endMs)
        }

        func makeSegment(id: String) -> TranscriptSegment {
            let hasOnlyPreciseWordTimings = attributions.allSatisfy { $0.word.hasWordTiming }
            let speakerLabel = canonicalSpeakerID.map { id in
                "Speaker \(id.dropFirst("speaker_".count))"
            } ?? "Unknown speaker"
            let words = hasOnlyPreciseWordTimings ? attributions.map {
                TimedWord(text: $0.word.word.text, startMs: $0.word.startMs, endMs: $0.word.endMs)
            } : nil
            return TranscriptSegment(
                id: id,
                speakerID: canonicalSpeakerID,
                speakerLabel: speakerLabel,
                startMs: startMs,
                endMs: endMs,
                text: join(attributions.map { $0.word.word.text }),
                overlap: attributions.contains(where: \.overlap),
                timingQuality: hasOnlyPreciseWordTimings ? .asrWord : .segmentOnly,
                words: words
            )
        }

        private func join(_ words: [String]) -> String {
            words.reduce("") { partial, word in
                guard !partial.isEmpty else { return word }
                let startsWithClosingPunctuation = word.unicodeScalars.first.map {
                    CharacterSet(charactersIn: ".,;:!?)]}").contains($0)
                } ?? false
                return partial + (startsWithClosingPunctuation ? "" : " ") + word
            }
        }
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidConfiguration
        case invalidDiarizedTurn(String)
        case invalidRecognizedWord(String)
        case duplicateWordID
        case invalidUntranscribedSpeechInterval
    }
}

public struct RecognizedWord: Sendable, Equatable {
    public let id: String
    public let text: String
    public let startMs: Int?
    public let endMs: Int?
    /// The recognized segment that contains this word. It provides honest fallback timing when
    /// decoder word timestamps are unavailable or invalid.
    public let enclosingStartMs: Int
    public let enclosingEndMs: Int

    public init(id: String, text: String, startMs: Int?, endMs: Int?, enclosingStartMs: Int, enclosingEndMs: Int) {
        self.id = id
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
        self.enclosingStartMs = enclosingStartMs
        self.enclosingEndMs = enclosingEndMs
    }
}

public struct DiarizedSpeakerTurn: Sendable, Equatable {
    public let speakerID: String
    public let startMs: Int
    public let endMs: Int

    public init(speakerID: String, startMs: Int, endMs: Int) {
        self.speakerID = speakerID
        self.startMs = startMs
        self.endMs = endMs
    }
}

public struct UntranscribedSpeechInterval: Sendable, Equatable {
    public let startMs: Int
    public let endMs: Int

    public init(startMs: Int, endMs: Int) {
        self.startMs = startMs
        self.endMs = endMs
    }
}

public struct SpeakerTurnBuildResult: Sendable, Equatable {
    public let speakers: [TranscriptSpeaker]
    public let segments: [TranscriptSegment]
    public let diagnostics: [SpeakerTurnDiagnostic]
    /// Traceability for the construction stage; every recognized input word is represented once.
    public let wordAssignments: [SpeakerTurnWordAssignment]
}

public struct SpeakerTurnWordAssignment: Sendable, Equatable {
    public let wordID: String
    public let segmentID: String
    public let speakerID: String?
}

public enum SpeakerTurnDiagnostic: Sendable, Equatable {
    case untranscribedSpeech(startMs: Int, endMs: Int)
}
