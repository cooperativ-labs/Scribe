import Foundation

/// Writes the canonical schema as the JSON export document.
///
/// The document is the validated canonical transcript itself: schema-required nullable fields are
/// emitted as explicit `null`, optional word timing and subtitle-cue mappings appear only when the
/// revision carries them, and speaker labels come from the revision's snapshot table. Key order is
/// the schema's declaration order and dictionary-backed objects are key-sorted, so two exports of
/// one revision are byte-identical.
public enum TranscriptJSONExporter {
    public static func export(_ transcript: CanonicalTranscript) throws -> String {
        String(decoding: try data(transcript), as: UTF8.self)
    }

    public static func data(_ transcript: CanonicalTranscript) throws -> Data {
        try TranscriptExporter.validate(transcript)
        return try ExportJSONWriter.data(document(for: transcript))
    }

    private static func document(for transcript: CanonicalTranscript) -> ExportJSON {
        let labels = TranscriptSpeakerLabels(transcript)
        var members: [ExportJSON.Member] = [
            .init("schema_version", .integer(transcript.schemaVersion)),
            .init("transcript_id", .string(transcript.transcriptID)),
            .init("revision", .integer(transcript.revision)),
            .init("status", .string(transcript.status.rawValue)),
            .init("created_at", .string(transcript.createdAt)),
            .init("source", source(transcript.source)),
            .init("language", .string(transcript.language)),
            .init("language_source", .string(transcript.languageSource.rawValue)),
            .init("timestamp_unit", .string(transcript.timestampUnit.rawValue)),
            .init("timestamp_origin", .string(transcript.timestampOrigin.rawValue)),
            .init("speakers", .array(transcript.speakers.map(speaker))),
            .init("segments", .array(transcript.segments.map { segment($0, label: labels.label(for: $0)) })),
        ]
        if let mappings = transcript.subtitleCueMappings {
            members.append(.init("subtitle_cue_mappings", .array(mappings.map(cueMapping))))
        }
        members.append(.init("processing_options", .sortedObject(transcript.processingOptions.mapValues(value))))
        members.append(.init("engine_revisions", .sortedObject(transcript.engineRevisions.mapValues(ExportJSON.string))))
        members.append(.init("warnings", .array(transcript.warnings.map(warning))))
        return .object(members)
    }

    private static func source(_ source: TranscriptSource) -> ExportJSON {
        .object([
            .init("filename", .string(source.filename)),
            .init("duration_ms", .integer(source.durationMs)),
            .init("checksum", .string(source.checksum)),
        ])
    }

    private static func speaker(_ speaker: TranscriptSpeaker) -> ExportJSON {
        .object([
            .init("id", .string(speaker.id)),
            .init("profile_id", speaker.profileID.map(ExportJSON.string) ?? .null),
            .init("identity_assignment", .string(speaker.identityAssignment.rawValue)),
            .init("label_snapshot", .string(speaker.labelSnapshot)),
        ])
    }

    private static func segment(_ segment: TranscriptSegment, label: String) -> ExportJSON {
        var members: [ExportJSON.Member] = [
            .init("id", .string(segment.id)),
            .init("speaker_id", segment.speakerID.map(ExportJSON.string) ?? .null),
            .init("speaker_label", .string(label)),
            .init("start_ms", .integer(segment.startMs)),
            .init("end_ms", .integer(segment.endMs)),
            .init("text", .string(segment.text)),
            .init("overlap", .boolean(segment.overlap)),
            .init("timing_quality", .string(segment.timingQuality.rawValue)),
            .init("speaker_confidence", segment.speakerConfidence.map(ExportJSON.double) ?? .null),
        ]
        if let words = segment.words {
            members.append(.init("words", .array(words.map(word))))
        }
        return .object(members)
    }

    private static func word(_ word: TimedWord) -> ExportJSON {
        .object([
            .init("text", .string(word.text)),
            .init("start_ms", .integer(word.startMs)),
            .init("end_ms", .integer(word.endMs)),
        ])
    }

    private static func cueMapping(_ mapping: SubtitleCueMapping) -> ExportJSON {
        .object([
            .init("cue_id", .string(mapping.cueID)),
            .init("parent_segment_id", .string(mapping.parentSegmentID)),
            .init("start_ms", .integer(mapping.startMs)),
            .init("end_ms", .integer(mapping.endMs)),
        ])
    }

    private static func warning(_ warning: TranscriptWarning) -> ExportJSON {
        var members: [ExportJSON.Member] = [
            .init("code", .string(warning.code)),
            .init("message", .string(warning.message)),
        ]
        if let segmentID = warning.segmentID {
            members.append(.init("segment_id", .string(segmentID)))
        }
        return .object(members)
    }

    /// JSON draws no line between integers and floats, so a whole-numbered option is written
    /// without a fractional part to keep an exported document shaped like the one it came from.
    private static func number(from raw: Double) -> ExportJSON {
        guard raw.isFinite, raw == raw.rounded(), abs(raw) <= 9_007_199_254_740_992 else { return .double(raw) }
        return .integer(Int(raw))
    }

    private static func value(_ value: TranscriptJSONValue) -> ExportJSON {
        switch value {
        case .string(let text): return .string(text)
        case .number(let raw): return number(from: raw)
        case .boolean(let flag): return .boolean(flag)
        case .array(let elements): return .array(elements.map(self.value))
        case .object(let object): return .sortedObject(object.mapValues(self.value))
        case .null: return .null
        }
    }
}
