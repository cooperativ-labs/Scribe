import Foundation
#if canImport(ScribeAppCore)
import ScribeAppCore
#endif

/// Source evidence supplements diarization; it never reassigns a known word.
public struct SourceEnergyPrior: Sendable {
    public static let provenance = "microphone-speaker-prior-v1"
    public struct Selection: Sendable, Equatable {
        public let speakerID: String
        public let agreement: Double
        public let microphoneCoverage: Double
        public let evidenceMs: Int
    }
    public let timeline: SourceEnergyTimeline
    public let selection: Selection

    /// Conservative calibration parameters: at least 5 s, >95% source purity,
    /// >60% of microphone-only speech, and a 20-point lead over another cluster.
    public init?(timeline: SourceEnergyTimeline, intervals: [AcousticSpeakerInterval], minimumAgreement: Double = 0.95) {
        guard timeline.isValid else { return nil }
        let mapped = Self.canonicalIntervals(intervals)
        var mic: [String: Int] = [:], sys: [String: Int] = [:]
        var totalMic = 0
        for window in timeline.windows where window.microphoneDominant || window.systemDominant {
            if window.microphoneDominant { totalMic += window.endMs - window.startMs }
            let hits = mapped.filter { $0.startMs < window.endMs && $0.endMs > window.startMs }
            let ids = Set(hits.map(\.speakerID))
            guard ids.count == 1, let id = ids.first, !hits.contains(where: \.overlapsAnotherSpeaker) else { continue }
            // Count a bin at most once even if the diarizer repeats an interval.
            let covered = Self.unionCoverage(hits.map { (max(window.startMs, $0.startMs), min(window.endMs, $0.endMs)) })
            if window.microphoneDominant { mic[id, default: 0] += covered }
            else { sys[id, default: 0] += covered }
        }
        let candidates = mic.map { id, duration in
            Selection(speakerID: id, agreement: Double(duration) / Double(duration + (sys[id] ?? 0)),
                      microphoneCoverage: Double(duration) / Double(max(1, totalMic)), evidenceMs: duration)
        }.sorted {
            if $0.agreement != $1.agreement { return $0.agreement > $1.agreement }
            if $0.evidenceMs != $1.evidenceMs { return $0.evidenceMs > $1.evidenceMs }
            return $0.speakerID < $1.speakerID
        }
        guard let best = candidates.first, best.evidenceMs >= 5_000,
              best.agreement > minimumAgreement, best.microphoneCoverage > 0.6,
              best.agreement - (candidates.dropFirst().first?.agreement ?? 0) >= 0.2 else { return nil }
        self.timeline = timeline
        selection = best
    }

    /// Fraction of a range covered by unambiguous source evidence. Double-talk,
    /// gaps and silence contribute no evidence, including partially covered tails.
    public func support(startMs: Int, endMs: Int, microphone: Bool = true) -> Double {
        guard startMs >= 0, endMs > startMs else { return 0 }
        let lo = min(timeline.windows.count, startMs / 100)
        let hi = min(timeline.windows.count, (endMs + 99) / 100)
        guard lo < hi else { return 0 }
        let covered = timeline.windows[lo..<hi].reduce(0) { total, window in
            total + ((microphone ? window.microphoneDominant : window.systemDominant)
                     ? max(0, min(endMs, window.endMs) - max(startMs, window.startMs)) : 0)
        }
        return Double(covered) / Double(endMs - startMs)
    }

    public func confidenceAdjusted(_ segment: TranscriptSegment) -> TranscriptSegment {
        guard segment.attributionSource != .manual, !segment.overlap,
              let id = segment.effectiveSpeakerID, let base = segment.speakerConfidence else { return segment }
        let words = segment.words ?? []
        let ranges = words.isEmpty ? [(segment.startMs, segment.endMs)] : words.map { ($0.startMs, $0.endMs) }
        let confidence = ranges.map { start, end in
            let mic = support(startMs: start, endMs: end)
            let sys = support(startMs: start, endMs: end, microphone: false)
            let agrees = id == selection.speakerID ? mic : sys
            let conflicts = id == selection.speakerID ? sys : mic
            return max(0, min(1, base + 0.25 * agrees * (1 - base) - 0.5 * conflicts * base))
        }.min() ?? base
        return TranscriptSegment(id: segment.id, speakerID: segment.speakerID, speakerLabel: segment.speakerLabel,
                                 startMs: segment.startMs, endMs: segment.endMs, text: segment.text, overlap: segment.overlap,
                                 timingQuality: segment.timingQuality, speakerConfidence: confidence, words: segment.words,
                                 attributionSource: segment.attributionSource, speakerInference: segment.speakerInference,
                                 unresolvedSpeakerEvidence: segment.unresolvedSpeakerEvidence)
    }

    static func canonicalIntervals(_ intervals: [AcousticSpeakerInterval]) -> [AcousticSpeakerInterval] {
        var ids: [String: String] = [:]
        for (_, interval) in intervals.enumerated().sorted(by: {
            if $0.element.startMs != $1.element.startMs { return $0.element.startMs < $1.element.startMs }
            if $0.element.endMs != $1.element.endMs { return $0.element.endMs < $1.element.endMs }
            return $0.offset < $1.offset
        }) where ids[interval.speakerID] == nil {
            ids[interval.speakerID] = "speaker_\(ids.count + 1)"
        }
        return intervals.map { .init(speakerID: ids[$0.speakerID]!, startMs: $0.startMs, endMs: $0.endMs,
                                     overlapsAnotherSpeaker: $0.overlapsAnotherSpeaker, qualityScore: $0.qualityScore) }
    }

    private static func unionCoverage(_ ranges: [(Int, Int)]) -> Int {
        var end = -1, total = 0
        for range in ranges.sorted(by: { $0.0 < $1.0 }) {
            total += max(0, range.1 - max(end, range.0))
            end = max(end, range.1)
        }
        return total
    }
}
