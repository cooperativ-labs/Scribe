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
    public static func pastableText(state: RecorderState, at date: Date) -> String? {
        if let activity = state.activity {
            return "at \(elapsedText(activity.elapsed(at: date)))"
        }
        if case .starting = state {
            return "at \(elapsedText(0))"
        }
        return nil
    }
}
