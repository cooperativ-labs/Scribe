import Foundation

/// A complete, non-overlapping partition of the source duration for the
/// transport's speaker-coloured track. Silence and unknown speech are neutral.
enum TranscriptSpeakerTimeline {
    struct Span: Equatable {
        let startMs: Int
        let endMs: Int
        let speakerID: String?

        var durationMs: Int { endMs - startMs }
    }

    static func spans(durationMs: Int, segments: [TranscriptSegment]) -> [Span] {
        let duration = max(0, durationMs)
        guard duration > 0 else { return [] }

        var result: [Span] = []
        var cursor = 0
        for segment in segments.sorted(by: {
            ($0.startMs, $0.endMs, $0.id) < ($1.startMs, $1.endMs, $1.id)
        }) {
            let start = max(0, min(duration, segment.startMs))
            let end = max(0, min(duration, segment.endMs))
            guard end > max(cursor, start) else { continue }
            if start > cursor {
                result.append(Span(startMs: cursor, endMs: start, speakerID: nil))
            }
            let visibleStart = max(cursor, start)
            result.append(Span(startMs: visibleStart, endMs: end, speakerID: segment.speakerID))
            cursor = end
        }
        if cursor < duration {
            result.append(Span(startMs: cursor, endMs: duration, speakerID: nil))
        }
        return result
    }

    static func timeLabel(_ milliseconds: Int, includeHours: Bool) -> String {
        let seconds = max(0, milliseconds) / 1_000
        let hours = seconds / 3_600
        let minutes = includeHours ? (seconds % 3_600) / 60 : seconds / 60
        if includeHours {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds % 60)
        }
        return String(format: "%d:%02d", minutes, seconds % 60)
    }
}
