import Foundation

/// A diarization interval on the source timeline, using canonical speaker IDs
/// after mapping, or the diarizer's cluster IDs before mapping.
public struct AcousticSpeakerInterval: Sendable, Equatable {
    public let speakerID: String
    public let startMs: Int
    public let endMs: Int
    public let overlapsAnotherSpeaker: Bool
    public let qualityScore: Double?

    public init(
        speakerID: String,
        startMs: Int,
        endMs: Int,
        overlapsAnotherSpeaker: Bool = false,
        qualityScore: Double? = nil
    ) {
        self.speakerID = speakerID
        self.startMs = startMs
        self.endMs = endMs
        self.overlapsAnotherSpeaker = overlapsAnotherSpeaker
        self.qualityScore = qualityScore
    }
}

/// Conservative second pass over unknown canonical turns.
///
/// Original `speakerID` values are never rewritten. A short unknown fragment
/// between two turns of the same named speaker is inferred only when diarization
/// timing supports continuity: unique adequate overlap with that speaker, or a
/// short unoccupied hole between that speaker's intervals. Neighbor identity and
/// wording are not evidence. Manual labels are left untouched.
public struct UnknownFragmentReconciler: Sendable {
    public static let provenance = "unknown-fragment-reconciliation-v1"

    public struct Configuration: Sendable, Equatable {
        public var maximumUnknownDurationMs: Int
        public var maximumNeighborGapMs: Int
        public var maximumDiarizationHoleMs: Int
        public var maximumWordCount: Int
        public var minimumOverlapMs: Int
        public var minimumOverlapRatio: Double
        public var minimumIntervalQuality: Double

        public init(
            maximumUnknownDurationMs: Int = 1_000,
            maximumNeighborGapMs: Int = 1_500,
            maximumDiarizationHoleMs: Int = 1_500,
            maximumWordCount: Int = 3,
            minimumOverlapMs: Int = 50,
            minimumOverlapRatio: Double = 0.5,
            minimumIntervalQuality: Double = 0.8
        ) {
            self.maximumUnknownDurationMs = maximumUnknownDurationMs
            self.maximumNeighborGapMs = maximumNeighborGapMs
            self.maximumDiarizationHoleMs = maximumDiarizationHoleMs
            self.maximumWordCount = maximumWordCount
            self.minimumOverlapMs = minimumOverlapMs
            self.minimumOverlapRatio = minimumOverlapRatio
            self.minimumIntervalQuality = minimumIntervalQuality
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func reconcile(
        segments: [TranscriptSegment],
        speakers: [TranscriptSpeaker],
        intervals: [AcousticSpeakerInterval]
    ) -> [TranscriptSegment] {
        let labels = Dictionary(speakers.map { ($0.id, $0.labelSnapshot) }, uniquingKeysWith: { first, _ in first })
        let mapped = mappedIntervals(intervals)
        let chronological = segments.enumerated().sorted { lhs, rhs in
            if lhs.element.startMs != rhs.element.startMs { return lhs.element.startMs < rhs.element.startMs }
            if lhs.element.endMs != rhs.element.endMs { return lhs.element.endMs < rhs.element.endMs }
            return lhs.offset < rhs.offset
        }
        var reconciled = chronological.map(\.element)
        for index in reconciled.indices {
            reconciled[index] = decide(
                at: index,
                in: reconciled,
                intervals: mapped,
                labels: labels
            )
        }
        var byID = Dictionary(uniqueKeysWithValues: reconciled.map { ($0.id, $0) })
        return segments.map { byID.removeValue(forKey: $0.id) ?? $0 }
    }

    /// Loads `diarization.json` from a run directory and applies the pass in
    /// memory. Missing or unreadable diarization leaves the transcript as-is.
    public static func applied(
        to transcript: CanonicalTranscript?,
        in runDirectoryURL: URL,
        fileManager: FileManager = .default
    ) -> CanonicalTranscript? {
        guard let transcript else { return nil }
        let url = runDirectoryURL.appending(path: TranscriptRunArtifact.diarization)
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(DiarizationRecord.self, from: data)
        else { return transcript }
        let intervals = record.acousticIntervals(sourceDurationMs: transcript.source.durationMs)
        let segments = UnknownFragmentReconciler().reconcile(
            segments: transcript.segments,
            speakers: transcript.speakers,
            intervals: intervals
        )
        guard segments != transcript.segments else { return transcript }
        return transcript.replacingSegments(segments)
    }

    // MARK: - Decisions

    private func decide(
        at index: Int,
        in segments: [TranscriptSegment],
        intervals: [AcousticSpeakerInterval],
        labels: [String: String]
    ) -> TranscriptSegment {
        let segment = segments[index]
        guard segment.speakerID == nil, segment.attributionSource != .manual else { return segment }

        let acoustic = classify(segment, using: intervals)
        let unresolved = unresolvedEvidence(acoustic)

        guard let previous = segments[safe: index - 1],
              let next = segments[safe: index + 1],
              let neighborID = previous.speakerID,
              neighborID == next.speakerID,
              isShortFragment(segment, previous: previous, next: next),
              !segment.overlap
        else {
            return segment.withUnresolvedEvidence(unresolved)
        }

        switch acoustic {
        case let .uniqueSpeaker(speakerID, overlapMs):
            guard speakerID == neighborID,
                  !competingSpeaker(in: neighborGap(previous: previous, next: next), otherThan: neighborID, intervals: intervals)
            else {
                return segment.withUnresolvedEvidence(.competingSpeakers)
            }
            return inferred(
                segment,
                speakerID: speakerID,
                labels: labels,
                evidence: .diarizationCoverage,
                overlapMs: overlapMs,
                diarizationHoleMs: nil
            )
        case .noCoverage:
            guard let hole = diarizationHole(
                for: segment,
                previous: previous,
                next: next,
                neighborID: neighborID,
                intervals: intervals
            ),
                hole >= 0,
                hole <= configuration.maximumDiarizationHoleMs,
                !competingSpeaker(
                    in: neighborGap(previous: previous, next: next),
                    otherThan: neighborID,
                    intervals: intervals
                )
            else {
                return segment.withUnresolvedEvidence(unresolved)
            }
            return inferred(
                segment,
                speakerID: neighborID,
                labels: labels,
                evidence: .diarizationBoundaryGap,
                overlapMs: nil,
                diarizationHoleMs: hole
            )
        case .insufficientOverlap, .competingSpeakers:
            return segment.withUnresolvedEvidence(unresolved)
        }
    }

    private func inferred(
        _ segment: TranscriptSegment,
        speakerID: String,
        labels: [String: String],
        evidence: TranscriptSpeakerInferenceEvidence,
        overlapMs: Int?,
        diarizationHoleMs: Int?
    ) -> TranscriptSegment {
        let label = labels[speakerID] ?? segment.speakerLabel
        return segment.withInference(
            TranscriptSpeakerInference(
                speakerID: speakerID,
                speakerLabel: label,
                evidence: evidence,
                provenance: Self.provenance,
                diarizationHoleMs: diarizationHoleMs,
                overlapMs: overlapMs
            )
        )
    }

    private func isShortFragment(
        _ segment: TranscriptSegment,
        previous: TranscriptSegment,
        next: TranscriptSegment
    ) -> Bool {
        let duration = segment.endMs - segment.startMs
        let gap = next.startMs - previous.endMs
        return duration > 0
            && duration <= configuration.maximumUnknownDurationMs
            && gap >= 0
            && gap <= configuration.maximumNeighborGapMs
            && segment.storedWordCount <= configuration.maximumWordCount
    }

    private func neighborGap(previous: TranscriptSegment, next: TranscriptSegment) -> (startMs: Int, endMs: Int) {
        (previous.endMs, next.startMs)
    }

    // MARK: - Acoustic evidence

    private enum AcousticEvidence: Equatable {
        case noCoverage
        case insufficientOverlap(speakerID: String, overlapMs: Int, requiredMs: Int)
        case competingSpeakers
        case uniqueSpeaker(speakerID: String, overlapMs: Int)
    }

    private func classify(_ segment: TranscriptSegment, using intervals: [AcousticSpeakerInterval]) -> AcousticEvidence {
        var overlapBySpeaker: [String: Int] = [:]
        var overlapping: [AcousticSpeakerInterval] = []
        for interval in intervals {
            let overlap = Self.overlapMs(
                startA: segment.startMs,
                endA: segment.endMs,
                startB: interval.startMs,
                endB: interval.endMs
            )
            guard overlap > 0 else { continue }
            overlapping.append(interval)
            overlapBySpeaker[interval.speakerID] = max(overlapBySpeaker[interval.speakerID] ?? 0, overlap)
        }
        if overlapping.contains(where: \.overlapsAnotherSpeaker) || overlapBySpeaker.count > 1 {
            return .competingSpeakers
        }
        guard let strongest = overlapBySpeaker.max(by: { $0.value < $1.value }) else {
            return .noCoverage
        }
        let required = requiredOverlapMs(for: segment)
        if strongest.value < required {
            return .insufficientOverlap(speakerID: strongest.key, overlapMs: strongest.value, requiredMs: required)
        }
        return .uniqueSpeaker(speakerID: strongest.key, overlapMs: strongest.value)
    }

    private func unresolvedEvidence(_ acoustic: AcousticEvidence) -> TranscriptUnresolvedSpeakerEvidence? {
        switch acoustic {
        case .noCoverage: .noCoverage
        case .insufficientOverlap: .insufficientOverlap
        case .competingSpeakers: .competingSpeakers
        case .uniqueSpeaker: nil
        }
    }

    private func requiredOverlapMs(for segment: TranscriptSegment) -> Int {
        let duration = max(1, segment.endMs - segment.startMs)
        let proportional = Int(ceil(Double(duration) * configuration.minimumOverlapRatio))
        return max(configuration.minimumOverlapMs, proportional)
    }

    private func diarizationHole(
        for segment: TranscriptSegment,
        previous: TranscriptSegment,
        next: TranscriptSegment,
        neighborID: String,
        intervals: [AcousticSpeakerInterval]
    ) -> Int? {
        let previousCoverage = intervals.filter {
            $0.speakerID == neighborID
                && !$0.overlapsAnotherSpeaker
                && ($0.qualityScore ?? 1) >= configuration.minimumIntervalQuality
                && Self.overlapMs(
                    startA: previous.startMs,
                    endA: previous.endMs,
                    startB: $0.startMs,
                    endB: $0.endMs
                ) > 0
        }
        let nextCoverage = intervals.filter {
            $0.speakerID == neighborID
                && !$0.overlapsAnotherSpeaker
                && ($0.qualityScore ?? 1) >= configuration.minimumIntervalQuality
                && Self.overlapMs(
                    startA: next.startMs,
                    endA: next.endMs,
                    startB: $0.startMs,
                    endB: $0.endMs
                ) > 0
        }
        guard let previousEnd = previousCoverage.map(\.endMs).max(),
              let nextStart = nextCoverage.map(\.startMs).min()
        else { return nil }
        guard segment.startMs >= previousEnd, segment.endMs <= nextStart else { return nil }
        return nextStart - previousEnd
    }

    private func competingSpeaker(
        in range: (startMs: Int, endMs: Int),
        otherThan speakerID: String,
        intervals: [AcousticSpeakerInterval]
    ) -> Bool {
        intervals.contains { interval in
            interval.speakerID != speakerID
                && Self.overlapMs(
                    startA: range.startMs,
                    endA: range.endMs,
                    startB: interval.startMs,
                    endB: interval.endMs
                ) > 0
        }
    }

    /// Matches `SpeakerTurnBuilder`: first appearance on the diarizer timeline.
    private func mappedIntervals(_ intervals: [AcousticSpeakerInterval]) -> [AcousticSpeakerInterval] {
        var canonicalIDs: [String: String] = [:]
        var ordinal = 0
        for (_, interval) in intervals.enumerated().sorted(by: { lhs, rhs in
            if lhs.element.startMs != rhs.element.startMs { return lhs.element.startMs < rhs.element.startMs }
            if lhs.element.endMs != rhs.element.endMs { return lhs.element.endMs < rhs.element.endMs }
            return lhs.offset < rhs.offset
        }) {
            guard canonicalIDs[interval.speakerID] == nil else { continue }
            ordinal += 1
            canonicalIDs[interval.speakerID] = "speaker_\(ordinal)"
        }
        return intervals.map { interval in
            AcousticSpeakerInterval(
                speakerID: canonicalIDs[interval.speakerID] ?? interval.speakerID,
                startMs: interval.startMs,
                endMs: interval.endMs,
                overlapsAnotherSpeaker: interval.overlapsAnotherSpeaker,
                qualityScore: interval.qualityScore
            )
        }
    }

    static func overlapMs(startA: Int, endA: Int, startB: Int, endB: Int) -> Int {
        max(0, min(endA, endB) - max(startA, startB))
    }
}

extension DiarizationRecord {
    func acousticIntervals(sourceDurationMs: Int) -> [AcousticSpeakerInterval] {
        intervals.compactMap { interval in
            let start = max(0, Int((interval.startSeconds * 1_000).rounded()))
            let end = min(sourceDurationMs, Int((interval.endSeconds * 1_000).rounded()))
            guard start < end else { return nil }
            return AcousticSpeakerInterval(
                speakerID: interval.speakerID,
                startMs: start,
                endMs: end,
                overlapsAnotherSpeaker: interval.overlapsAnotherSpeaker,
                qualityScore: Double(interval.qualityScore)
            )
        }
    }
}

extension CanonicalTranscript {
    func replacingSegments(_ segments: [TranscriptSegment]) -> CanonicalTranscript {
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

extension TranscriptSegment {
    fileprivate func withInference(_ inference: TranscriptSpeakerInference) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            speakerID: speakerID,
            speakerLabel: speakerLabel,
            startMs: startMs,
            endMs: endMs,
            text: text,
            overlap: overlap,
            timingQuality: timingQuality,
            speakerConfidence: speakerConfidence,
            words: words,
            attributionSource: .inferred,
            speakerInference: inference,
            unresolvedSpeakerEvidence: nil
        )
    }

    fileprivate func withUnresolvedEvidence(_ evidence: TranscriptUnresolvedSpeakerEvidence?) -> TranscriptSegment {
        guard let evidence else { return self }
        return TranscriptSegment(
            id: id,
            speakerID: speakerID,
            speakerLabel: speakerLabel,
            startMs: startMs,
            endMs: endMs,
            text: text,
            overlap: overlap,
            timingQuality: timingQuality,
            speakerConfidence: speakerConfidence,
            words: words,
            attributionSource: attributionSource,
            speakerInference: nil,
            unresolvedSpeakerEvidence: evidence
        )
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
