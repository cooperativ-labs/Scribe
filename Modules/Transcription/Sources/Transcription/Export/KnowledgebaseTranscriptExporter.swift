import Foundation

/// Writes the file-upload envelope accepted by Knowledgebase's transcript importer.
///
/// Scribe's canonical JSON remains the lossless archive. This projection intentionally follows
/// `kb.transcript-upload/1`: Knowledgebase derives its canonical resource identity and speaker IDs
/// while importing the file. Scribe-specific provenance lives in the namespaced `ai.scribe`
/// pipeline extension.
///
/// Meeting notes ride in that extension as `ai.scribe.notes`, an array of `{ id, text, offset_ms }`.
/// The upload contract rejects unknown top-level and segment members but accepts any object under
/// a namespaced extension, and Knowledgebase keeps `pipeline.extensions` verbatim on the imported
/// transcript, so notes need no new schema version and an importer that predates them still
/// accepts the file. Without notes the member is absent.
public enum KnowledgebaseTranscriptExporter {
    public static let schema = "kb.transcript-upload/1"

    public static func export(_ transcript: CanonicalTranscript, notes: [TranscriptExportNote] = []) throws -> String {
        String(decoding: try data(transcript, notes: notes), as: UTF8.self)
    }

    public static func data(_ transcript: CanonicalTranscript, notes: [TranscriptExportNote] = []) throws -> Data {
        try TranscriptExporter.validate(transcript)
        return try ExportJSONWriter.data(document(for: transcript, notes: TranscriptExportNote.exportable(notes)))
    }

    private static func document(for transcript: CanonicalTranscript, notes: [TranscriptExportNote]) -> ExportJSON {
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
            .init("pipeline", pipeline(transcript, notes: notes)),
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

    private static func pipeline(_ transcript: CanonicalTranscript, notes: [TranscriptExportNote]) -> ExportJSON {
        var scribe: [ExportJSON.Member] = [
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
        ]
        if !notes.isEmpty {
            scribe.append(.init("notes", .array(notes.map { note in
                .object([
                    .init("id", .string(note.id.uuidString.lowercased())),
                    .init("text", .string(note.exportedText)),
                    .init("offset_ms", note.offsetMs.map(ExportJSON.integer) ?? .null),
                ])
            })))
        }
        return .object([
            .init("producer", .object([
                .init("name", .string("scribe")),
            ])),
            .init("extensions", .object([
                .init("ai.scribe", .object(scribe)),
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
