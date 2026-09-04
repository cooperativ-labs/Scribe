import Foundation

/// Millisecond timecode formatting shared by every export format.
///
/// Hours are never truncated: a source longer than a day renders `25:01:01.250` rather than
/// wrapping to `01:01:01.250`.
public enum TranscriptTimecode {
    /// The fractional separator a format uses between seconds and milliseconds.
    public enum FractionSeparator: String, Sendable {
        /// `HH:MM:SS.mmm`, used by TXT and JSON-adjacent displays.
        case dot = "."
        /// `HH:MM:SS,mmm`, required by SRT.
        case comma = ","
    }

    public static func string(fromMilliseconds milliseconds: Int, separator: FractionSeparator = .dot) -> String {
        let clamped = max(0, milliseconds)
        let hours = clamped / 3_600_000
        let minutes = (clamped % 3_600_000) / 60_000
        let seconds = (clamped % 60_000) / 1_000
        let fraction = clamped % 1_000
        return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, seconds, separator.rawValue, fraction)
    }

    /// The `[start --> end]` range used by the TXT format.
    public static func range(startMs: Int, endMs: Int, separator: FractionSeparator = .dot) -> String {
        "\(string(fromMilliseconds: startMs, separator: separator)) --> \(string(fromMilliseconds: endMs, separator: separator))"
    }

    /// Reads a `HH:MM:SS.mmm` or `HH:MM:SS,mmm` timecode back, returning `nil` for anything a
    /// subtitle player would reject. Hours may run past 23 but keep at least two digits.
    public static func milliseconds(from text: String, separator: FractionSeparator = .dot) -> Int? {
        let fields = text.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 3 else { return nil }
        let tail = fields[2].split(separator: Character(separator.rawValue), omittingEmptySubsequences: false)
        guard tail.count == 2,
              let hours = decimal(fields[0], minimumDigits: 2),
              let minutes = decimal(fields[1], digits: 2), minutes < 60,
              let seconds = decimal(tail[0], digits: 2), seconds < 60,
              let fraction = decimal(tail[1], digits: 3) else { return nil }
        return hours * 3_600_000 + minutes * 60_000 + seconds * 1_000 + fraction
    }

    private static func decimal(_ text: Substring, digits: Int) -> Int? {
        text.count == digits ? decimal(text) : nil
    }

    private static func decimal(_ text: Substring, minimumDigits: Int) -> Int? {
        text.count >= minimumDigits ? decimal(text) : nil
    }

    private static func decimal(_ text: Substring) -> Int? {
        guard text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(text)
    }
}
