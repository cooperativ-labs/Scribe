import Foundation

/// Writes the SubRip subtitle document for one saved transcript revision.
///
///     1
///     00:00:01,250 --> 00:00:04,800
///     Speaker 1: Let's review the launch plan.
///
/// SRT has no speaker field, so every cue prints its speaker as part of the text, even when the
/// previous cue was the same person. The document stays plain text: review flags describe cues
/// that miss a readability target, but they travel on the cue model for the review interface
/// rather than as markup a player would show.
public enum TranscriptSRTExporter {
    public static func export(_ transcript: CanonicalTranscript) throws -> String {
        try document(for: SubtitleCueBuilder.cues(for: transcript))
    }

    public static func data(_ transcript: CanonicalTranscript) throws -> Data {
        Data(try export(transcript).utf8)
    }

    /// Renders built cues, checking the cue list going in and the document coming out.
    ///
    /// A recording with no speech has no cues and writes an empty file; the explanatory status
    /// belongs to the UI, because any wording in the file would show up as a subtitle.
    public static func document(for cues: [SubtitleCue]) throws -> String {
        try SubtitleCueValidator.validate(cues)
        guard !cues.isEmpty else { return "" }
        let document = cues.map(block).joined(separator: "\n\n") + "\n"
        try SubtitleCueValidator.validate(document: document)
        return document
    }

    private static func block(for cue: SubtitleCue) -> String {
        ([
            String(cue.number),
            TranscriptTimecode.range(startMs: cue.startMs, endMs: cue.endMs, separator: .comma),
        ] + cue.lines).joined(separator: "\n")
    }
}
