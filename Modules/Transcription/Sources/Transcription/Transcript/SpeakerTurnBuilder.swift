import Foundation

/// Converts recognized words and recording-wide diarization intervals into chronological transcript turns.
///
/// Attribution (who spoke each word) is independent of display grouping (how those
/// words become readable paragraphs) and of subtitle cue generation. The diarizer's
/// speaker IDs are only an input detail; canonical IDs are assigned as `speaker_1`,
/// `speaker_2`, and so on when a diarized speaker first appears on the timeline.
public struct SpeakerTurnBuilder: Sendable {
    public static let attributionProvenance = "speaker-turn-attribution-v3"
    public static let groupingProvenance = "speaker-turn-grouping-v2"
    public static let confidenceProvenance = "word-overlap-margin-v1"
    public static let exclusiveTimelineProvenance = "interval-extension-quality-v1"

    public struct Configuration: Sendable, Equatable {
        /// A candidate needs both this many milliseconds and this fraction of the word interval.
        public var minimumOverlapMs: Int
        public var minimumOverlapRatio: Double
        /// Minimum overlap lead; ambiguous words may use their phrase's dominant speaker.
        public var minimumLeadMs: Int
        /// Display-paragraph grouping. Does not change speaker identity.
        public var grouping: TranscriptDisplayGrouper.Configuration

        public init(
            minimumOverlapMs: Int = 50,
            minimumOverlapRatio: Double = 0.5,
            minimumLeadMs: Int = 1,
            grouping: TranscriptDisplayGrouper.Configuration = TranscriptDisplayGrouper.Configuration()
        ) {
            self.minimumOverlapMs = minimumOverlapMs
            self.minimumOverlapRatio = minimumOverlapRatio
            self.minimumLeadMs = minimumLeadMs
            self.grouping = grouping
        }

        /// Convenience for the historical flat grouping knobs used by tests and assembly.
        public init(
            minimumOverlapMs: Int = 50,
            minimumOverlapRatio: Double = 0.5,
            minimumLeadMs: Int = 1,
            pauseSplitMs: Int,
            maximumSegmentDurationMs: Int
        ) {
            self.init(
                minimumOverlapMs: minimumOverlapMs,
                minimumOverlapRatio: minimumOverlapRatio,
                minimumLeadMs: minimumLeadMs,
                grouping: TranscriptDisplayGrouper.Configuration(
                    pauseSplitMs: pauseSplitMs,
                    maximumSegmentDurationMs: maximumSegmentDurationMs
                )
            )
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
        let attributionTurns = exclusiveTimeline(from: normalizedTurns)
        var phrases: [[NormalizedWord]] = []
        for word in chronologicalWords {
            if let last = phrases.last?.last,
               last.word.enclosingStartMs == word.word.enclosingStartMs,
               last.word.enclosingEndMs == word.word.enclosingEndMs,
               word.startMs - last.endMs < configuration.grouping.pauseSplitMs {
                phrases[phrases.count - 1].append(word)
            } else {
                phrases.append([word])
            }
        }
        let attributions = phrases.flatMap { phrase in
            var totals: [String: Int] = [:]
            for word in phrase {
                for (speaker, overlap) in overlaps(for: word, using: attributionTurns) {
                    totals[speaker, default: 0] += overlap
                }
            }
            let ranked = totals.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            let phraseSpeaker = ranked.first.flatMap { best in
                best.value - (ranked.dropFirst().first?.value ?? 0) > configuration.minimumLeadMs ? best.key : nil
            }
            return phrase.map { attribute($0, using: attributionTurns, canonicalTurns: normalizedTurns, phraseSpeaker: phraseSpeaker) }
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
                    speakerID: draft.attributions.first?.nearestDistanceMs == nil ? draft.canonicalSpeakerID : nil
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
              TranscriptDisplayGrouper(configuration: configuration.grouping).isValid else { throw Error.invalidConfiguration }
    }

    private func attribute(
        _ word: NormalizedWord,
        using turns: [DiarizedSpeakerTurn],
        canonicalTurns: [DiarizedSpeakerTurn],
        phraseSpeaker: String?
    ) -> Attribution {
        let overlapBySpeaker = overlaps(for: word, using: turns)
        let orderedCandidates = overlapBySpeaker.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }
        let canonicalSpeakerCount = Set(canonicalTurns.filter {
            Self.overlapMs(startA: word.startMs, endA: word.endMs, startB: $0.startMs, endB: $0.endMs) > 0
        }.map(\.speakerID)).count
        let wordDuration = word.endMs - word.startMs
        let requiredOverlap = max(configuration.minimumOverlapMs, Int(ceil(Double(wordDuration) * configuration.minimumOverlapRatio)))
        let strongest = orderedCandidates.first
        let runnerUp = orderedCandidates.dropFirst().first?.value ?? 0
        let confidence = min(1, max(0, Double((strongest?.value ?? 0) - runnerUp) / Double(wordDuration)))
        let adequate = (strongest?.value ?? 0) >= requiredOverlap && strongest != nil
        var speaker: String?
        var distance: Int?
        if adequate, let strongest {
            // Phrase context resolves marginal boundaries; a real word-level turn
            // needs more than a 20% duration lead over the other speaker.
            let overrideLead = max(configuration.minimumLeadMs, Int(ceil(Double(wordDuration) * 0.2)))
            if strongest.key == phraseSpeaker || strongest.value - runnerUp > overrideLead {
                speaker = strongest.key
            } else if let phraseSpeaker, (overlapBySpeaker[phraseSpeaker] ?? 0) > 0 {
                speaker = phraseSpeaker
            }
        } else if let nearest = nearestInterval(to: word, using: canonicalTurns) {
            speaker = nearest.speakerID
            distance = nearest.distanceMs
        }
        return Attribution(word: word, diarizedSpeakerID: speaker, overlap: canonicalSpeakerCount > 1,
                           confidence: confidence, nearestDistanceMs: distance)
    }

    private func nearestInterval(to word: NormalizedWord, using turns: [DiarizedSpeakerTurn]) -> (speakerID: String, distanceMs: Int)? {
        let candidates = turns.map { turn in
            (turn: turn, distance: max(0, max(turn.startMs - word.endMs, word.startMs - turn.endMs)))
        }.filter { $0.distance <= 250 }
        guard let distance = candidates.map(\.distance).min() else { return nil }
        let closest = candidates.filter { $0.distance == distance }
        guard Set(closest.map { $0.turn.speakerID }).count == 1, let candidate = closest.first else { return nil }
        let start = min(word.startMs, candidate.turn.endMs)
        let end = max(word.endMs, candidate.turn.startMs)
        guard !turns.contains(where: {
            $0.speakerID != candidate.turn.speakerID && $0.startMs < end && $0.endMs > start
        }) else { return nil }
        return (candidate.turn.speakerID, distance)
    }

    private func overlaps(for word: NormalizedWord, using turns: [DiarizedSpeakerTurn]) -> [String: Int] {
        var overlapBySpeaker: [String: Int] = [:]
        for turn in turns {
            let overlap = max(0, min(word.endMs, turn.endMs) - max(word.startMs, turn.startMs))
            guard overlap > 0 else { continue }
            // The attribution timeline is exclusive, so its disjoint slices can be summed safely.
            overlapBySpeaker[turn.speakerID, default: 0] += overlap
        }
        return overlapBySpeaker
    }

    /// Resolves simultaneous diarizer intervals into a single-owner timeline for attribution.
    /// Original turns remain the source of overlap metadata and the canonical acoustic record.
    private func exclusiveTimeline(from turns: [DiarizedSpeakerTurn]) -> [DiarizedSpeakerTurn] {
        guard turns.count > 1 else { return turns }
        var boundaries = Set(turns.flatMap { [$0.startMs, $0.endMs] })
        for firstIndex in turns.indices {
            for secondIndex in turns.indices where secondIndex > firstIndex {
                let start = max(turns[firstIndex].startMs, turns[secondIndex].startMs)
                let end = min(turns[firstIndex].endMs, turns[secondIndex].endMs)
                if start < end { boundaries.insert(start + (end - start) / 2) }
            }
        }
        let orderedBoundaries = boundaries.sorted()
        var result: [DiarizedSpeakerTurn] = []
        for (start, end) in zip(orderedBoundaries, orderedBoundaries.dropFirst()) where start < end {
            let midpoint = Double(start + end) / 2
            let active = turns.enumerated().filter { _, turn in
                turn.startMs < end && start < turn.endMs
            }
            guard let owner = active.max(by: { lhs, rhs in
                ownershipRank(for: lhs, at: midpoint) < ownershipRank(for: rhs, at: midpoint)
            })?.element else { continue }
            if let previous = result.last,
               previous.speakerID == owner.speakerID,
               previous.endMs == start,
               previous.qualityScore == owner.qualityScore {
                result[result.count - 1] = DiarizedSpeakerTurn(
                    speakerID: owner.speakerID,
                    startMs: previous.startMs,
                    endMs: end,
                    qualityScore: owner.qualityScore
                )
            } else {
                result.append(DiarizedSpeakerTurn(
                    speakerID: owner.speakerID,
                    startMs: start,
                    endMs: end,
                    qualityScore: owner.qualityScore
                ))
            }
        }
        return result
    }

    private func ownershipRank(
        for indexedTurn: (offset: Int, element: DiarizedSpeakerTurn),
        at midpoint: Double
    ) -> OwnershipRank {
        let turn = indexedTurn.element
        let leftExtension = midpoint - Double(turn.startMs)
        let rightExtension = Double(turn.endMs) - midpoint
        return OwnershipRank(
            bilateralExtension: min(leftExtension, rightExtension),
            totalExtension: leftExtension + rightExtension,
            qualityScore: turn.qualityScore,
            inverseInputIndex: -indexedTurn.offset,
            speakerID: turn.speakerID
        )
    }

    private static func overlapMs(startA: Int, endA: Int, startB: Int, endB: Int) -> Int {
        max(0, min(endA, endB) - max(startA, startB))
    }

    private func canAppend(_ next: Attribution, to current: DraftSegment, canonicalSpeakerID: String?) -> Bool {
        // Confirmed and inferred words retain separate canonical attribution.
        // A changing distance alone is not a speaker/paragraph boundary; the
        // segment stores the furthest distance as a conservative evidence bound.
        guard (current.attributions.last?.nearestDistanceMs == nil) == (next.nearestDistanceMs == nil) else { return false }
        return TranscriptDisplayGrouper(configuration: configuration.grouping).shouldContinue(
            currentSpeakerID: current.canonicalSpeakerID,
            currentStartMs: current.startMs,
            currentEndMs: current.endMs,
            currentWordCount: current.attributions.count,
            lastText: current.attributions.last!.word.word.text,
            nextSpeakerID: canonicalSpeakerID,
            nextStartMs: next.word.startMs,
            nextEndMs: next.word.endMs
        )
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
        let confidence: Double
        let nearestDistanceMs: Int?
    }

    private struct OwnershipRank: Comparable {
        let bilateralExtension: Double
        let totalExtension: Double
        let qualityScore: Double
        let inverseInputIndex: Int
        let speakerID: String

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.bilateralExtension != rhs.bilateralExtension { return lhs.bilateralExtension < rhs.bilateralExtension }
            if lhs.totalExtension != rhs.totalExtension { return lhs.totalExtension < rhs.totalExtension }
            if lhs.qualityScore != rhs.qualityScore { return lhs.qualityScore < rhs.qualityScore }
            if lhs.inverseInputIndex != rhs.inverseInputIndex { return lhs.inverseInputIndex < rhs.inverseInputIndex }
            return lhs.speakerID > rhs.speakerID
        }
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
                speakerID: attributions[0].nearestDistanceMs == nil ? canonicalSpeakerID : nil,
                speakerLabel: attributions[0].nearestDistanceMs == nil ? speakerLabel : "Unknown speaker",
                startMs: startMs,
                endMs: endMs,
                text: join(attributions.map { $0.word.word.text }),
                overlap: attributions.contains(where: \.overlap),
                timingQuality: hasOnlyPreciseWordTimings ? .asrWord : .segmentOnly,
                speakerConfidence: attributions.map(\.confidence).min(),
                words: words,
                attributionSource: attributions[0].nearestDistanceMs == nil ? nil : .inferred,
                speakerInference: attributions.compactMap(\.nearestDistanceMs).max().flatMap { distance in
                    canonicalSpeakerID.map { TranscriptSpeakerInference(
                        speakerID: $0, speakerLabel: speakerLabel,
                        evidence: .nearestInterval(distanceMs: distance), provenance: SpeakerTurnBuilder.attributionProvenance
                    ) }
                }
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
    public let qualityScore: Double

    public init(speakerID: String, startMs: Int, endMs: Int, qualityScore: Double = 1) {
        self.speakerID = speakerID
        self.startMs = startMs
        self.endMs = endMs
        self.qualityScore = qualityScore
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
