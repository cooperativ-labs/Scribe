import Foundation
import XCTest
@testable import Transcription

/// Golden-file and interchange-contract coverage for transcript exports.
///
/// Set `SCRIBE_REGENERATE_GOLDENS=1` to rewrite `Tests/Fixtures/Goldens` from the current
/// exporters; review the diff before committing it.
final class TranscriptExporterTests: XCTestCase {
    private let goldenFixtures = [
        "one-speaker", "two-speakers", "four-speakers", "punctuation", "unicode",
        "unknown-speaker", "long-turns", "split-long-turn", "overlap", "dense-overlap", "no-speech",
        "past-one-hour", "past-twenty-four-hours",
    ]

    // MARK: - Goldens

    func testPlainTextExportsMatchGoldenFiles() throws {
        for name in goldenFixtures {
            let exported = try TranscriptExporter.plainText(transcript(named: name))
            try assertMatchesGolden(exported, named: name, extension: "txt")
        }
    }

    func testJSONExportsMatchGoldenFiles() throws {
        for name in goldenFixtures {
            let exported = try TranscriptExporter.json(transcript(named: name))
            try assertMatchesGolden(exported, named: name, extension: "json")
        }
    }

    func testSRTExportsMatchGoldenFiles() throws {
        for name in goldenFixtures {
            let exported = try TranscriptExporter.srt(transcript(named: name))
            try assertMatchesGolden(exported, named: name, extension: "srt")
        }
    }

    func testKnowledgebaseExportMatchesUploadContract() throws {
        let exported = try object(from: TranscriptExporter.export(transcript(named: "one-speaker"), as: .knowledgebase))

        XCTAssertEqual(exported["schema"] as? String, "kb.transcript-upload/1")
        let recording = try XCTUnwrap(exported["recording"] as? [String: Any])
        XCTAssertEqual(recording["duration_ms"] as? Int, 12_000)
        XCTAssertNil(recording["recorded_at"], "Transcript creation time is not recording start time")
        let transcript = try XCTUnwrap(exported["transcript"] as? [String: Any])
        XCTAssertEqual(transcript["processed_at"] as? String, "2026-09-03T12:00:00Z")
        XCTAssertEqual(transcript["language"] as? String, "en")

        let segments = try XCTUnwrap(exported["segments"] as? [[String: Any]])
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0]["speaker"] as? String, "Speaker 1")
        XCTAssertEqual(segments[0]["start_ms"] as? Int, 1_000)
        XCTAssertEqual(segments[0]["end_ms"] as? Int, 4_200)
        XCTAssertNil(segments[0]["words"], "The upload schema does not accept word timings")

        let pipeline = try XCTUnwrap(exported["pipeline"] as? [String: Any])
        XCTAssertEqual((pipeline["producer"] as? [String: Any])?["name"] as? String, "scribe")
        let extensions = try XCTUnwrap(pipeline["extensions"] as? [String: Any])
        let scribe = try XCTUnwrap(extensions["ai.scribe"] as? [String: Any])
        XCTAssertEqual(scribe["transcript_id"] as? String, "one-speaker")
        XCTAssertEqual(scribe["revision"] as? Int, 1)
        XCTAssertEqual(scribe["source_checksum"] as? String, "sha256:one")
    }

    func testKnowledgebaseExportsValidateAgainstTheUploadSchema() throws {
        let schemaURL = try XCTUnwrap(
            Bundle.module.url(forResource: "scribe-transcript-upload.schema", withExtension: "json")
        )
        let schema = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: schemaURL)) as? [String: Any]
        )
        let validator = JSONSchemaFixtureValidator(rootSchema: schema)

        for name in goldenFixtures {
            let exported = try TranscriptExporter.export(transcript(named: name), as: .knowledgebase)
            try validator.validate(try JSONSerialization.jsonObject(with: exported))
        }
    }

    func testKnowledgebaseExportUsesNullForUnknownSpeakersAndASilenceSegmentForNoSpeech() throws {
        let unassigned = try object(from: TranscriptExporter.export(transcript(named: "unknown-speaker"), as: .knowledgebase))
        let unassignedSegments = try XCTUnwrap(unassigned["segments"] as? [[String: Any]])
        XCTAssertTrue(unassignedSegments[0]["speaker"] is NSNull)

        let silent = try object(from: TranscriptExporter.export(transcript(named: "no-speech"), as: .knowledgebase))
        let silence = try XCTUnwrap((silent["segments"] as? [[String: Any]])?.first)
        XCTAssertTrue(silence["speaker"] is NSNull)
        XCTAssertEqual(silence["text"] as? String, "[silence]")
        XCTAssertEqual(silence["start_ms"] as? Int, 0)
        XCTAssertEqual(silence["end_ms"] as? Int, 9_000)
    }

    // MARK: - Meeting notes

    private let draftA = UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000001")!
    private let draftB = UUID(uuidString: "BBBBBBBB-0000-4000-8000-000000000002")!

    private func sampleNotes() -> [TranscriptExportNote] {
        [
            TranscriptExportNote(id: UUID(uuidString: "11111111-0000-4000-8000-000000000001")!,
                                 text: "  Ask Dana about the launch\r\n\n   and the budget  ", offsetMs: 350_000, draftID: draftA),
            TranscriptExportNote(id: UUID(uuidString: "22222222-0000-4000-8000-000000000002")!,
                                 text: "Untimed thought", offsetMs: nil, draftID: draftA),
            TranscriptExportNote(id: UUID(), text: " \u{3000}\n\t", offsetMs: 9_000, draftID: draftA),
            TranscriptExportNote(id: UUID(uuidString: "33333333-0000-4000-8000-000000000003")!,
                                 text: "From the second call", offsetMs: 3_723_000, draftID: draftB),
        ]
    }

    func testPlainTextAddsANotesSectionAfterTheTranscript() throws {
        let transcript = try transcript(named: "one-speaker")
        let plain = try TranscriptExporter.plainText(transcript)
        let withNotes = try TranscriptExporter.plainText(transcript, notes: sampleNotes())
        XCTAssertEqual(withNotes, plain.dropLast() + """


        Notes

        [05:50] Ask Dana about the launch
                and the budget

        [--:--] Untimed thought

        [1:02:03] From the second call

        """, "a note with no words is left out; later lines indent under the first")
        XCTAssertEqual(try TranscriptExporter.plainText(transcript, notes: []), plain, "no notes, no section")
        XCTAssertEqual(try TranscriptExporter.plainText(transcript, notes: [sampleNotes()[2]]), plain, "only blank notes, no section")

        let silent = try TranscriptExporter.plainText(self.transcript(named: "no-speech"), notes: [sampleNotes()[1]])
        XCTAssertEqual(silent, "\(TranscriptTextExporter.noSpeechStatement)\n\nNotes\n\n[--:--] Untimed thought\n")
    }

    func testJSONAddsATopLevelNotesArrayThatCanonicalReadersIgnore() throws {
        let schema = try XCTUnwrap(try JSONSerialization.jsonObject(with: CanonicalTranscriptSchema.data) as? [String: Any])
        let validator = JSONSchemaFixtureValidator(rootSchema: schema)
        for name in goldenFixtures {
            let original = try transcript(named: name)
            let exported = try TranscriptExporter.export(original, as: .json, notes: sampleNotes())
            try validator.validate(try JSONSerialization.jsonObject(with: exported))
            // A reader that predates notes decodes the same transcript.
            XCTAssertEqual(try CanonicalTranscriptCodec.decode(exported), original, name)
        }

        let original = try transcript(named: "one-speaker")
        let document = try TranscriptExporter.json(original, notes: sampleNotes())
        XCTAssertTrue(document.hasPrefix(try TranscriptExporter.json(original).dropLast(3)), "the canonical members come first, unchanged")
        let object = try object(from: Data(document.utf8))
        XCTAssertEqual(Array(object.keys.filter { $0 == "notes" }), ["notes"])
        let notes = try XCTUnwrap(object["notes"] as? [[String: Any]])
        XCTAssertEqual(notes.count, 3)
        XCTAssertEqual(notes[0]["id"] as? String, "11111111-0000-4000-8000-000000000001")
        XCTAssertEqual(notes[0]["text"] as? String, "Ask Dana about the launch\nand the budget")
        XCTAssertEqual(notes[0]["offset_ms"] as? Int, 350_000)
        XCTAssertEqual(notes[0]["draft_id"] as? String, "aaaaaaaa-0000-4000-8000-000000000001")
        XCTAssertTrue(notes[1]["offset_ms"] is NSNull, "an untimed note says so with null")
        XCTAssertEqual(notes[2]["draft_id"] as? String, "bbbbbbbb-0000-4000-8000-000000000002", "a combined note keeps its draft")
        XCTAssertEqual(notes.map { $0.keys.sorted() }, Array(repeating: ["draft_id", "id", "offset_ms", "text"], count: 3))
        XCTAssertEqual(orderOfKeys(["notes", "warnings"], in: document), ["warnings", "notes"])

        XCTAssertNil(try self.object(from: TranscriptExporter.export(original, as: .json, notes: [sampleNotes()[2]]))["notes"],
                     "without notes the document is the canonical transcript exactly")
    }

    func testKnowledgebaseCarriesNotesInItsExtensionAndStillValidatesAsVersionOne() throws {
        let schemaURL = try XCTUnwrap(Bundle.module.url(forResource: "scribe-transcript-upload.schema", withExtension: "json"))
        let schema = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: schemaURL)) as? [String: Any])
        let validator = JSONSchemaFixtureValidator(rootSchema: schema)
        for name in goldenFixtures {
            let exported = try TranscriptExporter.export(transcript(named: name), as: .knowledgebase, notes: sampleNotes())
            // The schema is Knowledgebase's own, which rejects unknown top-level
            // and segment members: an importer that predates notes accepts this.
            try validator.validate(try JSONSerialization.jsonObject(with: exported))
        }

        let original = try transcript(named: "one-speaker")
        let exported = try object(from: TranscriptExporter.export(original, as: .knowledgebase, notes: sampleNotes()))
        XCTAssertEqual(exported["schema"] as? String, KnowledgebaseTranscriptExporter.schema)
        XCTAssertEqual(KnowledgebaseTranscriptExporter.schema, "kb.transcript-upload/1")
        XCTAssertEqual(Set(exported.keys), ["schema", "recording", "transcript", "pipeline", "segments"])
        let scribe = try XCTUnwrap(((exported["pipeline"] as? [String: Any])?["extensions"] as? [String: Any])?["ai.scribe"] as? [String: Any])
        let notes = try XCTUnwrap(scribe["notes"] as? [[String: Any]])
        XCTAssertEqual(notes.map { $0["text"] as? String }, ["Ask Dana about the launch\nand the budget", "Untimed thought", "From the second call"])
        XCTAssertEqual(notes.map { $0.keys.sorted() }, Array(repeating: ["id", "offset_ms", "text"], count: 3))
        XCTAssertTrue(notes[1]["offset_ms"] is NSNull)

        let plain = try TranscriptExporter.export(original, as: .knowledgebase)
        XCTAssertEqual(try TranscriptExporter.export(original, as: .knowledgebase, notes: []), plain)
        let segments = try XCTUnwrap(exported["segments"] as? [[String: Any]])
        XCTAssertEqual(segments.count, try XCTUnwrap(object(from: plain)["segments"] as? [Any]).count, "notes never become segments")
    }

    func testSubtitlesNeverCarryNotes() throws {
        for name in goldenFixtures {
            let original = try transcript(named: name)
            XCTAssertEqual(try TranscriptExporter.export(original, as: .subtitles, notes: sampleNotes()),
                           try TranscriptExporter.export(original, as: .subtitles))
        }
    }

    func testTheAgentHandoffAndTheTextExportFormatNotesAlike() {
        let notes = [MeetingNote(text: "Ask Dana\n  and Sam", recordingOffsetMilliseconds: 350_000), MeetingNote(text: "Untimed")]
        let block = AgentHandoffPayload.notesBlock(notes)
        XCTAssertEqual(block, AgentHandoffPayload.notesHeading + "\n[05:50] Ask Dana\n        and Sam\n[--:--] Untimed")
    }

    func testKnowledgebaseExportUsesDistinctCompoundExtension() {
        XCTAssertEqual(TranscriptExportFormat.knowledgebase.fileExtension, "kb.json")
        XCTAssertEqual(TranscriptExportFormat.knowledgebase.contentType, .json)
    }

    // MARK: - Determinism and encoding

    func testExportsAreByteDeterministic() throws {
        for name in goldenFixtures {
            let transcript = try transcript(named: name)
            for format in TranscriptExportFormat.allCases {
                let first = try TranscriptExporter.export(transcript, as: format)
                let second = try TranscriptExporter.export(transcript, as: format)
                XCTAssertEqual(first, second, "\(name).\(format.fileExtension) is not byte-stable")
            }
        }
    }

    func testDictionaryBackedFieldsExportInAStableOrderRegardlessOfInsertionOrder() throws {
        let keys = ["zeta", "alpha", "middle", "beta", "omega"]
        let speakers = [TranscriptSpeaker(id: "speaker_1", identityAssignment: .unmatched, labelSnapshot: "Speaker 1")]
        let segments = [segment(id: "segment_001", speakerID: "speaker_1", label: "Speaker 1", startMs: 0, endMs: 1_000, text: "Order does not matter.")]
        let forward = makeTranscript(
            speakers: speakers,
            segments: segments,
            processingOptions: Dictionary(uniqueKeysWithValues: keys.map { ($0, TranscriptJSONValue.boolean(true)) }),
            engineRevisions: Dictionary(uniqueKeysWithValues: keys.map { ($0, "v1") })
        )
        let reversed = makeTranscript(
            speakers: speakers,
            segments: segments,
            processingOptions: Dictionary(uniqueKeysWithValues: keys.reversed().map { ($0, TranscriptJSONValue.boolean(true)) }),
            engineRevisions: Dictionary(uniqueKeysWithValues: keys.reversed().map { ($0, "v1") })
        )

        let exported = try TranscriptJSONExporter.export(forward)
        XCTAssertEqual(exported, try TranscriptJSONExporter.export(reversed))
        XCTAssertEqual(orderOfKeys(keys, in: exported), keys.sorted())
    }

    func testExportsAreUTF8AndLeaveNonASCIITextUnescaped() throws {
        let transcript = try transcript(named: "unicode")
        let text = try TranscriptExporter.export(transcript, as: .plainText)
        let json = try TranscriptExporter.export(transcript, as: .json)

        XCTAssertEqual(String(data: text, encoding: .utf8), try TranscriptExporter.plainText(transcript))
        XCTAssertEqual(String(data: json, encoding: .utf8), try TranscriptExporter.json(transcript))
        for expected in ["山田さん", "こんにちは、世界！", "Café déjà vu", "مرحبًا"] {
            XCTAssertTrue(String(decoding: text, as: UTF8.self).contains(expected))
            XCTAssertTrue(String(decoding: json, as: UTF8.self).contains(expected))
        }
        XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("\\u"))
    }

    // MARK: - JSON document shape

    func testExportedJSONValidatesAgainstTheBundledSchemaAndDecodesBack() throws {
        let schema = try XCTUnwrap(try JSONSerialization.jsonObject(with: CanonicalTranscriptSchema.data) as? [String: Any])
        let validator = JSONSchemaFixtureValidator(rootSchema: schema)

        for name in goldenFixtures {
            let original = try transcript(named: name)
            let exported = try TranscriptExporter.export(original, as: .json)
            try validator.validate(try JSONSerialization.jsonObject(with: exported))

            let decoded = try CanonicalTranscriptCodec.decode(exported)
            try CanonicalTranscriptValidator.validate(decoded)
            XCTAssertEqual(decoded, original, "\(name) did not survive a JSON export round trip")
        }
    }

    func testExportedJSONKeepsSchemaRequiredNullsAndOmitsAbsentOptionalFields() throws {
        let withOptionals = try object(from: try TranscriptExporter.export(transcript(named: "one-speaker"), as: .json))
        let withoutOptionals = try object(from: try TranscriptExporter.export(transcript(named: "unknown-speaker"), as: .json))

        let optionalSegment = try XCTUnwrap((withOptionals["segments"] as? [[String: Any]])?.first)
        XCTAssertEqual((optionalSegment["words"] as? [[String: Any]])?.count, 4)
        XCTAssertEqual((withOptionals["subtitle_cue_mappings"] as? [[String: Any]])?.first?["parent_segment_id"] as? String, "segment_001")

        let plainSegment = try XCTUnwrap((withoutOptionals["segments"] as? [[String: Any]])?.first)
        XCTAssertNil(plainSegment["words"])
        XCTAssertNil(withoutOptionals["subtitle_cue_mappings"])
        XCTAssertTrue(plainSegment["speaker_id"] is NSNull, "speaker_id is schema-required and must stay an explicit null")
        XCTAssertTrue(plainSegment["speaker_confidence"] is NSNull, "speaker_confidence is schema-required and must stay an explicit null")
        XCTAssertTrue((withoutOptionals["speakers"] as? [[String: Any]])?.first?["profile_id"] is NSNull)
    }

    func testEmptyRecordingExportsNoSpeechStatusAndAnExplanatoryParagraph() throws {
        let transcript = try transcript(named: "no-speech")
        let json = try object(from: try TranscriptExporter.export(transcript, as: .json))

        XCTAssertEqual(json["status"] as? String, "noSpeech")
        XCTAssertEqual((json["segments"] as? [Any])?.isEmpty, true)
        XCTAssertEqual(try TranscriptExporter.plainText(transcript), TranscriptTextExporter.noSpeechStatement + "\n")
    }

    // MARK: - Speaker labels

    func testEveryFormatUsesTheRevisionSpeakerLabelSnapshot() throws {
        let stale = makeTranscript(
            speakers: [TranscriptSpeaker(id: "speaker_1", profileID: "profile-sarah", identityAssignment: .manual, labelSnapshot: "Sarah")],
            segments: [segment(id: "segment_001", speakerID: "speaker_1", label: "Speaker 1", startMs: 0, endMs: 1_000, text: "Renamed after the segment was written.")]
        )

        XCTAssertEqual(try TranscriptExporter.plainText(stale), "[00:00:00.000 --> 00:00:01.000] Sarah: Renamed after the segment was written.\n")
        let segments = try XCTUnwrap(try object(from: TranscriptExporter.export(stale, as: .json))["segments"] as? [[String: Any]])
        XCTAssertEqual(segments.first?["speaker_label"] as? String, "Sarah")
    }

    func testUnassignableSpeechKeepsItsUnknownSpeakerLabel() throws {
        let exported = try TranscriptExporter.plainText(transcript(named: "unknown-speaker"))
        XCTAssertEqual(exported, "[00:00:01.500 --> 00:00:03.700] [timing approximate] Unknown speaker: This voice could not be assigned.\n")
    }

    // MARK: - Plain-text shape

    func testParagraphsAreSeparatedByABlankLineAndTheFileEndsWithASingleNewline() throws {
        let exported = try TranscriptExporter.plainText(transcript(named: "two-speakers"))
        XCTAssertEqual(exported, """
        [00:00:00.500 --> 00:00:03.100] Alex: Can we begin?

        [00:00:03.300 --> 00:00:06.000] Speaker 2: Yes, I have the notes.

        """)
    }

    func testAnnotationsAppearAfterTheTimestampInAStableOrder() throws {
        let annotated = makeTranscript(
            speakers: [TranscriptSpeaker(id: "speaker_1", identityAssignment: .unmatched, labelSnapshot: "Speaker 1")],
            segments: [segment(id: "segment_001", speakerID: "speaker_1", label: "Speaker 1", startMs: 0, endMs: 1_000, text: "Both flags apply.", overlap: true, timingQuality: .segmentOnly)]
        )

        XCTAssertEqual(
            try TranscriptExporter.plainText(annotated),
            "[00:00:00.000 --> 00:00:01.000] [overlap] [timing approximate] Speaker 1: Both flags apply.\n"
        )
        let unannotated = try TranscriptExporter.plainText(transcript(named: "one-speaker"))
        XCTAssertFalse(unannotated.contains(TranscriptTextExporter.overlapAnnotation))
        XCTAssertFalse(unannotated.contains(TranscriptTextExporter.approximateTimingAnnotation))
    }

    func testOverlappingSegmentsKeepTheirCanonicalTimesAndOrder() throws {
        XCTAssertEqual(try TranscriptExporter.plainText(transcript(named: "overlap")), """
        [00:00:01.000 --> 00:00:05.000] [overlap] Speaker 1: I think we should ship today.

        [00:00:02.800 --> 00:00:05.500] [overlap] Speaker 2: Wait, we need one more test.

        """)
    }

    func testLongTurnsStayOneParagraphEach() throws {
        let exported = try TranscriptExporter.plainText(transcript(named: "long-turns"))
        XCTAssertEqual(exported.components(separatedBy: "\n\n").count, 2)
        XCTAssertTrue(exported.hasPrefix("[00:00:00.000 --> 00:00:29.500] [timing approximate] Speaker 1: This is a deliberately long"))
    }

    // MARK: - Timecodes

    func testTimecodesKeepMillisecondsAndLetHoursExceedTwentyThree() {
        XCTAssertEqual(TranscriptTimecode.string(fromMilliseconds: 0), "00:00:00.000")
        XCTAssertEqual(TranscriptTimecode.string(fromMilliseconds: 1), "00:00:00.001")
        XCTAssertEqual(TranscriptTimecode.string(fromMilliseconds: 3_599_999), "00:59:59.999")
        XCTAssertEqual(TranscriptTimecode.string(fromMilliseconds: 3_600_000), "01:00:00.000")
        XCTAssertEqual(TranscriptTimecode.string(fromMilliseconds: 86_400_000), "24:00:00.000")
        XCTAssertEqual(TranscriptTimecode.string(fromMilliseconds: 90_061_250), "25:01:01.250")
        XCTAssertEqual(TranscriptTimecode.string(fromMilliseconds: 90_061_250, separator: .comma), "25:01:01,250")
    }

    func testHourBoundaryFixturesRenderFullHourCounts() throws {
        XCTAssertTrue(try TranscriptExporter.plainText(transcript(named: "past-one-hour")).hasPrefix("[01:01:01.250 --> 01:01:07.800]"))
        XCTAssertTrue(try TranscriptExporter.plainText(transcript(named: "past-twenty-four-hours")).hasPrefix("[25:01:01.250 --> 25:01:04.500]"))
    }

    // MARK: - Rejected input

    func testExportRejectsAStatusThatContradictsTheSegmentList() throws {
        let emptyButComplete = makeTranscript(speakers: [], segments: [])
        let speechButSilent = makeTranscript(
            status: .noSpeech,
            speakers: [TranscriptSpeaker(id: "speaker_1", identityAssignment: .unmatched, labelSnapshot: "Speaker 1")],
            segments: [segment(id: "segment_001", speakerID: "speaker_1", label: "Speaker 1", startMs: 0, endMs: 1_000, text: "Words exist.")]
        )

        for transcript in [emptyButComplete, speechButSilent] {
            for format in TranscriptExportFormat.allCases {
                XCTAssertThrowsError(try TranscriptExporter.export(transcript, as: format)) { error in
                    guard case TranscriptExportError.statusDoesNotMatchSegments = error else {
                        return XCTFail("expected a status mismatch, got \(error)")
                    }
                }
            }
        }
    }

    func testExportRejectsATranscriptTheCanonicalValidatorWouldReject() {
        let outOfRange = makeTranscript(
            speakers: [TranscriptSpeaker(id: "speaker_1", identityAssignment: .unmatched, labelSnapshot: "Speaker 1")],
            segments: [segment(id: "segment_001", speakerID: "speaker_1", label: "Speaker 1", startMs: 0, endMs: 60_001, text: "Past the source duration.")]
        )

        for format in TranscriptExportFormat.allCases {
            XCTAssertThrowsError(try TranscriptExporter.export(outOfRange, as: format)) { error in
                XCTAssertTrue(error is CanonicalTranscriptValidator.Error, "expected a canonical validation error, got \(error)")
            }
        }
    }

    func testJSONExportRejectsANumberJSONCannotRepresent() {
        let notANumber = makeTranscript(
            speakers: [TranscriptSpeaker(id: "speaker_1", identityAssignment: .unmatched, labelSnapshot: "Speaker 1")],
            segments: [TranscriptSegment(id: "segment_001", speakerID: "speaker_1", speakerLabel: "Speaker 1", startMs: 0, endMs: 1_000, text: "Unrepresentable confidence.", overlap: false, timingQuality: .asrWord, speakerConfidence: .nan)]
        )

        XCTAssertThrowsError(try TranscriptExporter.export(notANumber, as: .json)) { error in
            XCTAssertEqual(error as? TranscriptExportError, .nonFiniteNumber)
        }
        XCTAssertNoThrow(try TranscriptExporter.export(notANumber, as: .plainText), "plain text does not carry confidence and stays exportable")
    }

    // MARK: - Helpers

    private func transcript(named name: String) throws -> CanonicalTranscript {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"), "missing fixture \(name).json")
        return try CanonicalTranscriptCodec.decode(try Data(contentsOf: url))
    }

    private func object(from data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func orderOfKeys(_ keys: [String], in document: String) -> [String] {
        keys
            .compactMap { key -> (String, String.Index)? in
                guard let range = document.range(of: "\"\(key)\"") else { return nil }
                return (key, range.lowerBound)
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    private func makeTranscript(
        status: TranscriptStatus = .complete,
        speakers: [TranscriptSpeaker] = [],
        segments: [TranscriptSegment] = [],
        processingOptions: [String: TranscriptJSONValue] = [:],
        engineRevisions: [String: String] = [:]
    ) -> CanonicalTranscript {
        CanonicalTranscript(
            transcriptID: "exporter-test",
            revision: 4,
            status: status,
            createdAt: "2026-09-03T12:00:00Z",
            source: TranscriptSource(filename: "exporter-test.flac", durationMs: 60_000, checksum: "sha256:exporter"),
            language: "en",
            languageSource: .detected,
            speakers: speakers,
            segments: segments,
            processingOptions: processingOptions,
            engineRevisions: engineRevisions
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
        timingQuality: TranscriptTimingQuality = .asrWord
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            speakerID: speakerID,
            speakerLabel: label,
            startMs: startMs,
            endMs: endMs,
            text: text,
            overlap: overlap,
            timingQuality: timingQuality
        )
    }

    private func assertMatchesGolden(_ exported: String, named name: String, extension ext: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let goldenName = "expected-\(name)"
        if ProcessInfo.processInfo.environment["SCRIBE_REGENERATE_GOLDENS"] == "1" {
            let directory = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/Goldens", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(exported.utf8).write(to: directory.appendingPathComponent("\(goldenName).\(ext)"), options: .atomic)
            return
        }

        let url = try XCTUnwrap(
            Bundle.module.url(forResource: goldenName, withExtension: ext)
                ?? Bundle.module.url(forResource: goldenName, withExtension: ext, subdirectory: "Goldens"),
            "missing golden \(goldenName).\(ext); regenerate with SCRIBE_REGENERATE_GOLDENS=1",
            file: file,
            line: line
        )
        XCTAssertEqual(exported, String(decoding: try Data(contentsOf: url), as: UTF8.self), "\(goldenName).\(ext) drifted", file: file, line: line)
    }
}
