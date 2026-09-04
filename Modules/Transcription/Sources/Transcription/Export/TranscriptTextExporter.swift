import Foundation

/// Writes the plain-text transcript: one paragraph per canonical segment.
///
///     [00:00:01.250 --> 00:00:04.800] Speaker 1: Let's review the launch plan.
///
/// Annotations follow the timestamp range when they apply: `[overlap]` for a segment that shares
/// time with another speaker, `[timing approximate]` for a segment whose timing came from the
/// coarse fallback rather than validated word timing.
public enum TranscriptTextExporter {
    /// What a recording with no recognized speech says, instead of inventing a segment.
    public static let noSpeechStatement = "No speech was detected in this recording."

    static let overlapAnnotation = "[overlap]"
    static let approximateTimingAnnotation = "[timing approximate]"

    public static func export(_ transcript: CanonicalTranscript) throws -> String {
        try TranscriptExporter.validate(transcript)
        guard !transcript.segments.isEmpty else { return noSpeechStatement + "\n" }

        let labels = TranscriptSpeakerLabels(transcript)
        let paragraphs = transcript.segments.map { paragraph(for: $0, label: labels.label(for: $0)) }
        return paragraphs.joined(separator: "\n\n") + "\n"
    }

    public static func data(_ transcript: CanonicalTranscript) throws -> Data {
        Data(try export(transcript).utf8)
    }

    private static func paragraph(for segment: TranscriptSegment, label: String) -> String {
        var line = "[" + TranscriptTimecode.range(startMs: segment.startMs, endMs: segment.endMs) + "]"
        if segment.overlap { line += " " + overlapAnnotation }
        if segment.timingQuality == .segmentOnly { line += " " + approximateTimingAnnotation }
        line += " \(label): \(singleLine(segment.text))"
        return line
    }

    /// Keeps one segment on one paragraph line without dropping or reordering any word.
    private static func singleLine(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
