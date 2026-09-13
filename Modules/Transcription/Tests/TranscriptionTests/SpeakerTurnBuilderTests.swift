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

    func testPauseSplitsAndPunctuationDoesNot() throws {
        let result = try SpeakerTurnBuilder().build(
            words: [
                word("one", "Hello.", 0, 250), word("two", "After", 300, 550), word("three", "pause", 1_550, 1_800),
            ],
            diarizedTurns: [turn("A", 0, 2_000)]
        )

        XCTAssertEqual(result.segments.map(\.text), ["Hello. After", "pause"])
        XCTAssertEqual(result.segments.map(\.startMs), [0, 1_550])
        XCTAssertEqual(result.segments.map(\.endMs), [550, 1_800])
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

    func testSegmentConfidenceIsMinimumWordOverlapMargin() throws {
        let result = try SpeakerTurnBuilder().build(
            words: [word("certain", "Certain", 0, 100), word("mixed", "mixed", 200, 700)],
            diarizedTurns: [turn("A", 0, 550), turn("B", 550, 700)]
        )

        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.segments[0].speakerID, "speaker_1")
        XCTAssertEqual(try XCTUnwrap(result.segments[0].speakerConfidence), 0.4, accuracy: 0.000_001)
    }

    func testExclusiveTimelineResolvesCrossingIntervalsButPreservesOverlapFlag() throws {
        let result = try SpeakerTurnBuilder().build(
            words: [word("crossing", "Crossing", 300, 550)],
            diarizedTurns: [turn("A", 0, 700), turn("B", 300, 1_000)]
        )

        XCTAssertEqual(result.segments[0].speakerID, "speaker_1")
        XCTAssertTrue(result.segments[0].overlap)
        XCTAssertEqual(try XCTUnwrap(result.segments[0].speakerConfidence), 0.6, accuracy: 0.000_001)
    }

    func testExclusiveTimelineUsesQualityToBreakIdenticalIntervalTie() throws {
        let result = try SpeakerTurnBuilder().build(
            words: [word("tie", "Tie", 0, 400)],
            diarizedTurns: [turn("A", 0, 400, quality: 0.4), turn("B", 0, 400, quality: 0.9)]
        )

        XCTAssertEqual(result.segments[0].speakerID, "speaker_2")
        XCTAssertTrue(result.segments[0].overlap)
        XCTAssertEqual(result.segments[0].speakerConfidence, 1)
    }

    func testAdjacentExclusiveSlicesForOneSpeakerContributeToOneWord() throws {
        let result = try SpeakerTurnBuilder().build(
            words: [word("whole", "Whole", 0, 400)],
            diarizedTurns: [turn("A", 0, 200, quality: 0.4), turn("A", 200, 400, quality: 0.9)]
        )

        XCTAssertEqual(result.segments[0].speakerID, "speaker_1")
        XCTAssertEqual(result.segments[0].speakerConfidence, 1)
    }

    func testPhraseDefaultResolvesMarginalWordButAllowsClearSpeakerChange() throws {
        let words = [phraseWord("a", 0, 300), phraseWord("edge", 300, 500), phraseWord("b", 500, 700)]
        let result = try SpeakerTurnBuilder().build(words: words, diarizedTurns: [turn("A", 0, 390), turn("B", 390, 700)])
        XCTAssertEqual(result.wordAssignments.map(\.speakerID), ["speaker_1", "speaker_1", "speaker_2"])
        XCTAssertEqual(result.segments.flatMap { $0.words ?? [] }.count, 3)
    }

    func testPhraseDoesNotCrossASRSpanOrPauseThreshold() throws {
        let builder = SpeakerTurnBuilder(configuration: .init(pauseSplitMs: 100, maximumSegmentDurationMs: 30_000))
        let turns = [turn("A", 0, 200), turn("A", 300, 390), turn("B", 390, 500)]
        let paused = try builder.build(words: [phraseWord("a", 0, 200), phraseWord("edge", 300, 500)], diarizedTurns: turns)
        XCTAssertEqual(paused.wordAssignments.map(\.speakerID), ["speaker_1", "speaker_2"])
        let separate = try SpeakerTurnBuilder().build(words: [word("a", "a", 0, 300), word("edge", "edge", 300, 500)],
            diarizedTurns: [turn("A", 0, 390), turn("B", 390, 500)])
        XCTAssertEqual(separate.wordAssignments.map(\.speakerID), ["speaker_1", "speaker_2"])
    }

    func testNearestIntervalIsBoundedAndKeepsCanonicalUnknown() throws {
        for distance in [0, 250, 251] {
            let result = try SpeakerTurnBuilder().build(words: [word("edge", "edge", 500 + distance, 530 + distance)],
                diarizedTurns: [turn("A", 0, 500)])
            let segment = try XCTUnwrap(result.segments.first)
            XCTAssertNil(segment.speakerID)
            XCTAssertNil(result.wordAssignments.first?.speakerID)
            if distance <= 250 {
                XCTAssertEqual(segment.effectiveSpeakerID, "speaker_1")
                XCTAssertEqual(segment.attributionSource, .inferred)
                XCTAssertEqual(segment.speakerInference?.evidence, .nearestInterval(distanceMs: distance))
            } else {
                XCTAssertNil(segment.speakerInference)
            }
        }
        let short = try SpeakerTurnBuilder().build(words: [word("short", "short", 100, 130)], diarizedTurns: [turn("A", 0, 500)])
        XCTAssertEqual(short.segments[0].speakerInference?.evidence, .nearestInterval(distanceMs: 0))
    }

    func testNearestRejectsCompetingCoverageAndEquidistantSpeakers() throws {
        let competing = try SpeakerTurnBuilder().build(words: [word("mixed", "mixed", 501, 530)],
            diarizedTurns: [turn("A", 0, 500), turn("B", 510, 520)])
        // Only B overlaps; nearest must not propagate A through B.
        XCTAssertEqual(competing.segments[0].effectiveSpeakerID, "speaker_2")
        let mixed = try SpeakerTurnBuilder().build(words: [word("mixed", "mixed", 490, 530)],
            diarizedTurns: [turn("A", 0, 500), turn("B", 510, 520)])
        XCTAssertNil(mixed.segments[0].effectiveSpeakerID)
        let tie = try SpeakerTurnBuilder().build(words: [word("tie", "tie", 600, 630)],
            diarizedTurns: [turn("A", 0, 500), turn("B", 730, 900)])
        XCTAssertNil(tie.segments[0].effectiveSpeakerID)
    }

    func testInferredWordDoesNotContaminateConfirmedSegmentOrLoseDistance() throws {
        let result = try SpeakerTurnBuilder().build(words: [word("a", "a", 0, 200), word("b", "b", 220, 250), word("c", "c", 300, 330)],
            diarizedTurns: [turn("A", 0, 200)])
        XCTAssertEqual(result.segments.count, 3)
        XCTAssertEqual(result.segments[0].speakerID, "speaker_1")
        XCTAssertEqual(result.segments[1].speakerInference?.evidence, .nearestInterval(distanceMs: 20))
        XCTAssertEqual(result.segments[2].speakerInference?.evidence, .nearestInterval(distanceMs: 100))
    }

    func testInferenceEvidenceRoundTripsAndRetainsLegacyStrings() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for evidence: TranscriptSpeakerInferenceEvidence in [.diarizationCoverage, .diarizationBoundaryGap, .nearestInterval(distanceMs: 250)] {
            XCTAssertEqual(try decoder.decode(TranscriptSpeakerInferenceEvidence.self, from: encoder.encode(evidence)), evidence)
        }
        XCTAssertEqual(String(data: try encoder.encode(TranscriptSpeakerInferenceEvidence.diarizationCoverage), encoding: .utf8), "\"diarization_coverage\"")
        XCTAssertThrowsError(try decoder.decode(TranscriptSpeakerInferenceEvidence.self, from: Data(#"{"type":"nearest_interval","distance_ms":251}"#.utf8)))
        XCTAssertThrowsError(try encoder.encode(TranscriptSpeakerInferenceEvidence.nearestInterval(distanceMs: -1)))
    }

    private func phraseWord(_ id: String, _ start: Int, _ end: Int) -> RecognizedWord {
        RecognizedWord(id: id, text: id, startMs: start, endMs: end, enclosingStartMs: 0, enclosingEndMs: 1_000)
    }

    private func word(_ id: String, _ text: String, _ startMs: Int, _ endMs: Int) -> RecognizedWord {
        RecognizedWord(id: id, text: text, startMs: startMs, endMs: endMs, enclosingStartMs: startMs, enclosingEndMs: endMs)
    }

    private func turn(_ speakerID: String, _ startMs: Int, _ endMs: Int, quality: Double = 1) -> DiarizedSpeakerTurn {
        DiarizedSpeakerTurn(speakerID: speakerID, startMs: startMs, endMs: endMs, qualityScore: quality)
    }
}
