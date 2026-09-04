import Foundation

/// Reconstructs source-relative words from the worker's timed Parakeet tokens.
///
/// Behavior is pinned to FluidAudio v0.12.4 / `docs/feasibility/asr-timing.md`:
/// SentencePiece `▁` (or a leading space after `normalizedTimingToken`) starts a
/// word, punctuation attaches to the preceding lexical word, chunk timestamps are
/// restored from the audio-preparation mapping plus optional chunk offsets, and
/// only tokens that match on text and time are dropped at chunk seams.
public struct TokenTimingReconciler: Sendable {
    public struct Configuration: Sendable, Equatable {
        /// Pinned ChunkProcessor actual-audio window.
        public var modelWindowSeconds: TimeInterval
        /// Pinned chunk overlap.
        public var overlapSeconds: TimeInterval
        /// Pinned left mel/encoder context on chunks after the first.
        public var leftContextSeconds: TimeInterval
        /// `ASRConstants.secondsPerEncoderFrame` (80 ms).
        public var encoderFrameSeconds: TimeInterval
        /// Period, question mark, and exclamation mark in the pinned v3 vocabulary.
        public var punctuationTokenIDs: Set<Int>
        public var specialTokenTexts: Set<String>
        public var sentencePieceWordBoundary: String

        public init(
            modelWindowSeconds: TimeInterval = 14.88,
            overlapSeconds: TimeInterval = 2.0,
            leftContextSeconds: TimeInterval = 0.08,
            encoderFrameSeconds: TimeInterval = 0.08,
            punctuationTokenIDs: Set<Int> = [7883, 7952, 7948],
            specialTokenTexts: Set<String> = ["<blank>", "<pad>"],
            sentencePieceWordBoundary: String = "\u{2581}"
        ) {
            self.modelWindowSeconds = modelWindowSeconds
            self.overlapSeconds = overlapSeconds
            self.leftContextSeconds = leftContextSeconds
            self.encoderFrameSeconds = encoderFrameSeconds
            self.punctuationTokenIDs = punctuationTokenIDs
            self.specialTokenTexts = specialTokenTexts
            self.sentencePieceWordBoundary = sentencePieceWordBoundary
        }

        /// FluidAudio matches seam tokens inside half of the overlap window.
        public var provenDuplicateToleranceSeconds: TimeInterval { overlapSeconds / 2 }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func reconcile(_ request: TokenTimingReconciliationRequest) throws -> TokenTimingReconciliationResult {
        guard request.sourceDurationMs >= 0 else { throw Error.invalidSourceDuration }
        guard request.timeMapping.sourceSampleRate > 0, request.timeMapping.workingSampleRate > 0 else {
            throw Error.invalidTimeMapping
        }
        guard request.workerTranscript.timestampUnit == "seconds" else {
            throw Error.unsupportedTimestampUnit(request.workerTranscript.timestampUnit)
        }

        let streams = workingStreams(from: request.workerTranscript, vocabulary: request.vocabulary)
        let (merged, droppedDuplicates) = merge(streams)
        let mapped = merged.map { token in
            token.mappingTimes { request.timeMapping.sourceTime(forWorkingSeconds: $0) }
        }

        if mapped.isEmpty {
            return fallbackResult(for: request, droppedDuplicates: droppedDuplicates)
        }

        let drafts = joinWords(mapped)
        let recognizedSpan = enclosingSpan(of: drafts, sourceDurationMs: request.sourceDurationMs)
        var warnings: [TranscriptWarning] = []
        let words = drafts.enumerated().map { index, draft -> RecognizedWord in
            let id = String(format: "word_%03d", index + 1)
            let quality = wordTiming(draft, sourceDurationMs: request.sourceDurationMs)
            if quality.timingQuality == .segmentOnly, !draft.text.isEmpty {
                warnings.append(TranscriptWarning(
                    code: quality.warningCode ?? "timing_fallback",
                    message: "Preserved \(id) without fabricating word times.",
                    segmentID: id
                ))
            }
            return RecognizedWord(
                id: id,
                text: draft.text,
                startMs: quality.startMs,
                endMs: quality.endMs,
                enclosingStartMs: recognizedSpan.startMs,
                enclosingEndMs: recognizedSpan.endMs
            )
        }

        let outOfBounds = words.contains { word in
            guard let start = word.startMs, let end = word.endMs else { return false }
            return start < 0 || end > request.sourceDurationMs || start >= end
        }
        if outOfBounds {
            throw Error.wordTimesExceedSourceDuration
        }

        return TokenTimingReconciliationResult(
            words: words,
            droppedDuplicateTokenCount: droppedDuplicates,
            warnings: warnings
        )
    }

    private func workingStreams(
        from transcript: WorkerASRTranscript,
        vocabulary: [Int: String]
    ) -> [[InternalToken]] {
        if let chunks = transcript.chunks, !chunks.isEmpty {
            return chunks
                .sorted { $0.chunkIndex < $1.chunkIndex }
                .map { chunk in
                    let offset = chunk.timesAreAbsolute ? 0 : chunk.chunkStartSeconds
                    return chunk.tokens.compactMap { token in
                        normalize(token, vocabulary: vocabulary, additionalOffset: offset)
                    }
                }
        }
        return [transcript.tokens.compactMap { token in
            normalize(token, vocabulary: vocabulary, additionalOffset: 0)
        }]
    }

    private func normalize(
        _ token: WorkerTimedToken,
        vocabulary: [Int: String],
        additionalOffset: TimeInterval
    ) -> InternalToken? {
        var text = token.text
        if text.isEmpty || text.hasPrefix("token_") {
            text = vocabulary[token.tokenID] ?? text
        }
        if configuration.specialTokenTexts.contains(text) || text.isEmpty { return nil }
        return InternalToken(
            text: text,
            tokenID: token.tokenID,
            startSeconds: token.startSeconds + additionalOffset,
            endSeconds: token.endSeconds + additionalOffset
        )
    }

    private func merge(_ streams: [[InternalToken]]) -> (tokens: [InternalToken], dropped: Int) {
        var dropped = 0
        let merged = streams.reduce(into: [InternalToken]()) { partial, next in
            let result = merge(partial, with: next)
            dropped += result.dropped
            partial = result.tokens
        }
        return (merged, dropped)
    }

    private func merge(
        _ left: [InternalToken],
        with right: [InternalToken]
    ) -> (tokens: [InternalToken], dropped: Int) {
        if left.isEmpty { return (right, 0) }
        if right.isEmpty { return (left, 0) }
        if left.last!.endSeconds <= right.first!.startSeconds {
            return (left + right, 0)
        }

        var claimedLeft: Set<Int> = []
        var keptRight: [InternalToken] = []
        var dropped = 0
        for token in right {
            if let match = left.indices.last(where: { index in
                !claimedLeft.contains(index) && isProvenDuplicate(left[index], token)
            }) {
                claimedLeft.insert(match)
                dropped += 1
            } else {
                keptRight.append(token)
            }
        }
        if dropped > 0 {
            return (left + keptRight, dropped)
        }

        let cutoff = (left.last!.endSeconds + right.first!.startSeconds) / 2
        let leftKept = left.filter { $0.startSeconds < cutoff }
        let rightKept = right.filter { $0.startSeconds >= cutoff }
        return (leftKept + rightKept, 0)
    }

    private func isProvenDuplicate(_ left: InternalToken, _ right: InternalToken) -> Bool {
        let leftText = matchText(left)
        let rightText = matchText(right)
        let textMatch = !leftText.isEmpty && leftText == rightText
        let idMatch = left.tokenID != 0 && left.tokenID == right.tokenID
        guard textMatch || idMatch else { return false }
        return abs(left.startSeconds - right.startSeconds) < configuration.provenDuplicateToleranceSeconds
    }

    private func matchText(_ token: InternalToken) -> String {
        stripWordBoundary(token.text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func joinWords(_ tokens: [InternalToken]) -> [DraftWord] {
        var words: [DraftWord] = []
        var current = DraftWord()
        var heldPunctuation = ""
        var lastWasPunctuation = false

        func flush() {
            let trimmed = current.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                current = DraftWord()
                return
            }
            current.text = trimmed
            words.append(current)
            current = DraftWord()
        }

        for token in tokens {
            if isPunctuation(token) {
                let mark = stripWordBoundary(token.text)
                guard !mark.isEmpty else { continue }
                if current.text.isEmpty {
                    heldPunctuation += mark
                } else {
                    current.append(text: mark, token: token)
                }
                lastWasPunctuation = true
                continue
            }

            let piece = stripWordBoundary(token.text)
            guard !piece.isEmpty else { continue }
            let startsNewWord = current.text.isEmpty || lastWasPunctuation || isWordBoundary(token.text)
            if startsNewWord {
                flush()
                current.append(text: heldPunctuation + piece, token: token)
                heldPunctuation = ""
            } else {
                current.append(text: piece, token: token)
            }
            lastWasPunctuation = false
        }

        if !heldPunctuation.isEmpty {
            if current.text.isEmpty, var last = words.last {
                last.text += heldPunctuation
                last.absorb(endSeconds: last.endSeconds)
                words[words.count - 1] = last
            } else {
                current.text += heldPunctuation
            }
        }
        flush()
        return words
    }

    private func isWordBoundary(_ token: String) -> Bool {
        token.hasPrefix(configuration.sentencePieceWordBoundary) || token.hasPrefix(" ")
    }

    private func stripWordBoundary(_ token: String) -> String {
        if isWordBoundary(token) { return String(token.dropFirst()) }
        return token
    }

    private func isPunctuation(_ token: InternalToken) -> Bool {
        if configuration.punctuationTokenIDs.contains(token.tokenID) { return true }
        let piece = stripWordBoundary(token.text)
        guard !piece.isEmpty else { return false }
        return piece.unicodeScalars.allSatisfy { scalar in
            CharacterSet.punctuationCharacters.contains(scalar) || CharacterSet.symbols.contains(scalar)
        }
    }

    private func enclosingSpan(of words: [DraftWord], sourceDurationMs: Int) -> (startMs: Int, endMs: Int) {
        let timed = words.compactMap { word -> (Int, Int)? in
            guard let start = milliseconds(word.startSeconds), let end = milliseconds(word.endSeconds) else {
                return nil
            }
            return (start, end)
        }
        if let lastStart = timed.map(\.0).min(), let lastEnd = timed.map(\.1).max() {
            let start = max(0, lastStart)
            let end = min(sourceDurationMs, max(lastEnd, start + 1))
            if start < end { return (start, end) }
        }
        return (0, max(1, sourceDurationMs))
    }

    private func wordTiming(_ draft: DraftWord, sourceDurationMs: Int) -> (startMs: Int?, endMs: Int?, timingQuality: TranscriptTimingQuality, warningCode: String?) {
        guard !draft.hasInvalidTiming, let startSeconds = draft.startSeconds, let endSeconds = draft.endSeconds else {
            return (nil, nil, .segmentOnly, "timing_invalid")
        }
        let startMs = milliseconds(startSeconds) ?? -1
        var endMs = milliseconds(endSeconds) ?? -1
        if startMs == endMs, startMs >= 0, startMs + 1 <= sourceDurationMs {
            endMs = startMs + 1
        }
        guard startMs >= 0, startMs < endMs, endMs <= sourceDurationMs else {
            return (nil, nil, .segmentOnly, "timing_out_of_bounds")
        }
        return (startMs, endMs, .asrWord, nil)
    }

    private func milliseconds(_ seconds: TimeInterval?) -> Int? {
        guard let seconds, seconds.isFinite else { return nil }
        return Int((seconds * 1_000).rounded())
    }

    private func fallbackResult(
        for request: TokenTimingReconciliationRequest,
        droppedDuplicates: Int
    ) -> TokenTimingReconciliationResult {
        let text = request.workerTranscript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return TokenTimingReconciliationResult(words: [], droppedDuplicateTokenCount: droppedDuplicates, warnings: [])
        }
        let endMs = max(1, request.sourceDurationMs)
        return TokenTimingReconciliationResult(
            words: [
                RecognizedWord(
                    id: "word_001",
                    text: text,
                    startMs: nil,
                    endMs: nil,
                    enclosingStartMs: 0,
                    enclosingEndMs: endMs
                ),
            ],
            droppedDuplicateTokenCount: droppedDuplicates,
            warnings: [
                TranscriptWarning(
                    code: "missing_token_timings",
                    message: "Preserved transcript text without decoder word times.",
                    segmentID: "word_001"
                ),
            ]
        )
    }

    private struct InternalToken: Sendable {
        let text: String
        let tokenID: Int
        let startSeconds: TimeInterval
        let endSeconds: TimeInterval

        func mappingTimes(_ transform: (TimeInterval) -> TimeInterval) -> InternalToken {
            InternalToken(
                text: text,
                tokenID: tokenID,
                startSeconds: transform(startSeconds),
                endSeconds: transform(endSeconds)
            )
        }
    }

    private struct DraftWord: Sendable {
        var text = ""
        var startSeconds: TimeInterval?
        var endSeconds: TimeInterval?
        var hasInvalidTiming = false

        mutating func append(text piece: String, token: InternalToken) {
            text += piece
            absorb(startSeconds: token.startSeconds, endSeconds: token.endSeconds)
        }

        mutating func absorb(startSeconds: TimeInterval? = nil, endSeconds: TimeInterval?) {
            if let startSeconds {
                if !startSeconds.isFinite || startSeconds < 0 {
                    hasInvalidTiming = true
                } else if self.startSeconds == nil {
                    self.startSeconds = startSeconds
                }
            }
            if let endSeconds {
                if !endSeconds.isFinite {
                    hasInvalidTiming = true
                } else {
                    self.endSeconds = max(self.endSeconds ?? endSeconds, endSeconds)
                }
            }
            if let start = self.startSeconds, let end = self.endSeconds, start > end {
                hasInvalidTiming = true
            }
        }
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidSourceDuration
        case invalidTimeMapping
        case unsupportedTimestampUnit(String)
        case wordTimesExceedSourceDuration
    }
}

public struct TokenTimingReconciliationRequest: Sendable {
    public var workerTranscript: WorkerASRTranscript
    public var timeMapping: AudioTimeMapping
    public var sourceDurationMs: Int
    public var vocabulary: [Int: String]

    public init(
        workerTranscript: WorkerASRTranscript,
        timeMapping: AudioTimeMapping,
        sourceDurationMs: Int,
        vocabulary: [Int: String] = [:]
    ) {
        self.workerTranscript = workerTranscript
        self.timeMapping = timeMapping
        self.sourceDurationMs = sourceDurationMs
        self.vocabulary = vocabulary
    }
}

public struct TokenTimingReconciliationResult: Sendable, Equatable {
    public let words: [RecognizedWord]
    public let droppedDuplicateTokenCount: Int
    public let warnings: [TranscriptWarning]

    public var texts: [String] { words.map(\.text) }

    public init(words: [RecognizedWord], droppedDuplicateTokenCount: Int, warnings: [TranscriptWarning]) {
        self.words = words
        self.droppedDuplicateTokenCount = droppedDuplicateTokenCount
        self.warnings = warnings
    }
}
