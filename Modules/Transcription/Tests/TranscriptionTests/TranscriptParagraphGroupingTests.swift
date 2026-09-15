import Foundation
import XCTest
@testable import Transcription

/// Presentation paragraphs are derived from canonical segments. They must not
/// rewrite speaker assignments, words, timestamps, or manual edits.
final class TranscriptParagraphGroupingTests: XCTestCase {
    func testConsecutiveSameSpeakerSegmentsGroupIntoOneParagraph() {
        let segments = [
            segment("a", speaker: "speaker_1", start: 0, end: 400, text: "That's fine.", words: [
                TimedWord(text: "That's", startMs: 0, endMs: 200),
                TimedWord(text: "fine.", startMs: 220, endMs: 400),
            ]),
            segment("b", speaker: "speaker_1", start: 450, end: 1_000, text: "We can wait.", words: [
                TimedWord(text: "We", startMs: 450, endMs: 600),
                TimedWord(text: "can", startMs: 620, endMs: 780),
                TimedWord(text: "wait.", startMs: 800, endMs: 1_000),
            ]),
        ]

        let paragraphs = TranscriptParagraphGrouper().paragraphs(from: segments)

        XCTAssertEqual(paragraphs.count, 1)
        XCTAssertEqual(paragraphs[0].speakerID, "speaker_1")
        XCTAssertEqual(paragraphs[0].text, "That's fine. We can wait.")
        XCTAssertEqual(paragraphs[0].startMs, 0)
        XCTAssertEqual(paragraphs[0].endMs, 1_000)
        XCTAssertEqual(paragraphs[0].sourceSegmentIDs, ["a", "b"])
        XCTAssertEqual(paragraphs[0].words, segments.flatMap { $0.words ?? [] })
        XCTAssertEqual(segments.map(\.text), ["That's fine.", "We can wait."], "canonical segments stay as they were")
    }

    func testUnknownSentenceBoundaryDoesNotTreatAllUnknownsAsOneSpeaker() {
        let segments = [
            segment("a", speaker: nil, start: 0, end: 200, text: "Hello."),
            segment("b", speaker: nil, start: 250, end: 600, text: "Hey, hey."),
        ]

        let paragraphs = TranscriptParagraphGrouper().paragraphs(from: segments)

        XCTAssertEqual(paragraphs.map(\.speakerID), [nil, nil])
        XCTAssertEqual(paragraphs.map(\.text), ["Hello.", "Hey, hey."])
        XCTAssertEqual(paragraphs.map(\.sourceSegmentIDs), [["a"], ["b"]])
    }

    func testContiguousUnknownFragmentsMayGroupUntilASentenceBoundary() {
        let segments = [
            segment("a", speaker: nil, start: 0, end: 200, text: "Maybe"),
            segment("b", speaker: nil, start: 220, end: 400, text: "later."),
        ]

        let paragraphs = TranscriptParagraphGrouper().paragraphs(from: segments)

        XCTAssertEqual(paragraphs.count, 1)
        XCTAssertNil(paragraphs[0].speakerID)
        XCTAssertEqual(paragraphs[0].text, "Maybe later.")
        XCTAssertEqual(paragraphs[0].sourceSegmentIDs, ["a", "b"])
    }

    func testShortAcknowledgmentBridgesTheSurroundingSpeaker() {
        let segments = [
            segment("a", speaker: "speaker_1", start: 0, end: 200, text: "So"),
            segment("b", speaker: "speaker_2", start: 250, end: 500, text: "Mm-hm."),
            segment("c", speaker: "speaker_1", start: 550, end: 900, text: "anyway."),
        ]

        let paragraphs = TranscriptParagraphGrouper().paragraphs(from: segments)

        XCTAssertEqual(paragraphs.map(\.speakerID), ["speaker_1"])
        XCTAssertEqual(paragraphs.map(\.text), ["So anyway."])
        XCTAssertEqual(paragraphs.map(\.sourceSegmentIDs), [["a", "c"]])
        XCTAssertEqual(paragraphs[0].asides.map(\.text), ["Mm-hm."])
        XCTAssertEqual(paragraphs[0].asides[0].speakerID, "speaker_2")
        XCTAssertEqual(paragraphs[0].asides[0].sourceSegmentIDs, ["b"])
        XCTAssertEqual(paragraphs[0].asides[0].words, segments[1].words)
    }

    func testKnownSpeakerDoesNotAbsorbAnUnknownSpan() {
        let segments = [
            segment("a", speaker: "speaker_1", start: 0, end: 200, text: "Hello."),
            segment("b", speaker: nil, start: 250, end: 500, text: "unclear"),
            segment("c", speaker: "speaker_1", start: 550, end: 800, text: "there."),
        ]

        let paragraphs = TranscriptParagraphGrouper().paragraphs(from: segments)

        XCTAssertEqual(paragraphs.map(\.speakerID), ["speaker_1", nil, "speaker_1"])
        XCTAssertEqual(paragraphs.map(\.text), ["Hello.", "unclear", "there."])
    }

    func testOverlapIndicatorIsPreservedOnTheParagraph() {
        let segments = [
            segment("a", speaker: "speaker_1", start: 0, end: 400, text: "Alpha", overlap: false),
            segment("b", speaker: "speaker_2", start: 300, end: 900, text: "Bravo", overlap: true),
        ]

        let paragraphs = TranscriptParagraphGrouper().paragraphs(from: segments)

        XCTAssertEqual(paragraphs.map(\.speakerID), ["speaker_1", "speaker_2"])
        XCTAssertEqual(paragraphs.map(\.overlap), [false, true])
    }

    func testShortConnectedSentencesStayInOneParagraph() {
        // A sentence ending under the minimum word count is not a reading break.
        let segments = [
            segment("a", speaker: "speaker_1", start: 0, end: 400, text: "Hello."),
            segment("b", speaker: "speaker_1", start: 1_500, end: 1_800, text: "Later."),
        ]
        let paragraphs = TranscriptParagraphGrouper().paragraphs(from: segments)
        XCTAssertEqual(paragraphs.map(\.text), ["Hello. Later."])
    }

    func testMeaningfulPauseAtASentenceEndingStartsANewParagraph() {
        let segments = [
            segment("a", speaker: "speaker_1", start: 0, end: 400, text: "Hello."),
            segment("b", speaker: "speaker_1", start: 1_950, end: 2_300, text: "Later."),
        ]
        let paragraphs = TranscriptParagraphGrouper().paragraphs(from: segments)
        XCTAssertEqual(paragraphs.map(\.text), ["Hello.", "Later."])
    }

    func testMidSentencePauseOnlyBreaksAtTheHardLimit() {
        // 1.6s inside a sentence reads as hesitation, not a paragraph break.
        let hesitation = [
            segment("a", speaker: "speaker_1", start: 0, end: 400, text: "So the thing is"),
            segment("b", speaker: "speaker_1", start: 2_000, end: 2_400, text: "we should wait."),
        ]
        XCTAssertEqual(
            TranscriptParagraphGrouper().paragraphs(from: hesitation).map(\.text),
            ["So the thing is we should wait."]
        )

        let longSilence = [
            segment("a", speaker: "speaker_1", start: 0, end: 400, text: "So the thing is"),
            segment("b", speaker: "speaker_1", start: 3_100, end: 3_500, text: "we should wait."),
        ]
        XCTAssertEqual(
            TranscriptParagraphGrouper().paragraphs(from: longSilence).map(\.text),
            ["So the thing is", "we should wait."]
        )
    }

    func testLongPassageBreaksAtTheFirstSentenceEndingPastTheMinimum() {
        let configuration = TranscriptParagraphGrouper.Configuration(minimumWordCount: 4, maximumWordCount: 110)
        let segments = [
            segment("a", speaker: "speaker_1", start: 0, end: 1_100, text: "One. Two. Three. Four."),
            segment("b", speaker: "speaker_1", start: 1_150, end: 1_400, text: "Five."),
        ]
        XCTAssertEqual(
            TranscriptParagraphGrouper(configuration: configuration).paragraphs(from: segments).map(\.text),
            ["One. Two. Three. Four.", "Five."]
        )
    }

    func testHardWordCapSplitsEvenMidSentence() {
        let configuration = TranscriptParagraphGrouper.Configuration(minimumWordCount: 3, maximumWordCount: 4)
        let segments = [
            segment("a", speaker: "speaker_1", start: 0, end: 400, text: "one two three"),
            segment("b", speaker: "speaker_1", start: 450, end: 800, text: "four five"),
        ]
        XCTAssertEqual(
            TranscriptParagraphGrouper(configuration: configuration).paragraphs(from: segments).map(\.text),
            ["one two three", "four five"]
        )
    }

    func testOverlappingSpeechIsNotAbsorbedIntoCleanSpeech() {
        let segments = [
            segment("a", speaker: "speaker_1", start: 0, end: 400, text: "So the plan is", overlap: false),
            segment("b", speaker: "speaker_1", start: 420, end: 800, text: "to ship it.", overlap: true),
            segment("c", speaker: "speaker_1", start: 820, end: 1_200, text: "Next week", overlap: false),
        ]
        let paragraphs = TranscriptParagraphGrouper().paragraphs(from: segments)
        XCTAssertEqual(paragraphs.map(\.text), ["So the plan is", "to ship it.", "Next week"])
        XCTAssertEqual(paragraphs.map(\.overlap), [false, true, false])
    }

    func testUnknownFragmentsKeepTheTighterPauseLimit() {
        // Two unresolved fragments a second apart are not evidence of one speaker.
        let segments = [
            segment("a", speaker: nil, start: 0, end: 200, text: "Maybe"),
            segment("b", speaker: nil, start: 1_400, end: 1_700, text: "later"),
        ]
        let paragraphs = TranscriptParagraphGrouper().paragraphs(from: segments)
        XCTAssertEqual(paragraphs.map(\.text), ["Maybe", "later"])
        XCTAssertEqual(paragraphs.map(\.speakerID), [nil, nil])
    }

    func testGroupingDoesNotRewriteCanonicalAttributionOrWordTimings() {
        let original = [
            segment("a", speaker: "speaker_1", start: 100, end: 250, text: "Hello.", words: [
                TimedWord(text: "Hello.", startMs: 100, endMs: 250),
            ]),
            segment("b", speaker: "speaker_1", start: 300, end: 500, text: "There.", words: [
                TimedWord(text: "There.", startMs: 300, endMs: 500),
            ]),
        ]
        let snapshot = original.map(CanonicalSnapshot.init)

        let paragraphs = TranscriptParagraphGrouper().paragraphs(from: original)

        XCTAssertEqual(original.map(CanonicalSnapshot.init), snapshot)
        XCTAssertEqual(paragraphs[0].words, [
            TimedWord(text: "Hello.", startMs: 100, endMs: 250),
            TimedWord(text: "There.", startMs: 300, endMs: 500),
        ])
        XCTAssertEqual(paragraphs.flatMap(\.sourceSegmentIDs), original.map(\.id))
        XCTAssertEqual(paragraphs.map(\.text).joined(separator: " "), original.map(\.text).joined(separator: " "))
    }

    func testReferenceRunParagraphsPreserveOrderCompletenessAndAttribution() throws {
        let url = URL(
            fileURLWithPath: "/Users/jake/Meeting Transcripts/meeting--12cc48aa2c740dc50eb637b4b25a274f/runs/767535C4-424D-48BF-A178-E36435C01F12/canonical-transcript.json"
        )
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "Reference run is not on this machine")

        let transcript = try CanonicalTranscriptCodec.decode(Data(contentsOf: url))
        let original = transcript.segments
        let snapshot = original.map(CanonicalSnapshot.init)

        let paragraphs = TranscriptParagraphGrouper().paragraphs(from: original)

        XCTAssertEqual(original.map(CanonicalSnapshot.init), snapshot)
        let allSources = paragraphs.flatMap { $0.sourceSegmentIDs + $0.asides.flatMap(\.sourceSegmentIDs) }
        XCTAssertEqual(allSources.sorted(), original.map(\.id).sorted())
        XCTAssertEqual(Set(allSources).count, original.count)
        for paragraph in paragraphs + paragraphs.flatMap(\.asides) {
            let sources = original.filter { paragraph.sourceSegmentIDs.contains($0.id) }
            XCTAssertTrue(sources.allSatisfy { $0.effectiveSpeakerID == paragraph.speakerID })
            XCTAssertEqual(paragraph.words, sources.flatMap { $0.words ?? [] })
        }

        let unknownParagraphs = paragraphs.filter { $0.speakerID == nil }
        XCTAssertGreaterThan(unknownParagraphs.count, 1, "unknown spans must stay unresolved rather than collapsing into one speaker")
        let overlapSourceIDs = Set(original.filter(\.overlap).map(\.id))
        let overlapParagraphSourceIDs = Set((paragraphs + paragraphs.flatMap(\.asides)).filter(\.overlap).flatMap(\.sourceSegmentIDs))
        XCTAssertTrue(overlapSourceIDs.isSubset(of: overlapParagraphSourceIDs), "overlap indicators must remain visible in Paragraphs view")

        let speakerChanges = zip(original, original.dropFirst()).filter { $0.speakerID != $1.speakerID }.count
        let paragraphSpeakerChanges = zip(paragraphs, paragraphs.dropFirst()).filter { $0.speakerID != $1.speakerID }.count
        XCTAssertLessThanOrEqual(paragraphSpeakerChanges, speakerChanges)

        let grouped = paragraphs.filter { $0.sourceSegmentCount > 1 }.count
        let unknownWords = original.filter { $0.speakerID == nil }.flatMap { $0.words ?? [] }.count
        let adjacentSameKnown = zip(paragraphs, paragraphs.dropFirst()).filter {
            $0.speakerID != nil && $0.speakerID == $1.speakerID
        }.count
        let adjacentUnknown = zip(paragraphs, paragraphs.dropFirst()).filter {
            $0.speakerID == nil && $1.speakerID == nil
        }.count

        // Readability: a break between two paragraphs of the same speaker should
        // land on a sentence ending unless a long silence forced it.
        let sentences = TranscriptDisplayGrouper()
        let midSentenceBreaks = zip(paragraphs, paragraphs.dropFirst()).filter { current, next in
            current.speakerID != nil
                && current.speakerID == next.speakerID
                && !sentences.endsSentence(current.words?.last?.text ?? current.text)
        }
        XCTAssertLessThanOrEqual(midSentenceBreaks.count, 2, "down from 32 at the display-grouper baseline")
        XCTAssertTrue(
            midSentenceBreaks.allSatisfy { $1.startMs - $0.endMs >= TranscriptParagraphGrouper.Configuration().hardPauseMs },
            "a mid-sentence paragraph break must be justified by a long silence"
        )

        let knownWordCounts = paragraphs.filter { $0.speakerID != nil }.map { $0.words?.count ?? 0 }
        XCTAssertLessThanOrEqual(
            knownWordCounts.filter { $0 > 110 }.count, 0,
            "no paragraph may exceed the hard word cap"
        )

        let aroundContraction = paragraphs.filter { $0.startMs >= 97_000 && $0.startMs <= 103_000 }
        XCTAssertFalse(aroundContraction.isEmpty, "the split contraction near 01:38 should remain visible")
        XCTAssertTrue(
            aroundContraction.contains { $0.speakerID == nil && $0.text.contains("ll") },
            "the unknown half of the split contraction must stay an unresolved span"
        )

        XCTAssertEqual(original.count, 1_033)
        XCTAssertLessThanOrEqual(paragraphs.count, 994)
        XCTAssertGreaterThanOrEqual(grouped, 32)
        XCTAssertEqual(unknownParagraphs.count, 548)
        XCTAssertEqual(unknownWords, 814)
        XCTAssertEqual(adjacentSameKnown, 31, "down from 70 at the display-grouper baseline")
        XCTAssertEqual(adjacentUnknown, 153)
        XCTAssertEqual(transcript.revision, 3)
    }

    func testBackchannelLimitsLexiconAndOverlap() {
        let before = segment("a", speaker: "speaker_1", start: 0, end: 500, text: "The plan is")
        let after = segment("c", speaker: "speaker_1", start: 1_800, end: 2_200, text: "to continue.")
        for (text, duration, overlap, bridges) in [
            ("YEAH!", 1_200, false, true), ("got it", 300, false, true),
            ("uh-huh.", 300, false, true), ("wait for me", 300, true, true),
            ("yeah", 1_201, false, false), ("yes yes yes yes", 300, true, false),
            ("new proposal", 300, false, false), ("", 300, true, false),
        ] {
            let aside = segment("b", speaker: "speaker_2", start: 550, end: 550 + duration, text: text, overlap: overlap)
            let result = TranscriptParagraphGrouper().paragraphs(from: [before, aside, after])
            XCTAssertEqual(result.count, bridges ? 1 : 3, text)
            if bridges {
                XCTAssertEqual(result[0].asides[0].overlap, overlap)
                XCTAssertFalse(result[0].overlap, "aside overlap does not relabel the main speech")
            }
        }
    }

    func testBackchannelRequiresTwoKnownMatchingNeighboursWithinHardPause() {
        let before = segment("a", speaker: "speaker_1", start: 0, end: 500, text: "The plan")
        let aside = segment("b", speaker: "speaker_2", start: 550, end: 800, text: "yeah")
        let after = segment("c", speaker: "speaker_1", start: 900, end: 1_200, text: "continues")
        let grouper = TranscriptParagraphGrouper()
        for rows in [
            [aside, after], [before, aside],
            [before, aside, segment("c", speaker: "speaker_3", start: 900, end: 1_200, text: "continues")],
            [before, segment("b", speaker: nil, start: 550, end: 800, text: "yeah", overlap: true), after],
            [before, aside, segment("c", speaker: "speaker_1", start: 3_000, end: 3_200, text: "continues")],
            [segment("a", speaker: nil, start: 0, end: 500, text: "The plan"), aside,
             segment("c", speaker: nil, start: 900, end: 1_200, text: "continues")],
        ] {
            XCTAssertTrue(grouper.paragraphs(from: rows).allSatisfy { $0.asides.isEmpty })
        }
    }

    func testRepeatedBackchannelsKeepEverySourceExactlyOnceAndRespectHardCaps() throws {
        let rows = [
            segment("a", speaker: "speaker_1", start: 0, end: 400, text: "The plan."),
            segment("b", speaker: "speaker_2", start: 450, end: 600, text: "yeah"),
            segment("c", speaker: "speaker_1", start: 650, end: 1_000, text: "Will work."),
            segment("d", speaker: "speaker_3", start: 1_050, end: 1_200, text: "right"),
            segment("e", speaker: "speaker_1", start: 1_250, end: 1_600, text: "Very well."),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let snapshot = try encoder.encode(rows)
        let result = TranscriptParagraphGrouper().paragraphs(from: rows.reversed())
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].sourceSegmentIDs, ["a", "c", "e"])
        XCTAssertEqual(result[0].asides.flatMap(\.sourceSegmentIDs), ["b", "d"])
        XCTAssertEqual(result.flatMap(\.allSourceSegmentIDs).sorted(), rows.map(\.id).sorted())
        XCTAssertEqual(try encoder.encode(rows), snapshot)

        for config in [
            TranscriptParagraphGrouper.Configuration(minimumWordCount: 1, maximumWordCount: 3),
            TranscriptParagraphGrouper.Configuration(maximumDurationMs: 800),
        ] {
            XCTAssertTrue(TranscriptParagraphGrouper(configuration: config).paragraphs(from: rows).allSatisfy { $0.asides.isEmpty })
        }
    }

    private func segment(
        _ id: String,
        speaker: String?,
        start: Int,
        end: Int,
        text: String,
        overlap: Bool = false,
        words: [TimedWord]? = nil
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            speakerID: speaker,
            speakerLabel: speaker == nil ? "Unknown speaker" : "Speaker \(speaker!.suffix(1))",
            startMs: start,
            endMs: end,
            text: text,
            overlap: overlap,
            timingQuality: .asrWord,
            words: words ?? text.split(whereSeparator: \.isWhitespace).enumerated().map { index, token in
                let width = max(1, (end - start) / max(1, text.split(whereSeparator: \.isWhitespace).count))
                let tokenStart = start + index * width
                return TimedWord(text: String(token), startMs: tokenStart, endMs: min(end, tokenStart + width))
            }
        )
    }
}

private struct CanonicalSnapshot: Equatable {
    let id: String
    let speakerID: String?
    let speakerLabel: String
    let startMs: Int
    let endMs: Int
    let text: String
    let overlap: Bool
    let timingQuality: TranscriptTimingQuality
    let speakerConfidence: Double?
    let words: [TimedWord]?

    init(_ segment: TranscriptSegment) {
        id = segment.id
        speakerID = segment.speakerID
        speakerLabel = segment.speakerLabel
        startMs = segment.startMs
        endMs = segment.endMs
        text = segment.text
        overlap = segment.overlap
        timingQuality = segment.timingQuality
        speakerConfidence = segment.speakerConfidence
        words = segment.words
    }
}
