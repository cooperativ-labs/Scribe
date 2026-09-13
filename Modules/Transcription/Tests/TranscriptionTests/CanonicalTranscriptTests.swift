import Foundation
import XCTest
@testable import Transcription

final class CanonicalTranscriptTests: XCTestCase {
    private let fixtureNames = [
        "one-speaker", "two-speakers", "four-speakers", "overlap", "unknown-speaker",
        "no-speech", "long-turns", "unicode", "past-one-hour", "past-twenty-four-hours",
    ]

    func testFixturesValidateAgainstBundledSchemaAndSemanticValidator() throws {
        let schema = try XCTUnwrap(try JSONSerialization.jsonObject(with: CanonicalTranscriptSchema.data) as? [String: Any])
        let schemaValidator = JSONSchemaFixtureValidator(rootSchema: schema)

        for name in fixtureNames {
            let data = try fixtureData(named: name)
            try schemaValidator.validate(try JSONSerialization.jsonObject(with: data))
            try CanonicalTranscriptValidator.validate(try CanonicalTranscriptCodec.decode(data))
        }
    }

    func testFixtureRoundTripPreservesCanonicalFields() throws {
        let transcript = try CanonicalTranscriptCodec.decode(fixtureData(named: "one-speaker"))
        let roundTripped = try CanonicalTranscriptCodec.decode(CanonicalTranscriptCodec.encode(transcript))

        XCTAssertEqual(roundTripped, transcript)
        XCTAssertEqual(transcript.segments.first?.words?.count, 4)
        XCTAssertEqual(transcript.subtitleCueMappings?.first?.parentSegmentID, "segment_001")
    }

    func testOverlapIsPermittedWhenChronologicalOrderIsStable() throws {
        let transcript = try CanonicalTranscriptCodec.decode(fixtureData(named: "overlap"))
        XCTAssertNoThrow(try CanonicalTranscriptValidator.validate(transcript))
        XCTAssertTrue(transcript.segments.allSatisfy(\.overlap))
    }

    func testValidatorRejectsInvalidBoundsEmptyTextUnknownSpeakerAndOrdering() throws {
        let source = TranscriptSource(filename: "test.wav", durationMs: 1_000, checksum: "sha256:test")
        let speaker = TranscriptSpeaker(id: "speaker_1", identityAssignment: .unmatched, labelSnapshot: "Speaker 1")
        let valid = TranscriptSegment(id: "segment_001", speakerID: "speaker_1", speakerLabel: "Speaker 1", startMs: 0, endMs: 100, text: "Valid.", overlap: false, timingQuality: .asrWord)

        XCTAssertThrowsError(try CanonicalTranscriptValidator.validate(transcript(source: source, speakers: [speaker], segments: [
            TranscriptSegment(id: "bad-bounds", speakerID: "speaker_1", speakerLabel: "Speaker 1", startMs: 500, endMs: 1_001, text: "Out of range.", overlap: false, timingQuality: .asrWord),
        ])))
        XCTAssertThrowsError(try CanonicalTranscriptValidator.validate(transcript(source: source, speakers: [speaker], segments: [
            TranscriptSegment(id: "empty", speakerID: "speaker_1", speakerLabel: "Speaker 1", startMs: 0, endMs: 100, text: "  ", overlap: false, timingQuality: .asrWord),
        ])))
        XCTAssertThrowsError(try CanonicalTranscriptValidator.validate(transcript(source: source, speakers: [speaker], segments: [
            TranscriptSegment(id: "unknown", speakerID: "speaker_missing", speakerLabel: "Missing", startMs: 0, endMs: 100, text: "Who am I?", overlap: false, timingQuality: .asrWord),
        ])))
        XCTAssertThrowsError(try CanonicalTranscriptValidator.validate(transcript(source: source, speakers: [speaker], segments: [
            TranscriptSegment(id: "later", speakerID: "speaker_1", speakerLabel: "Speaker 1", startMs: 200, endMs: 300, text: "Later.", overlap: false, timingQuality: .asrWord),
            valid,
        ])))
    }

    func testNearestInferenceRoundTripsAndMatchesSchema() throws {
        let built = try SpeakerTurnBuilder().build(words: [RecognizedWord(id: "edge", text: "edge", startMs: 500, endMs: 530,
            enclosingStartMs: 500, enclosingEndMs: 530)], diarizedTurns: [DiarizedSpeakerTurn(speakerID: "A", startMs: 0, endMs: 400)])
        let value = transcript(source: TranscriptSource(filename: "test.wav", durationMs: 1_000, checksum: "sha256:test"), speakers: built.speakers, segments: built.segments)
        let data = try CanonicalTranscriptCodec.encode(value)
        XCTAssertEqual(try CanonicalTranscriptCodec.decode(data), value)
        let schema = try XCTUnwrap(try JSONSerialization.jsonObject(with: CanonicalTranscriptSchema.data) as? [String: Any])
        let validator = JSONSchemaFixtureValidator(rootSchema: schema)
        var document = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var segments = try XCTUnwrap(document["segments"] as? [[String: Any]])
        // The schema describes explicit-null export labels; the storage codec
        // omits nil fields. Supply that existing normalization for this check.
        segments[0]["speaker_id"] = NSNull()
        document["segments"] = segments
        try validator.validate(document)
        var inference = try XCTUnwrap(segments[0]["speaker_inference"] as? [String: Any])
        inference["evidence"] = ["type": "nearest_interval", "distance_ms": 251]
        segments[0]["speaker_inference"] = inference
        document["segments"] = segments
        XCTAssertThrowsError(try validator.validate(document))
    }

    private func transcript(source: TranscriptSource, speakers: [TranscriptSpeaker], segments: [TranscriptSegment]) -> CanonicalTranscript {
        CanonicalTranscript(
            transcriptID: "validator-test",
            revision: 1,
            status: .complete,
            createdAt: "2026-09-03T12:00:00Z",
            source: source,
            language: "en",
            languageSource: .detected,
            speakers: speakers,
            segments: segments
        )
    }

    private func fixtureData(named name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }
}
