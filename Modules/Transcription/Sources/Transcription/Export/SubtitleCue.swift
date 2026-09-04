import Foundation

/// Readability targets for subtitle cues, taken from the export specification.
///
/// These are targets, not limits. A cue that cannot meet them keeps every word and its true
/// timing and carries a review flag instead; the builder never trims text, retimes speech, or
/// drops a speaker to make a cue fit.
public struct SubtitleReadabilityTargets: Sendable, Equatable {
    public let maximumLines: Int
    public let maximumCharactersPerLine: Int
    public let minimumDurationMs: Int
    public let maximumDurationMs: Int

    /// Two lines of roughly 42 characters, shown for one to six seconds.
    public static let standard = SubtitleReadabilityTargets(
        maximumLines: 2,
        maximumCharactersPerLine: 42,
        minimumDurationMs: 1_000,
        maximumDurationMs: 6_000
    )

    public init(maximumLines: Int, maximumCharactersPerLine: Int, minimumDurationMs: Int, maximumDurationMs: Int) {
        self.maximumLines = maximumLines
        self.maximumCharactersPerLine = maximumCharactersPerLine
        self.minimumDurationMs = minimumDurationMs
        self.maximumDurationMs = maximumDurationMs
    }
}

/// Why a cue needs a human to look at it before the subtitles ship.
///
/// Flags never change the document: the SRT file stays plain text, and the flags travel with the
/// cue model for the review interface to surface.
public enum SubtitleReviewFlag: String, Sendable, Equatable, Hashable, CaseIterable, Comparable {
    /// The turn was too long for one cue but had no validated word boundaries to split on, so the
    /// cue keeps the enclosing segment interval rather than pretending words were aligned.
    case wordTimingUnavailable = "word_timing_unavailable"
    /// The cue is the union of colliding cues, with one prefixed block per speaker.
    case overlapMerged = "overlap_merged"
    /// A displayed line is longer than the per-line target.
    case lineTooLong = "line_too_long"
    /// The cue displays more lines than the target allows.
    case tooManyLines = "too_many_lines"
    /// The cue is on screen for less than the minimum comfortable reading time.
    case durationBelowTarget = "duration_below_target"
    /// The cue is on screen for longer than the maximum comfortable reading time.
    case durationAboveTarget = "duration_above_target"

    /// Declaration order, so a cue's flag list is stable across runs.
    private var order: Int {
        switch self {
        case .wordTimingUnavailable: return 0
        case .overlapMerged: return 1
        case .lineTooLong: return 2
        case .tooManyLines: return 3
        case .durationBelowTarget: return 4
        case .durationAboveTarget: return 5
        }
    }

    public static func < (lhs: SubtitleReviewFlag, rhs: SubtitleReviewFlag) -> Bool { lhs.order < rhs.order }
}

/// One speaker's contribution to a cue.
///
/// A cue built from a single turn has one block. A cue merged out of colliding turns has one
/// block per speaker, each carrying its own prefix, because SRT has no speaker field.
public struct SubtitleCueBlock: Sendable, Equatable {
    /// The display name resolved from the revision's speaker snapshot.
    public let speakerLabel: String
    /// The speech itself, without the prefix.
    public let text: String
    /// The displayed lines, with the speaker prefix on the first.
    public let lines: [String]
    /// The canonical segments whose words this block prints, in chronological order.
    public let parentSegmentIDs: [String]

    public init(speakerLabel: String, text: String, lines: [String], parentSegmentIDs: [String]) {
        self.speakerLabel = speakerLabel
        self.text = text
        self.lines = lines
        self.parentSegmentIDs = parentSegmentIDs
    }
}

/// A display cue: the unit an SRT file numbers, times, and shows.
public struct SubtitleCue: Sendable, Equatable, Identifiable {
    /// The SRT cue number, sequential from 1 across the document.
    public let number: Int
    public let startMs: Int
    public let endMs: Int
    public let blocks: [SubtitleCueBlock]
    public let reviewFlags: [SubtitleReviewFlag]

    public var id: String { SubtitleCue.identifier(number: number) }
    public var durationMs: Int { endMs - startMs }
    public var needsReview: Bool { !reviewFlags.isEmpty }

    /// Every displayed line of the cue, blocks in order.
    public var lines: [String] { blocks.flatMap(\.lines) }

    /// The canonical segments this cue came from, in block order and without repeats.
    public var parentSegmentIDs: [String] {
        var seen = Set<String>()
        return blocks.flatMap(\.parentSegmentIDs).filter { seen.insert($0).inserted }
    }

    /// `cue_001`, matching the cue identifiers the canonical schema's mapping table carries.
    public static func identifier(number: Int) -> String { String(format: "cue_%03d", number) }

    public init(number: Int, startMs: Int, endMs: Int, blocks: [SubtitleCueBlock], reviewFlags: [SubtitleReviewFlag]) {
        self.number = number
        self.startMs = startMs
        self.endMs = endMs
        self.blocks = blocks
        self.reviewFlags = reviewFlags
    }
}

/// Greedy line wrapping at existing word boundaries.
enum SubtitleTextWrapper {
    /// Wraps `text` to `width` characters without breaking a word: a word longer than the target
    /// keeps its own line, because breaking it would change the words on screen.
    static func lines(for text: String, width: Int) -> [String] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var lines: [String] = []
        var current = ""
        for word in words {
            if current.isEmpty {
                current = word
            } else if current.count + 1 + word.count <= width {
                current += " " + word
            } else {
                lines.append(current)
                current = word
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }
}
