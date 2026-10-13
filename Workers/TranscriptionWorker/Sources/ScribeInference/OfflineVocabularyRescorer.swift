@preconcurrency import AVFoundation
import FluidAudio
import Foundation

/// Wire snapshot matches VocabularySnapshot without coupling inference to desktop UI.
public struct WorkerVocabularySnapshot: Codable, Sendable, Equatable {
    public struct Term: Codable, Sendable, Equatable {
        public let text: String
        public let aliases: [String]
        public init(text: String, aliases: [String] = []) { self.text = text; self.aliases = aliases }
    }
    public let revision: String?
    public let terms: [Term]
    public init(revision: String? = nil, terms: [Term] = []) { self.revision = revision; self.terms = terms }
    public static func load(in directory: URL, path: String?) throws -> Self {
        guard let path else { return .init() }
        guard path == "vocabulary.json" else { throw CocoaError(.fileReadInvalidFileName) }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: directory.appendingPathComponent(path)))
    }
    public var usableTerms: [Term] {
        terms.filter { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 && $0.text.contains { $0.isLetter || $0.isNumber } }
    }
}

public struct VocabularyReplacement: Codable, Sendable, Equatable {
    public let original: String
    public let replacement: String
    public let startSeconds: Double
    public let endSeconds: Double
    public let originalScore: Float
    public let replacementScore: Float
}

/// No model hub, cache recovery or download helpers. Log-probabilities live for at
/// most 36 seconds of audio, independent of recording length. ASR tokens stay raw.
public enum OfflineVocabularyRescorer {
    public struct Output: Sendable {
        public let text: String
        public let replacements: [VocabularyReplacement]
        public let warning: String?
    }

    public static func rescore(
        fileURL: URL, text: String, tokens: [TokenTiming], snapshot: WorkerVocabularySnapshot,
        manifest: ModelManifest, modelsDirectory: URL
    ) async -> Output {
        guard !snapshot.usableTerms.isEmpty else { return .init(text: text, replacements: [], warning: nil) }
        do {
            let models = try await OfflineModelLoader.loadCTC(manifest: manifest, modelsDirectory: modelsDirectory)
            let directory = modelsDirectory.appendingPathComponent("parakeet-ctc-110m-coreml")
            let tokenizer = try await CtcTokenizer.load(from: directory)
            let terms = snapshot.usableTerms.compactMap { term -> CustomVocabularyTerm? in
                let ids = tokenizer.encode(term.text)
                guard !ids.isEmpty else { return nil }
                return CustomVocabularyTerm(text: term.text, aliases: term.aliases.filter { $0.count >= 3 }, ctcTokenIds: ids)
            }
            guard !terms.isEmpty else { return .init(text: text, replacements: [], warning: nil) }
            let context = CustomVocabularyContext(terms: terms)
            let spotter = CtcKeywordSpotter(models: models)
            let rescorer = try await VocabularyRescorer.create(
                spotter: spotter, vocabulary: context,
                config: .init(shortTermCbwTaperPivot: 5, spotterRescueEnabled: false),
                ctcModelDirectory: directory
            )
            let file = try AVAudioFile(forReading: fileURL)
            let duration = Double(file.length) / 16_000
            var replacements: [VocabularyReplacement] = []
            var coreStart = 0.0
            while coreStart < duration {
                try Task.checkCancellation()
                let coreEnd = min(duration, coreStart + 30)
                let start = max(0, coreStart - 3)
                let end = min(duration, coreEnd + 3)
                let localTokens = tokens.filter { $0.startTime >= start && $0.endTime <= end }.map {
                    TokenTiming(token: $0.token, tokenId: $0.tokenId, startTime: $0.startTime - start,
                                endTime: $0.endTime - start, confidence: $0.confidence)
                }
                if !localTokens.isEmpty {
                    file.framePosition = AVAudioFramePosition((start * 16_000).rounded())
                    let count = AVAudioFrameCount(((end - start) * 16_000).rounded())
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else {
                        throw CocoaError(.fileReadUnknown)
                    }
                    try file.read(into: buffer, frameCount: count)
                    guard let channel = buffer.floatChannelData?[0] else { throw CocoaError(.fileReadUnknown) }
                    let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
                    let spotted = try await spotter.spotKeywordsWithLogProbs(audioSamples: samples, customVocabulary: context)
                    let evidence = rescorer.ctcTokenEvaluateCandidates(
                        transcript: localTokens.map(\.token).joined().replacingOccurrences(of: "▁", with: " ").trimmingCharacters(in: .whitespaces),
                        tokenTimings: localTokens, logProbs: spotted.logProbs,
                        frameDuration: spotted.frameDuration, minSimilarity: 0.5
                    )
                    for candidate in evidence.candidates where candidate.comparisonPassed && candidate.legacyOutcome == .applied {
                        guard let localStart = candidate.startTime, let localEnd = candidate.endTime,
                              let originalScore = candidate.rawOriginalCTCScore, originalScore.isFinite,
                              let score = candidate.rawVocabularyCTCScore, score.isFinite,
                              localStart.isFinite, localEnd.isFinite, localEnd > localStart else { continue }
                        let absoluteStart = start + localStart
                        let absoluteEnd = start + localEnd
                        // Each candidate belongs to one core window; margins rescue seams.
                        guard absoluteStart >= coreStart, absoluteStart < coreEnd, absoluteEnd <= duration,
                              accepts(original: candidate.basePhrase, canonical: candidate.canonicalTerm,
                                      aliases: snapshot.usableTerms.first(where: { $0.text == candidate.canonicalTerm })?.aliases ?? [], similarity: candidate.similarity),
                              !replacements.contains(where: { $0.startSeconds < absoluteEnd && absoluteStart < $0.endSeconds }) else { continue }
                        replacements.append(.init(original: candidate.basePhrase, replacement: candidate.canonicalTerm,
                                                  startSeconds: absoluteStart, endSeconds: absoluteEnd,
                                                  originalScore: originalScore, replacementScore: score))
                    }
                    // Exact normalized spellings are skipped by upstream rescoring.
                    // Canonicalize them only when CTC independently spots this term
                    // at the same audio occurrence; never expand into adjacent words.
                    for item in exactSpellings(tokens: localTokens, detections: spotted.detections, minimumScore: context.minCtcScore) {
                        let absoluteStart = start + item.startSeconds, absoluteEnd = start + item.endSeconds
                        guard absoluteStart >= coreStart, absoluteStart < coreEnd,
                              !replacements.contains(where: { $0.startSeconds < absoluteEnd && absoluteStart < $0.endSeconds }) else { continue }
                        replacements.append(.init(original: item.original, replacement: item.replacement,
                            startSeconds: absoluteStart, endSeconds: absoluteEnd,
                            originalScore: item.originalScore, replacementScore: item.replacementScore))
                    }
                }
                coreStart = coreEnd
            }
            // Dictation uses text; batch applies these same spans to canonical words.
            // Only replace a uniquely aligned phrase in the raw text, in token order.
            let corrected = correctedText(text, tokens: tokens, replacements: replacements)
            return .init(text: corrected, replacements: replacements, warning: nil)
        } catch {
            return .init(text: text, replacements: [], warning: "vocabulary_assets_unavailable")
        }
    }

    /// A vocabulary phrase already present inside a longer span must never eat
    /// neighboring words. Explicit whole-phrase aliases may differ substantially;
    /// other candidates need strong orthographic agreement as well as CTC evidence.
    static func accepts(original: String, canonical: String, aliases: [String], similarity: Float) -> Bool {
        let base = key(original), target = key(canonical)
        guard !base.isEmpty, !target.isEmpty, original != canonical else { return false }
        if base != target && base.contains(target) { return false }
        if aliases.contains(where: { key($0) == base }) { return true }
        let ratio = Double(min(base.count, target.count)) / Double(max(base.count, target.count))
        return similarity >= 0.75 && ratio >= 0.75
    }

    private struct Word { var text: String; let start: Double; var end: Double }
    private static func timedWords(_ tokens: [TokenTiming]) -> [Word] {
        var words: [Word] = []
        for token in tokens where !token.token.isEmpty && token.token != "<blank>" && token.token != "<pad>" {
            let value = token.token.replacingOccurrences(of: "▁", with: " ")
            if words.isEmpty || (value.first?.isWhitespace == true && !key(value).isEmpty) {
                words.append(.init(text: value.trimmingCharacters(in: .whitespaces), start: token.startTime, end: token.endTime))
            } else {
                words[words.count - 1].text += value.trimmingCharacters(in: .whitespaces)
                if !key(value).isEmpty { words[words.count - 1].end = token.endTime }
            }
        }
        return words
    }

    static func exactSpellings(tokens: [TokenTiming], detections: [CtcKeywordSpotter.KeywordDetection], minimumScore: Float) -> [VocabularyReplacement] {
        let words = timedWords(tokens)
        var replacements: [VocabularyReplacement] = []
        for detection in detections where detection.score.isFinite && detection.score >= minimumScore {
            let target = detection.term.text
            for first in words.indices {
                for count in 1...min(max(4, target.split(separator: " ").count), words.count - first) {
                    let last = first + count - 1
                    let original = words[first...last].map(\.text).joined(separator: " ")
                    let start = words[first].start, end = words[last].end
                    let overlap = max(0, min(end, detection.endTime) - max(start, detection.startTime))
                    guard end > start, key(original) == key(target),
                          original.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) != target,
                          abs(start - detection.startTime) <= 0.5, abs(end - detection.endTime) <= 0.5,
                          overlap / (end - start) >= 0.5,
                          !replacements.contains(where: { $0.startSeconds < end && start < $0.endSeconds }) else { continue }
                    replacements.append(.init(original: original, replacement: target, startSeconds: start, endSeconds: end,
                        originalScore: detection.score, replacementScore: detection.score))
                }
            }
        }
        return replacements
    }

    static func correctedText(_ text: String, tokens: [TokenTiming], replacements: [VocabularyReplacement]) -> String {
        guard !replacements.isEmpty else { return text }
        let words = timedWords(tokens)
        guard let regex = try? NSRegularExpression(pattern: "\\S+") else { return text }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard matches.count == words.count else { return text }
        for (match, word) in zip(matches, words) {
            guard let range = Range(match.range, in: text), key(String(text[range])) == key(word.text) else { return text }
        }
        var edits: [(Range<String.Index>, String)] = []
        var claimed = Set<Int>()
        for replacement in replacements.sorted(by: { $0.startSeconds < $1.startSeconds }) {
            let indices = words.indices.filter { words[$0].start >= replacement.startSeconds - 0.001 && words[$0].start < replacement.endSeconds - 0.001 }
            guard let first = indices.first, let last = indices.last,
                  abs(words[first].start - replacement.startSeconds) <= 0.1,
                  !indices.contains(where: { claimed.contains($0) }),
                  key(indices.map { words[$0].text }.joined(separator: " ")) == key(replacement.original),
                  let startRange = Range(matches[first].range, in: text), let endRange = Range(matches[last].range, in: text) else { continue }
            let range = startRange.lowerBound..<endRange.upperBound
            let original = String(text[range])
            let leading = String(original.prefix { !$0.isLetter && !$0.isNumber })
            let trailing = String(original.reversed().prefix { !$0.isLetter && !$0.isNumber }.reversed())
            edits.append((range, (replacement.replacement.hasPrefix(leading) ? "" : leading) + replacement.replacement + (replacement.replacement.hasSuffix(trailing) ? "" : trailing)))
            claimed.formUnion(indices)
        }
        var output = text
        for (range, value) in edits.reversed() { output.replaceSubrange(range, with: value) }
        return output
    }

    private static func key(_ text: String) -> String {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined()
    }
}
