import Foundation

/// The document formats an export action can produce from a saved transcript revision.
public enum TranscriptExportFormat: String, CaseIterable, Sendable, Hashable {
    case plainText = "txt"
    case json
    case subtitles = "srt"

    public var fileExtension: String { rawValue }
}

public enum TranscriptExportError: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    /// The revision's status and segment list disagree, so no format can describe it honestly.
    case statusDoesNotMatchSegments(status: TranscriptStatus, segmentCount: Int)
    /// A stored processing option or confidence held infinity or NaN, which JSON cannot represent.
    case nonFiniteNumber

    public var description: String {
        switch self {
        case .statusDoesNotMatchSegments(let status, let count):
            return "Transcript status \(status.rawValue) does not match a segment count of \(count)."
        case .nonFiniteNumber:
            return "A transcript number was infinite or NaN and cannot be exported as JSON."
        }
    }
}

/// Renders one saved transcript revision as an export document.
///
/// Exporting is a pure transformation: it never reruns transcription or diarization, never reads
/// another revision, and never mutates the transcript. Every format resolves speaker display names
/// through the revision's `label_snapshot` table so the documents agree with each other. All output
/// is UTF-8.
public enum TranscriptExporter {
    public static func export(_ transcript: CanonicalTranscript, as format: TranscriptExportFormat) throws -> Data {
        switch format {
        case .plainText: return try TranscriptTextExporter.data(transcript)
        case .json: return try TranscriptJSONExporter.data(transcript)
        case .subtitles: return try TranscriptSRTExporter.data(transcript)
        }
    }

    public static func plainText(_ transcript: CanonicalTranscript) throws -> String {
        try TranscriptTextExporter.export(transcript)
    }

    public static func json(_ transcript: CanonicalTranscript) throws -> String {
        try TranscriptJSONExporter.export(transcript)
    }

    public static func srt(_ transcript: CanonicalTranscript) throws -> String {
        try TranscriptSRTExporter.export(transcript)
    }

    /// The `subtitle_cue_mappings` rows describing the SRT this revision would export, for a
    /// caller that wants the JSON document to name the segment behind each cue.
    public static func subtitleCueMappings(_ transcript: CanonicalTranscript) throws -> [SubtitleCueMapping] {
        SubtitleCueBuilder.mappings(for: try SubtitleCueBuilder.cues(for: transcript))
    }

    /// Checks every invariant an export relies on before any format writes a byte.
    static func validate(_ transcript: CanonicalTranscript) throws {
        try CanonicalTranscriptValidator.validate(transcript)
        let isNoSpeech = transcript.status == .noSpeech
        guard isNoSpeech == transcript.segments.isEmpty else {
            throw TranscriptExportError.statusDoesNotMatchSegments(status: transcript.status, segmentCount: transcript.segments.count)
        }
    }
}
