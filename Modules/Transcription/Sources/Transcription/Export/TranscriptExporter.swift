import Foundation
import UniformTypeIdentifiers

/// The document formats an export action can produce from a saved transcript revision.
public enum TranscriptExportFormat: String, CaseIterable, Sendable, Hashable {
    case plainText = "txt"
    case json
    case knowledgebase = "kb.json"
    case subtitles = "srt"

    public var fileExtension: String { rawValue }

    /// The type a Save panel offers for this format, so the exported file is a document rather than a folder.
    public var contentType: UTType {
        switch self {
        case .plainText: .plainText
        case .json, .knowledgebase: .json
        case .subtitles: UTType(filenameExtension: fileExtension) ?? .plainText
        }
    }

    public var displayName: String {
        switch self {
        case .plainText: "TXT"
        case .json: "JSON"
        case .knowledgebase: "Knowledgebase JSON"
        case .subtitles: "SRT"
        }
    }
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
///
/// `notes` are the meeting's notes, which belong to the meeting rather than the revision. TXT adds
/// a Notes section after the transcript, Scribe JSON a top-level `notes` array and Knowledgebase
/// JSON a `notes` array in its `ai.scribe` pipeline extension; SRT stays subtitles only. With no
/// notes every format is exactly what it was before notes existed.
public enum TranscriptExporter {
    public static func export(
        _ transcript: CanonicalTranscript,
        as format: TranscriptExportFormat,
        notes: [TranscriptExportNote] = []
    ) throws -> Data {
        switch format {
        case .plainText: return try TranscriptTextExporter.data(transcript, notes: notes)
        case .json: return try TranscriptJSONExporter.data(transcript, notes: notes)
        case .knowledgebase: return try KnowledgebaseTranscriptExporter.data(transcript, notes: notes)
        case .subtitles: return try TranscriptSRTExporter.data(transcript)
        }
    }

    public static func plainText(_ transcript: CanonicalTranscript, notes: [TranscriptExportNote] = []) throws -> String {
        try TranscriptTextExporter.export(transcript, notes: notes)
    }

    public static func json(_ transcript: CanonicalTranscript, notes: [TranscriptExportNote] = []) throws -> String {
        try TranscriptJSONExporter.export(transcript, notes: notes)
    }

    public static func knowledgebaseJSON(_ transcript: CanonicalTranscript, notes: [TranscriptExportNote] = []) throws -> String {
        try KnowledgebaseTranscriptExporter.export(transcript, notes: notes)
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
