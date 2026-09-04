import XCTest
@testable import Transcription

final class SpeakerTurnBuilderTests: XCTestCase {
    func testPropertyEveryInputWordIsAssignedOnceAndPreservedInOutput() throws {
        let words = (0..<80).map { index in
            RecognizedWord(
                id: "word-\(index)", text: "token\(index)", startMs: index * 200, endMs: index * 200 + 100,
                enclosingStartMs: index * 200, enclosingEndMs: index * 200 + 100
            )
        }
        let turns = (0..<80).map { index in
            DiarizedSpeakerTurn(speakerID: index.isMultiple(of: 3) ? "A" : "B", startMs: index * 200, endMs: index * 200 + 100)
        }

        let result = try SpeakerTurnBuilder().build(words: words, diarizedTurns: turns)

        XCTAssertEqual(Set(result.wordAssignments.map(\.wordID)), Set(words.map(\.id)))
        XCTAssertEqual(result.wordAssignments.count, words.count)
        let emittedTokens = result.segments.flatMap { $0.text.split(separator: " ").map(String.init) }
        XCTAssertEqual(Set(emittedTokens), Set(words.map(\.text)))
        XCTAssertEqual(emittedTokens.count, words.count)
    }

    func testConversationStaysChronologicalAndNeverMergesAcrossInterveningSpeaker() throws {
        let result = try SpeakerTurnBuilder().build(
            words: [
                word("a1", "First", 0, 200), word("b", "Second", 250, 450), word("a2", "Third", 500, 700),
            ],
            diarizedTurns: [turn("A", 0, 200), turn("B", 250, 450), turn("A", 500, 700)]
        )

        XCTAssertEqual(result.segments.map(\.speakerID), ["speaker_1", "speaker_2", "speaker_1"])
        XCTAssertEqual(result.segments.map(\.text), ["First", "Second", "Third"])
        XCTAssertEqual(result.segments.map(\.startMs), [0, 250, 500])
    }

    func testSpeakerNumbersFollowDiarizedFirstAppearance() throws {
        let result = try SpeakerTurnBuilder().build(
            words: [word("b", "First", 0, 100), word("a", "Second", 200, 300)],
            diarizedTurns: [turn("cluster_B", 0, 100), turn("cluster_A", 200, 300)]
        )

        XCTAssertEqual(result.speakers.map(\.id), ["speaker_1", "speaker_2"])
        XCTAssertEqual(result.segments.map(\.speakerID), ["speaker_1", "speaker_2"])
    }

    func testPauseAndSentenceBoundaryRetainSourceTimestamps() throws {
        let result = try SpeakerTurnBuilder().build(
            words: [
                word("one", "Hello.", 0, 250), word("two", "After", 300, 550), word("three", "pause", 1_550, 1_800),
            ],
            diarizedTurns: [turn("A", 0, 2_000)]
        )

        XCTAssertEqual(result.segments.map(\.startMs), [0, 300, 1_550])
        XCTAssertEqual(result.segments.map(\.endMs), [250, 550, 1_800])
    }

    func testLongRunsCapAtWordBoundary() throws {
        let words = (0..<31).map { index in word("w\(index)", "word\(index)", index * 1_000, index * 1_000 + 500) }
        let result = try SpeakerTurnBuilder().build(words: words, diarizedTurns: [turn("A", 0, 31_000)])

        XCTAssertEqual(result.segments.count, 2)
        XCTAssertEqual(result.segments.map(\.startMs), [0, 30_000])
        XCTAssertEqual(result.segments.map(\.endMs), [29_500, 30_500])
    }

    func testOverlappingDiarizationKeepsBothSpeakersAndMarksPrimaryTextAttribution() throws {
        let result = try SpeakerTurnBuilder().build(
            words: [word("a", "Alpha", 0, 400), word("b", "Bravo", 500, 900)],
            diarizedTurns: [turn("A", 0, 550), turn("B", 450, 1_000)]
        )

        XCTAssertEqual(result.speakers.map(\.id), ["speaker_1", "speaker_2"])
        XCTAssertEqual(result.segments.map(\.speakerID), ["speaker_1", "speaker_2"])
        XCTAssertFalse(result.segments[0].overlap)
        XCTAssertTrue(result.segments[1].overlap)
    }

    func testAmbiguousOrMissingEvidenceUsesUnknownSpeakerAndFallbackTextUsesSegmentTiming() throws {
        let result = try SpeakerTurnBuilder().build(
            words: [RecognizedWord(id: "fallback", text: "Uncertain", startMs: nil, endMs: nil, enclosingStartMs: 100, enclosingEndMs: 500)],
            diarizedTurns: [turn("A", 100, 300), turn("B", 300, 500)],
            untranscribedSpeech: [UntranscribedSpeechInterval(startMs: 800, endMs: 1_200)]
        )

        XCTAssertEqual(result.segments[0].speakerID, nil)
        XCTAssertEqual(result.segments[0].speakerLabel, "Unknown speaker")
        XCTAssertEqual(result.segments[0].timingQuality, .segmentOnly)
        XCTAssertNil(result.segments[0].words)
        XCTAssertEqual(result.segments[0].startMs, 100)
        XCTAssertEqual(result.diagnostics, [.untranscribedSpeech(startMs: 800, endMs: 1_200)])
    }

    private func word(_ id: String, _ text: String, _ startMs: Int, _ endMs: Int) -> RecognizedWord {
        RecognizedWord(id: id, text: text, startMs: startMs, endMs: endMs, enclosingStartMs: startMs, enclosingEndMs: endMs)
    }

    private func turn(_ speakerID: String, _ startMs: Int, _ endMs: Int) -> DiarizedSpeakerTurn {
        DiarizedSpeakerTurn(speakerID: speakerID, startMs: startMs, endMs: endMs)
    }
}
