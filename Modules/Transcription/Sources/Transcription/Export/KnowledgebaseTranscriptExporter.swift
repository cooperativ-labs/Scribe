import Foundation

/// Writes the interchange document accepted by Knowledgebase's `transcript` resource type.
///
/// Scribe's canonical JSON remains the lossless archive. This projection deliberately contains
/// only fields in `kb.meeting-transcript/1`; Scribe-specific revision and processing details live
/// below `pipeline.scribe`, which Knowledgebase permits as an open metadata object.
public enum KnowledgebaseTranscriptExporter {
    public static let schema = "kb.meeting-transcript/1"
    static let unknownSpeakerID = "SCRIBE_UNKNOWN"

    public static func export(_ transcript: CanonicalTranscript) throws -> String {
        String(decoding: try data(transcript), as: UTF8.self)
    }

    public static func data(_ transcript: CanonicalTranscript) throws -> Data {
        try TranscriptExporter.validate(transcript)
        return try ExportJSONWriter.data(document(for: transcript))
    }

    private static func document(for transcript: CanonicalTranscript) -> ExportJSON {
        let needsUnknownSpeaker = transcript.speakers.isEmpty || transcript.segments.contains { $0.speakerID == nil }
        var speakers = transcript.speakers.map { speaker in
            ExportJSON.object([
                .init("id", .string(speaker.id)),
                .init("label", .string(speaker.labelSnapshot)),
            ])
        }
        if needsUnknownSpeaker {
            speakers.append(.object([
                .init("id", .string(unknownSpeakerID)),
                .init("label", .string("Unknown speaker")),
            ]))
        }

        return .object([
            .init("schema", .string(schema)),
            .init("source", .object([
                // The source checksum is content-stable, so Knowledgebase can use it as its
                // per-meeting idempotency key when the same Scribe export is uploaded again.
                .init("ref", .string(sourceReference(for: transcript))),
                // Scribe v1 records transcript creation, but not recording start, in the
                // canonical revision. This is the closest truthful timestamp available.
                .init("recorded_at", .string(transcript.createdAt)),
                .init("duration_ms", .integer(transcript.source.durationMs)),
            ])),
            .init("language", .string(transcript.language)),
            .init("pipeline", pipeline(transcript)),
            .init("speakers", .array(speakers)),
            .init("turns", .array(transcript.segments.map { segment in
                var members: [ExportJSON.Member] = [
                    .init("speaker_id", .string(segment.speakerID ?? unknownSpeakerID)),
                    .init("start_ms", .integer(segment.startMs)),
                    .init("end_ms", .integer(segment.endMs)),
                    .init("text", .string(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))),
                ]
                if let words = segment.words {
                    members.append(.init("words", .array(words.map { word in
                        .object([
                            .init("text", .string(word.text.trimmingCharacters(in: .whitespacesAndNewlines))),
                            .init("start_ms", .integer(word.startMs)),
                            .init("end_ms", .integer(word.endMs)),
                        ])
                    })))
                }
                return .object(members)
            })),
        ])
    }

    private static func sourceReference(for transcript: CanonicalTranscript) -> String {
        let checksum = transcript.source.checksum.trimmingCharacters(in: .whitespacesAndNewlines)
        return checksum.isEmpty ? "scribe:\(transcript.transcriptID)" : checksum
    }

    private static func pipeline(_ transcript: CanonicalTranscript) -> ExportJSON {
        .object([
            .init("scribe", .object([
                .init("transcript_id", .string(transcript.transcriptID)),
                .init("revision", .integer(transcript.revision)),
                .init("status", .string(transcript.status.rawValue)),
                .init("source_filename", .string(transcript.source.filename)),
                .init("recorded_at_basis", .string("transcript_created_at")),
                .init("engine_revisions", .sortedObject(transcript.engineRevisions.mapValues(ExportJSON.string))),
                .init("processing_options", .sortedObject(transcript.processingOptions.mapValues(value))),
            ])),
        ])
    }

    private static func value(_ value: TranscriptJSONValue) -> ExportJSON {
        switch value {
        case .string(let text): .string(text)
        case .number(let number):
            number.isFinite && number == number.rounded() && abs(number) <= 9_007_199_254_740_992
                ? .integer(Int(number))
                : .double(number)
        case .boolean(let flag): .boolean(flag)
        case .array(let elements): .array(elements.map(self.value))
        case .object(let object): .sortedObject(object.mapValues(self.value))
        case .null: .null
        }
    }
}
