import Foundation
import XCTest
@testable import Transcription

/// Coverage for the subtitle cue builder, its validator, and the SRT document they produce.
///
/// The golden SRT files live alongside the TXT and JSON goldens and are checked by
/// `TranscriptExporterTests`; this suite covers the behaviour behind them.
final class SubtitleCueTests: XCTestCase {
    private let fixtures = [
        "one-speaker", "two-speakers", "four-speakers", "punctuation", "unicode",
        "unknown-speaker", "long-turns", "split-long-turn", "overlap", "dense-overlap", "no-speech",
        "past-one-hour", "past-twenty-four-hours",
    ]

    // MARK: - Document shape

    func testEveryFixtureProducesADocumentTheValidatorAccepts() throws {
        for name in fixtures {
            let document = try TranscriptExporter.srt(transcript(named: name))
            XCTAssertNoThrow(try SubtitleCueValidator.validate(document: document), "\(name).srt failed validation")
            XCTAssertNoThrow(try SubtitleCueValidator.validate(SubtitleCueBuilder.cues(for: transcript(named: name))))
        }
    }

    func testNoSpeechExportsAnEmptyFile() throws {
        let transcript = try transcript(named: "no-speech")
        XCTAssertEqual(try SubtitleCueBuilder.cues(for: transcript), [])
        XCTAssertEqual(try TranscriptExporter.srt(transcript), "")
        XCTAssertEqual(try TranscriptExporter.export(transcript, as: .subtitles), Data())
    }

    func testCuesAreNumberedFromOneAndSeparatedByABlankLine() throws {
        XCTAssertEqual(try TranscriptExporter.srt(transcript(named: "two-speakers")), """
        1
        00:00:00,500 --> 00:00:03,100
        Alex: Can we begin?

        2
        00:00:03,300 --> 00:00:06,000
        Speaker 2: Yes, I have the notes.

        """)
    }

    func testTimestampsUseTheSRTCommaAndKeepHoursPastTwentyThree() throws {
        XCTAssertTrue(try TranscriptExporter.srt(transcript(named: "past-one-hour")).contains("01:01:01,250 --> 01:01:07,800"))
        XCTAssertTrue(try TranscriptExporter.srt(transcript(named: "past-twenty-four-hours")).contains("25:01:01,250 --> 25:01:04,500"))
    }

    func testEveryCuePrintsItsSpeakerEvenWhenTheSpeakerRepeats() throws {
        for name in fixtures {
            let cues = try SubtitleCueBuilder.cues(for: transcript(named: name))
            for cue in cues {
                for block in cue.blocks {
                    XCTAssertTrue(
                        block.lines.first?.hasPrefix("\(block.speakerLabel):") == true,
                        "cue \(cue.number) of \(name) lost its speaker prefix"
                    )
                }
            }
        }
    }

    func testCuesUseTheRevisionSpeakerLabelSnapshot() throws {
        let stale = makeTranscript(
            speakers: [TranscriptSpeaker(id: "speaker_1", profileID: "profile-sarah", identityAssignment: .manual, labelSnapshot: "Sarah")],
            segments: [segment(id: "segment_001", speakerID: "speaker_1", label: "Speaker 1", startMs: 0, endMs: 2_000, text: "Renamed after the segment was written.")]
        )

        XCTAssertEqual(try TranscriptExporter.srt(stale), """
        1
        00:00:00,000 --> 00:00:02,000
        Sarah: Renamed after the segment was
        written.

        """)
    }

    func testTheDocumentStaysPlainTextWithoutReviewMarkup() throws {
        let document = try TranscriptExporter.srt(transcript(named: "dense-overlap"))
        for flag in SubtitleReviewFlag.allCases {
            XCTAssertFalse(document.contains(flag.rawValue), "review flags must not reach the subtitle file")
        }
        for markup in ["<i>", "<b>", "<font", "{\\an", "[overlap]", "[timing approximate]"] {
            XCTAssertFalse(document.contains(markup), "subtitles stay plain text: \(markup)")
        }
    }

    func testSRTExportIsUTF8AndLeavesNonASCIITextUnescaped() throws {
        let transcript = try transcript(named: "unicode")
        let data = try TranscriptExporter.export(transcript, as: .subtitles)
        XCTAssertEqual(String(data: data, encoding: .utf8), try TranscriptExporter.srt(transcript))
        for expected in ["山田さん:", "こんにちは、世界！", "Café déjà vu", "مرحبًا"] {
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(expected))
        }
    }

    // MARK: - Splitting long turns

    func testALongTurnSplitsAtWordBoundariesWithoutLosingOrMovingText() throws {
        let transcript = try transcript(named: "split-long-turn")
        let turn = transcript.segments[0]
        let cues = try SubtitleCueBuilder.cues(for: transcript)
        let fromTurn = cues.filter { $0.parentSegmentIDs == [turn.id] }

        XCTAssertGreaterThan(fromTurn.count, 1, "a fifteen-second turn should not stay one cue")
        XCTAssertEqual(fromTurn.flatMap { $0.blocks.map(\.text) }.joined(separator: " "), turn.text)
        XCTAssertEqual(fromTurn.first?.startMs, turn.startMs, "the first cue starts where the turn starts")
        XCTAssertEqual(fromTurn.last?.endMs, turn.endMs, "the last cue ends where the turn ends")

        let boundaries = Set(turn.words?.flatMap { [$0.startMs, $0.endMs] } ?? [])
        for cue in fromTurn.dropFirst() { XCTAssertTrue(boundaries.contains(cue.startMs)) }
        for cue in fromTurn.dropLast() { XCTAssertTrue(boundaries.contains(cue.endMs)) }
    }

    func testSplitCuesMeetTheReadabilityTargets() throws {
        let cues = try SubtitleCueBuilder.cues(for: transcript(named: "split-long-turn"))
        let targets = SubtitleReadabilityTargets.standard

        for cue in cues {
            XCTAssertEqual(cue.reviewFlags, [], "cue \(cue.number) should not need review")
            XCTAssertLessThanOrEqual(cue.lines.count, targets.maximumLines)
            XCTAssertLessThanOrEqual(cue.lines.map(\.count).max() ?? 0, targets.maximumCharactersPerLine)
            XCTAssertLessThanOrEqual(cue.durationMs, targets.maximumDurationMs)
            XCTAssertGreaterThanOrEqual(cue.durationMs, targets.minimumDurationMs)
        }
    }

    func testATurnWithoutWordTimesKeepsItsSegmentIntervalAndIsFlaggedForReview() throws {
        let transcript = try transcript(named: "long-turns")
        let cues = try SubtitleCueBuilder.cues(for: transcript)

        XCTAssertEqual(cues.count, transcript.segments.count, "no word times means no split")
        for (cue, segment) in zip(cues, transcript.segments) {
            XCTAssertEqual(cue.startMs, segment.startMs)
            XCTAssertEqual(cue.endMs, segment.endMs)
            XCTAssertEqual(cue.reviewFlags, [.wordTimingUnavailable, .tooManyLines, .durationAboveTarget])
        }
    }

    func testCoarseSegmentTimingIsNeverUsedAsASplitPoint() throws {
        let coarse = makeTranscript(
            speakers: [speaker()],
            segments: [segment(
                id: "segment_001", speakerID: "speaker_1", label: "Speaker 1", startMs: 0, endMs: 20_000,
                text: "Word timing exists but the pipeline marked it as a coarse fallback estimate.",
                timingQuality: .segmentOnly,
                words: evenlySpacedWords("Word timing exists but the pipeline marked it as a coarse fallback estimate.", startMs: 0, endMs: 20_000)
            )]
        )

        let cues = try SubtitleCueBuilder.cues(for: coarse)
        XCTAssertEqual(cues.count, 1)
        XCTAssertTrue(cues[0].reviewFlags.contains(.wordTimingUnavailable))
    }

    func testWordsThatDoNotReproduceTheSegmentTextAreNotUsedAsSplitPoints() throws {
        let text = "The word list here is missing one of the words it claims to time precisely."
        var words = evenlySpacedWords(text, startMs: 0, endMs: 20_000)
        words.remove(at: 3)

        let cues = try SubtitleCueBuilder.cues(for: makeTranscript(
            speakers: [speaker()],
            segments: [segment(id: "segment_001", speakerID: "speaker_1", label: "Speaker 1", startMs: 0, endMs: 20_000, text: text, words: words)]
        ))

        XCTAssertEqual(cues.count, 1, "an unreliable word list must not be split on")
        XCTAssertEqual(cues[0].blocks.first?.text, text, "no word is dropped from the cue")
        XCTAssertTrue(cues[0].reviewFlags.contains(.wordTimingUnavailable))
    }

    func testWordsThatOverlapEachOtherAreNotUsedAsSplitPoints() throws {
        let text = "These word intervals run backwards over each other and cannot be trusted at all."
        var words = evenlySpacedWords(text, startMs: 0, endMs: 20_000)
        words[2] = TimedWord(text: words[2].text, startMs: words[1].startMs, endMs: words[2].endMs)

        let cues = try SubtitleCueBuilder.cues(for: makeTranscript(
            speakers: [speaker()],
            segments: [segment(id: "segment_001", speakerID: "speaker_1", label: "Speaker 1", startMs: 0, endMs: 20_000, text: text, words: words)]
        ))

        XCTAssertEqual(cues.count, 1)
        XCTAssertTrue(cues[0].reviewFlags.contains(.wordTimingUnavailable))
    }

    // MARK: - Colliding cues

    func testCollidingCuesMergeIntoOneCueWithAPrefixedBlockPerSpeaker() throws {
        let transcript = try transcript(named: "dense-overlap")
        let cues = try SubtitleCueBuilder.cues(for: transcript)

        XCTAssertEqual(cues.count, 2, "the three-way collision chain becomes one cue")
        let merged = cues[0]
        XCTAssertEqual(merged.startMs, 1_000, "the merged cue spans the union of the collision")
        XCTAssertEqual(merged.endMs, 9_000)
        XCTAssertEqual(merged.blocks.map(\.speakerLabel), ["Speaker 1", "Noor", "Speaker 3"], "one block per speaker, in order of first appearance")
        XCTAssertEqual(merged.blocks[0].text, "I think we should ship the release today. It was verified last night.")
        XCTAssertEqual(merged.blocks[0].parentSegmentIDs, ["segment_001", "segment_004"])
        XCTAssertEqual(merged.reviewFlags, [.overlapMerged, .tooManyLines, .durationAboveTarget])

        XCTAssertEqual(cues[1].startMs, 9_500, "speech after the collision keeps its own cue")
        XCTAssertEqual(cues[1].reviewFlags, [])
    }

    func testMergingKeepsEverySpeakerAndEveryWord() throws {
        let transcript = try transcript(named: "dense-overlap")
        let document = try TranscriptExporter.srt(transcript)
        let flattened = document.replacingOccurrences(of: "\n", with: " ")

        for segment in transcript.segments {
            XCTAssertTrue(flattened.contains(segment.text), "the merge dropped \(segment.id)")
        }
    }

    func testNoTwoCuesAreEverOnScreenAtOnce() throws {
        for name in fixtures {
            let cues = try SubtitleCueBuilder.cues(for: transcript(named: name))
            for (previous, next) in zip(cues, cues.dropFirst()) {
                XCTAssertGreaterThanOrEqual(next.startMs, previous.endMs, "cues \(previous.number) and \(next.number) of \(name) collide")
            }
        }
    }

    func testCuesNeverReachPastTheSourceOrTheirOwnSegments() throws {
        for name in fixtures {
            let transcript = try transcript(named: name)
            let cues = try SubtitleCueBuilder.cues(for: transcript)
            let starts = Dictionary(uniqueKeysWithValues: transcript.segments.map { ($0.id, $0.startMs) })
            let ends = Dictionary(uniqueKeysWithValues: transcript.segments.map { ($0.id, $0.endMs) })

            for cue in cues {
                XCTAssertLessThanOrEqual(cue.endMs, transcript.source.durationMs, "cue \(cue.number) of \(name) runs past the source")
                XCTAssertGreaterThanOrEqual(cue.startMs, cue.parentSegmentIDs.compactMap { starts[$0] }.min() ?? 0)
                XCTAssertLessThanOrEqual(cue.endMs, cue.parentSegmentIDs.compactMap { ends[$0] }.max() ?? 0)
            }
        }
    }

    // MARK: - Review flags

    func testACueTooShortToReadIsFlaggedRatherThanStretched() throws {
        let brief = makeTranscript(
            speakers: [speaker()],
            segments: [segment(id: "segment_001", speakerID: "speaker_1", label: "Speaker 1", startMs: 0, endMs: 400, text: "Yes.")]
        )

        let cues = try SubtitleCueBuilder.cues(for: brief)
        XCTAssertEqual(cues[0].reviewFlags, [.durationBelowTarget])
        XCTAssertEqual(cues[0].endMs, 400, "the cue keeps the timing the source supports")
    }

    func testAWordTooLongForALineIsFlaggedRatherThanBroken() throws {
        let long = String(repeating: "supercalifragilistic", count: 3)
        let text = "\(long) afterwards"
        let cues = try SubtitleCueBuilder.cues(for: makeTranscript(
            speakers: [speaker()],
            segments: [segment(
                id: "segment_001", speakerID: "speaker_1", label: "Speaker 1", startMs: 0, endMs: 5_000, text: text,
                words: [TimedWord(text: long, startMs: 0, endMs: 3_000), TimedWord(text: "afterwards", startMs: 3_200, endMs: 5_000)]
            )]
        ))

        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].reviewFlags, [.lineTooLong])
        XCTAssertTrue(cues[0].lines.contains(long), "the word is kept whole")
        XCTAssertEqual(cues[1].reviewFlags, [])
    }

    func testFlagsAreListedInAStableOrder() throws {
        let cues = try SubtitleCueBuilder.cues(for: transcript(named: "long-turns"))
        for cue in cues {
            XCTAssertEqual(cue.reviewFlags, cue.reviewFlags.sorted())
            XCTAssertTrue(cue.needsReview)
        }
        XCTAssertFalse(try XCTUnwrap(SubtitleCueBuilder.cues(for: transcript(named: "one-speaker")).first).needsReview)
    }

    // MARK: - Parent-segment mapping for JSON

    func testCueMappingsNameTheirParentSegmentAndSurviveAJSONExport() throws {
        let source = try transcript(named: "dense-overlap")
        let cues = try SubtitleCueBuilder.cues(for: source)
        let mappings = SubtitleCueBuilder.mappings(for: cues)

        XCTAssertEqual(mappings.map(\.cueID), ["cue_001", "cue_001", "cue_001", "cue_001", "cue_002"])
        XCTAssertEqual(mappings.map(\.parentSegmentID), ["segment_001", "segment_004", "segment_002", "segment_003", "segment_005"])
        XCTAssertEqual(Set(mappings.prefix(4).map(\.startMs)), [1_000], "every row of a merged cue carries the cue's display interval")

        let withMappings = attach(mappings, to: source)
        XCTAssertNoThrow(try CanonicalTranscriptValidator.validate(withMappings))
        let exported = try XCTUnwrap(try JSONSerialization.jsonObject(with: TranscriptExporter.export(withMappings, as: .json)) as? [String: Any])
        let rows = try XCTUnwrap(exported["subtitle_cue_mappings"] as? [[String: Any]])
        XCTAssertEqual(rows.count, mappings.count)
        XCTAssertEqual(rows.first?["parent_segment_id"] as? String, "segment_001")
        XCTAssertEqual(try TranscriptExporter.srt(withMappings), try TranscriptExporter.srt(source), "mappings do not change the document")
    }

    func testASplitTurnMapsEveryCueBackToTheOneSegmentItCameFrom() throws {
        let source = try transcript(named: "split-long-turn")
        let mappings = try TranscriptExporter.subtitleCueMappings(source)

        XCTAssertEqual(mappings.filter { $0.parentSegmentID == "segment_001" }.count, 3)
        XCTAssertEqual(mappings.map(\.cueID), ["cue_001", "cue_002", "cue_003", "cue_004"])
        XCTAssertNoThrow(try CanonicalTranscriptValidator.validate(attach(mappings, to: source)))
    }

    // MARK: - Validator

    func testValidatorAcceptsAWellFormedDocumentAndAnEmptyOne() {
        XCTAssertNoThrow(try SubtitleCueValidator.validate(document: ""))
        XCTAssertNoThrow(try SubtitleCueValidator.validate(document: """
        1
        00:00:01,250 --> 00:00:04,800
        Speaker 1: Let's review the launch plan.

        2
        00:00:05,100 --> 00:00:07,600
        Speaker 2: The first milestone is complete.

        """))
    }

    func testValidatorRejectsNumberingThatSkipsACue() {
        assertRejects(document("1", "00:00:01,000", "00:00:02,000") + "\n\n" + document("3", "00:00:03,000", "00:00:04,000"),
                      .numberingNotSequential(expected: 2, found: "3"))
    }

    func testValidatorRejectsACueWithoutPositiveDuration() {
        assertRejects(document("1", "00:00:02,000", "00:00:02,000"),
                      .nonPositiveDuration(number: 1, startMs: 2_000, endMs: 2_000))
    }

    func testValidatorRejectsMalformedTimestampSyntax() {
        for malformed in ["00:00:01.000 --> 00:00:02,000", "0:00:01,000 --> 00:00:02,000", "00:60:01,000 --> 00:00:02,000", "00:00:01,00 --> 00:00:02,000"] {
            let line = malformed.components(separatedBy: " --> ")
            assertRejects(document("1", line[0], line[1]), .malformedTimestampLine(number: 1, line: malformed))
        }
        assertRejects("1\n00:00:01,000 00:00:02,000\nSpeaker 1: Text.", .malformedTimestampLine(number: 1, line: "00:00:01,000 00:00:02,000"))
    }

    func testValidatorRejectsCuesThatShareScreenTimeOrRunBackwards() {
        assertRejects(document("1", "00:00:01,000", "00:00:05,000") + "\n\n" + document("2", "00:00:04,000", "00:00:06,000"),
                      .displayOverlap(previousNumber: 1, number: 2))
        assertRejects(document("1", "00:00:04,000", "00:00:06,000") + "\n\n" + document("2", "00:00:01,000", "00:00:02,000"),
                      .outOfOrder(previousNumber: 1, number: 2))
    }

    func testValidatorRejectsABlockMissingItsTextOrTimestamp() {
        assertRejects("1\n00:00:01,000 --> 00:00:02,000", .malformedCueBlock(number: 1))
    }

    func testValidatorRejectsACueModelTheBuilderShouldNeverProduce() {
        let block = SubtitleCueBlock(speakerLabel: "Speaker 1", text: "Text.", lines: ["Speaker 1: Text."], parentSegmentIDs: ["segment_001"])
        let misnumbered = [SubtitleCue(number: 2, startMs: 0, endMs: 1_000, blocks: [block], reviewFlags: [])]
        let empty = [SubtitleCue(number: 1, startMs: 0, endMs: 1_000, blocks: [], reviewFlags: [])]

        XCTAssertThrowsError(try SubtitleCueValidator.validate(misnumbered)) {
            XCTAssertEqual($0 as? SubtitleCueValidator.Error, .numberingNotSequential(expected: 1, found: "2"))
        }
        XCTAssertThrowsError(try SubtitleCueValidator.validate(empty)) {
            XCTAssertEqual($0 as? SubtitleCueValidator.Error, .emptyText(number: 1))
        }
    }

    func testTimecodesParseBackToTheMillisecondTheyCameFrom() {
        for milliseconds in [0, 1, 999, 3_599_999, 3_600_000, 86_400_000, 90_061_250] {
            let text = TranscriptTimecode.string(fromMilliseconds: milliseconds, separator: .comma)
            XCTAssertEqual(TranscriptTimecode.milliseconds(from: text, separator: .comma), milliseconds)
        }
        XCTAssertEqual(TranscriptTimecode.milliseconds(from: "00:00:01.250"), 1_250)
        XCTAssertNil(TranscriptTimecode.milliseconds(from: "00:00:01,250"), "a dot format must not accept a comma")
        XCTAssertNil(TranscriptTimecode.milliseconds(from: "00:00:0１,250", separator: .comma), "non-ASCII digits are not a timecode")
        XCTAssertNil(TranscriptTimecode.milliseconds(from: "00:00:01,250 ", separator: .comma))
    }

    // MARK: - Determinism

    func testTheSameRevisionAlwaysProducesTheSameBytes() throws {
        for name in fixtures {
            let transcript = try transcript(named: name)
            XCTAssertEqual(
                try TranscriptExporter.export(transcript, as: .subtitles),
                try TranscriptExporter.export(transcript, as: .subtitles),
                "\(name).srt is not byte-stable"
            )
        }
    }

    // MARK: - Helpers

    private func transcript(named name: String) throws -> CanonicalTranscript {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"), "missing fixture \(name).json")
        return try CanonicalTranscriptCodec.decode(try Data(contentsOf: url))
    }

    private func document(_ number: String, _ start: String, _ end: String) -> String {
        "\(number)\n\(start) --> \(end)\nSpeaker 1: Text."
    }

    private func assertRejects(_ document: String, _ expected: SubtitleCueValidator.Error, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try SubtitleCueValidator.validate(document: document), file: file, line: line) { error in
            XCTAssertEqual(error as? SubtitleCueValidator.Error, expected, file: file, line: line)
        }
    }

    /// Word timings spread evenly across a segment, for tests about word lists the builder must
    /// refuse. The builder never invents timings like these itself.
    private func evenlySpacedWords(_ text: String, startMs: Int, endMs: Int) -> [TimedWord] {
        let words = text.split(separator: " ").map(String.init)
        let step = (endMs - startMs) / words.count
        return words.enumerated().map { index, word in
            TimedWord(text: word, startMs: startMs + index * step, endMs: startMs + (index + 1) * step - 10)
        }
    }

    private func attach(_ mappings: [SubtitleCueMapping], to transcript: CanonicalTranscript) -> CanonicalTranscript {
        CanonicalTranscript(
            transcriptID: transcript.transcriptID,
            revision: transcript.revision,
            status: transcript.status,
            createdAt: transcript.createdAt,
            source: transcript.source,
            language: transcript.language,
            languageSource: transcript.languageSource,
            speakers: transcript.speakers,
            segments: transcript.segments,
            subtitleCueMappings: mappings,
            processingOptions: transcript.processingOptions,
            engineRevisions: transcript.engineRevisions,
            warnings: transcript.warnings
        )
    }

    private func speaker(id: String = "speaker_1", label: String = "Speaker 1") -> TranscriptSpeaker {
        TranscriptSpeaker(id: id, identityAssignment: .unmatched, labelSnapshot: label)
    }

    private func makeTranscript(speakers: [TranscriptSpeaker], segments: [TranscriptSegment]) -> CanonicalTranscript {
        CanonicalTranscript(
            transcriptID: "subtitle-test",
            revision: 1,
            status: .complete,
            createdAt: "2026-09-03T12:00:00Z",
            source: TranscriptSource(filename: "subtitle-test.flac", durationMs: 60_000, checksum: "sha256:subtitle"),
            language: "en",
            languageSource: .detected,
            speakers: speakers,
            segments: segments
        )
    }

    private func segment(
        id: String,
        speakerID: String?,
        label: String,
        startMs: Int,
        endMs: Int,
        text: String,
        overlap: Bool = false,
        timingQuality: TranscriptTimingQuality = .asrWord,
        words: [TimedWord]? = nil
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            speakerID: speakerID,
            speakerLabel: label,
            startMs: startMs,
            endMs: endMs,
            text: text,
            overlap: overlap,
            timingQuality: timingQuality,
            words: words
        )
    }
}
