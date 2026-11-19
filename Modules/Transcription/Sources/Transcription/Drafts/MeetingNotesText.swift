import Foundation
import Platform

/// The identity a note carries on its characters in the editor: which note it
/// is and where in the recording it was written. Tracked on the text itself,
/// not by paragraph index, so inserting, deleting, undoing and redoing text
/// keeps each note's stamp with the words it belongs to.
public struct MeetingNoteTag: Equatable, Hashable, Sendable {
    public let id: UUID
    public let recordingOffsetMilliseconds: Int?

    public init(id: UUID = UUID(), recordingOffsetMilliseconds: Int?) {
        self.id = id
        self.recordingOffsetMilliseconds = recordingOffsetMilliseconds
    }
}

/// How the notes editor turns text into notes.
///
/// A note is a run of non-empty lines; a blank line ends it, and Return adds
/// a line to the same note (decision 2). The stamping rules live here, apart
/// from AppKit, so they are the same for every surface that edits notes:
///
/// - The first character of a new note takes the time it was typed.
/// - Typing into a note, or pasting into the middle of one, keeps its stamp.
/// - Joining two notes (deleting the blank line between them) keeps the
///   earlier stamp; an untimed note joined to a timed one takes the time.
/// - Splitting a note with a blank line gives both halves the original stamp.
/// - Pasting several notes at once gives each one the paste time.
/// - Undo and redo restore stamps because the stamps travel on the text.
public enum MeetingNotesText {
    /// A note as found in the text: where it is and which tags its characters
    /// carry, in text order, without repeats. `hasUntaggedText` is true when
    /// some of its characters (just typed or pasted) carry none.
    public struct Group: Equatable, Sendable {
        /// UTF-16 range of the note's text, from its first character to the
        /// end of its last non-empty line, newline excluded.
        public let range: NSRange
        public var tags: [MeetingNoteTag]
        public var hasUntaggedText: Bool

        public init(range: NSRange, tags: [MeetingNoteTag] = [], hasUntaggedText: Bool = false) {
            self.range = range
            self.tags = tags
            self.hasUntaggedText = hasUntaggedText
        }
    }

    /// The note ranges in `text`. Lines holding only spaces or tabs count as
    /// blank, so a stray space does not glue two notes together.
    public static func groupRanges(in text: String) -> [NSRange] {
        let string = text as NSString
        var ranges: [NSRange] = []
        var groupStart: Int?
        var groupEnd = 0
        var location = 0
        while location < string.length {
            var lineEnd = 0
            var contentsEnd = 0
            string.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            let line = string.substring(with: NSRange(location: location, length: contentsEnd - location))
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if let start = groupStart {
                    ranges.append(NSRange(location: start, length: groupEnd - start))
                    groupStart = nil
                }
            } else {
                if groupStart == nil { groupStart = location }
                groupEnd = contentsEnd
            }
            guard lineEnd > location else { break }
            location = lineEnd
        }
        if let start = groupStart {
            ranges.append(NSRange(location: start, length: groupEnd - start))
        }
        return ranges
    }

    /// Decides each group's tag after an edit.
    ///
    /// - Parameters:
    ///   - groups: The groups in text order with the tags found on them.
    ///   - clock: The recording time to give a new note, read once per new
    ///     note. Nil while capture is paused, stopping or stopped.
    public static func resolve(
        _ groups: [Group],
        clock: () -> Int?,
        makeID: () -> UUID = UUID.init
    ) -> [MeetingNoteTag] {
        var used = Set<UUID>()
        return groups.map { group in
            guard !group.tags.isEmpty else {
                let tag = MeetingNoteTag(id: makeID(), recordingOffsetMilliseconds: clock())
                used.insert(tag.id)
                return tag
            }
            // A join keeps the earliest time; the first such note in the
            // text keeps its identity.
            let kept = group.tags.enumerated().min { lhs, rhs in
                switch (lhs.element.recordingOffsetMilliseconds, rhs.element.recordingOffsetMilliseconds) {
                case let (left?, right?) where left != right: return left < right
                case (_?, nil): return true
                case (nil, _?): return false
                default: return lhs.offset < rhs.offset
                }
            }!.element
            // A split leaves the same identity on both halves: the first half
            // keeps it, the second becomes a new note with the same time.
            guard used.insert(kept.id).inserted else {
                let split = MeetingNoteTag(id: makeID(), recordingOffsetMilliseconds: kept.recordingOffsetMilliseconds)
                used.insert(split.id)
                return split
            }
            return kept
        }
    }

    /// The notes `text` holds, given the tag decided for each group.
    public static func notes(in text: String, ranges: [NSRange], tags: [MeetingNoteTag]) -> [MeetingNote] {
        let string = text as NSString
        return zip(ranges, tags).map { range, tag in
            MeetingNote(
                id: tag.id,
                text: string.substring(with: range),
                recordingOffsetMilliseconds: tag.recordingOffsetMilliseconds
            )
        }
    }

    /// The text that shows `notes`: one note per paragraph, a blank line
    /// between them. Blank lines inside a note (which the editor never
    /// writes) are dropped so the round trip gives the same notes back.
    public static func text(for notes: [MeetingNote]) -> String {
        notes.map(normalized(_:)).joined(separator: "\n\n")
    }

    /// The UTF-16 ranges `text(for:)` puts each note at.
    public static func ranges(for notes: [MeetingNote]) -> [NSRange] {
        var location = 0
        return notes.map { note in
            let length = (normalized(note) as NSString).length
            defer { location += length + 2 }
            return NSRange(location: location, length: length)
        }
    }

    private static func normalized(_ note: MeetingNote) -> String {
        note.text
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "\n")
    }

    // MARK: - Presentation

    /// The gutter's figure: `05:50`, `1:02:03`, or `--:--` for an untimed note.
    public static func stampText(_ offsetMilliseconds: Int?) -> String {
        guard let offsetMilliseconds else { return "--:--" }
        return RecordingTimestamp.elapsedText(TimeInterval(offsetMilliseconds) / 1000)
    }

    /// What VoiceOver says for a note's stamp: "Note at 5 minutes, 50 seconds".
    public static func accessibilityLabel(_ offsetMilliseconds: Int?) -> String {
        guard let offsetMilliseconds else { return "Note without a recording time" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .full
        formatter.zeroFormattingBehavior = .dropAll
        let seconds = TimeInterval(offsetMilliseconds / 1000)
        let spoken = seconds < 1 ? "0 seconds" : (formatter.string(from: seconds) ?? stampText(offsetMilliseconds))
        return "Note at \(spoken)"
    }
}
