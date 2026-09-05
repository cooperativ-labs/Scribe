import Foundation

/// The elapsed figure a person copies into notes: `MM:SS` below an hour,
/// `H:MM:SS` above it. Shared by the chip, the menu, and the clipboard.
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

    /// `nil` when nothing is being recorded, so Copy Timestamp is a no-op.
    /// Starting still copies `00:00`: the chip already shows a clock then.
    public static func copyableText(state: RecorderState, at date: Date) -> String? {
        if let activity = state.activity {
            return elapsedText(activity.elapsed(at: date))
        }
        if case .starting = state {
            return elapsedText(0)
        }
        return nil
    }
}
