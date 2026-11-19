import Foundation

/// The elapsed figure a person pastes into notes: `MM:SS` below an hour,
/// `H:MM:SS` above it. Shared by the chip, the menu, and the paste command.
public enum RecordingTimestamp {
    public static func elapsedText(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded(.down))
        let seconds = total % 60
        let minutes = (total / 60) % 60
        let hours = total / 3600
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }

    /// Adds `at ` to the elapsed clock for notes. `nil` when nothing is being
    /// recorded, so Paste Timestamp is a no-op. Starting pastes `at 00:00`.
    /// `offset` seconds are subtracted (floored at zero) because notes are
    /// usually taken just after the moment they refer to.
    public static func pastableText(state: RecorderState, at date: Date, offset: TimeInterval = 0) -> String? {
        if let activity = state.activity {
            return "at \(elapsedText(adjustedElapsed(activity, at: date, offset: offset)))"
        }
        if case .starting = state {
            return "at \(elapsedText(0))"
        }
        return nil
    }

    /// Where in the recording a note written now belongs, in milliseconds:
    /// the capture clock less the Paste Timestamp offset, floored at zero —
    /// the same figure Paste Timestamp would paste, as a number.
    ///
    /// Nil unless audio is being captured right now. Unlike Paste Timestamp,
    /// a paused, starting, stopping or stopped recorder gives no time, so a
    /// note written then is untimed rather than pinned to a moment no audio
    /// was taken. Paused spans are kept in the recording as silence, so the
    /// wall clock since capture started is also the position in the audio.
    public static func noteOffsetMilliseconds(state: RecorderState, at date: Date, offset: TimeInterval = 0) -> Int? {
        guard case .recording(let activity) = state else { return nil }
        return Int((adjustedElapsed(activity, at: date, offset: offset) * 1000).rounded(.down))
    }

    /// `noteOffsetMilliseconds` for a session the caller tracks itself.
    public static func noteOffsetMilliseconds(
        startedAt: Date,
        isPaused: Bool,
        at date: Date,
        offset: TimeInterval = 0
    ) -> Int? {
        guard !isPaused else { return nil }
        let activity = RecordingActivity(sessionID: UUID(), startedAt: startedAt)
        return Int((adjustedElapsed(activity, at: date, offset: offset) * 1000).rounded(.down))
    }

    private static func adjustedElapsed(_ activity: RecordingActivity, at date: Date, offset: TimeInterval) -> TimeInterval {
        max(0, activity.elapsed(at: date) - offset)
    }
}
