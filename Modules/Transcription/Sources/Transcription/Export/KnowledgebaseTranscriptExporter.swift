import Foundation

/// Writes the file-upload envelope accepted by Knowledgebase's transcript importer.
///
/// Scribe's canonical JSON remains the lossless archive. This projection intentionally follows
/// `kb.transcript-upload/1`: Knowledgebase derives its canonical resource identity and speaker IDs
/// while importing the file. Scribe-specific provenance lives in the namespaced `ai.scribe`
/// pipeline extension.
public enum KnowledgebaseTranscriptExporter {
    public static let schema = "kb.transcript-upload/1"

    public static func export(_ transcript: CanonicalTranscript) throws -> String {
        String(decoding: try data(transcript), as: UTF8.self)
    }

    public static func data(_ transcript: CanonicalTranscript) throws -> Data {
        try TranscriptExporter.validate(transcript)
        return try ExportJSONWriter.data(document(for: transcript))
    }

    private static func document(for transcript: CanonicalTranscript) -> ExportJSON {
        .object([
            .init("schema", .string(schema)),
            .init("recording", .object([
                // Canonical transcript v1 does not retain the real-world recording start.
                // Omitting recorded_at lets Knowledgebase use the meeting date when available.
                .init("duration_ms", .integer(transcript.source.durationMs)),
            ])),
            .init("transcript", .object([
                .init("processed_at", .string(transcript.createdAt)),
                .init("language", .string(transcript.language)),
            ])),
            .init("pipeline", pipeline(transcript)),
            .init("segments", .array(segments(transcript))),
        ])
    }

    private static func segments(_ transcript: CanonicalTranscript) -> [ExportJSON] {
        guard !transcript.segments.isEmpty else {
            // The upload contract requires at least one segment and explicitly permits
            // speakerless non-speech spans. Preserve a no-speech recording as such a span.
            return [.object([
                .init("speaker", .null),
                .init("text", .string("[silence]")),
                .init("start_ms", .integer(0)),
                .init("end_ms", .integer(transcript.source.durationMs)),
            ])]
        }

        let labels = TranscriptSpeakerLabels(transcript)
        return transcript.segments.map { segment in
            .object([
                .init(
                    "speaker",
                    segment.speakerID == nil
                        ? .null
                        : .string(labels.label(for: segment).trimmingCharacters(in: .whitespacesAndNewlines))
                ),
                .init("text", .string(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))),
                .init("start_ms", .integer(segment.startMs)),
                .init("end_ms", .integer(segment.endMs)),
            ])
        }
    }

    private static func pipeline(_ transcript: CanonicalTranscript) -> ExportJSON {
        .object([
            .init("producer", .object([
                .init("name", .string("scribe")),
            ])),
            .init("extensions", .object([
                .init("ai.scribe", .object([
                    .init("transcript_id", .string(transcript.transcriptID)),
                    .init("revision", .integer(transcript.revision)),
                    .init("status", .string(transcript.status.rawValue)),
                    .init("source_filename", .string(transcript.source.filename)),
                    .init("source_checksum", .string(transcript.source.checksum)),
                    .init("language_source", .string(transcript.languageSource.rawValue)),
                    .init("timestamp_unit", .string(transcript.timestampUnit.rawValue)),
                    .init("timestamp_origin", .string(transcript.timestampOrigin.rawValue)),
                    .init("engine_revisions", .sortedObject(transcript.engineRevisions.mapValues(ExportJSON.string))),
                    .init("processing_options", .sortedObject(transcript.processingOptions.mapValues(value))),
                ])),
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
