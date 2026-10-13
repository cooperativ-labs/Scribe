import XCTest
@testable import Transcription

final class VocabularyWordReplacerTests: XCTestCase {
    private func word(_ text: String, _ start: Int, _ end: Int) -> ReconciledWordsRecord.Word {
        .init(id: "w-\(start)", text: text, startMs: start, endMs: end, enclosingStartMs: start, enclosingEndMs: end)
    }
    private func replacement(_ original: String, _ replacement: String, _ start: Double, _ end: Double) -> WorkerVocabularyReplacement {
        .init(original: original, replacement: replacement, startSeconds: start, endSeconds: end)
    }
    func testMultiwordAliasKeepsEnclosingTimeAndPunctuation() {
        let words = [word("Use", 0, 100), word("Liv", 200, 400), word("Mali,", 400, 600), word("please.", 800, 900)]
        let corrected = VocabularyWordReplacer.apply([replacement("Liv Mali,", "Livmarli", 0.2, 0.6)], to: words)
        XCTAssertEqual(corrected.map(\.text), ["Use", "Livmarli,", "please."])
        XCTAssertEqual(corrected[1].startMs, 200)
        XCTAssertEqual(corrected[1].endMs, 600)
        XCTAssertEqual(corrected[1].id, "w-200")
    }
    func testMultiwordCanonicalUsesOneRealTimedSlot() {
        let corrected = VocabularyWordReplacer.apply([replacement("clearcomply.", "Clear Comply", 1, 1.4)], to: [word("clearcomply.", 1000, 1400)])
        XCTAssertEqual(corrected.map(\.text), ["Clear Comply."])
        XCTAssertEqual(corrected[0].endMs, 1400)
    }
    func testRepeatedPhraseUsesSourceSpanAndOverlapIsAppliedOnce() {
        let words = [word("Liv", 0, 200), word("Mali.", 200, 400), word("Liv", 31000, 31200), word("Mali!", 31200, 31400)]
        let corrected = VocabularyWordReplacer.apply([
            replacement("Liv Mali!", "Livmarli", 31, 31.4), replacement("Mali!", "Other", 31.2, 31.4)
        ], to: words)
        XCTAssertEqual(corrected.map(\.text), ["Liv", "Mali.", "Livmarli!"])
    }
    func testNonHitsInvalidSpansAndWrongOriginalNeverRewriteWords() {
        let words = [word("ordinary", 0, 300), word("speech.", 400, 800)]
        for replacements in [[], [replacement("other", "NVIDIA", 0, 0.3)],
                             [replacement("ordinary", "NVIDIA", .nan, 0.3)],
                             [replacement("ordinary", "NVIDIA", 0.2, 0.3)],
                             [replacement("speech", "", 0.4, 0.8)]] {
            XCTAssertEqual(VocabularyWordReplacer.apply(replacements, to: words).map(\.text), words.map(\.text))
        }
    }
}
