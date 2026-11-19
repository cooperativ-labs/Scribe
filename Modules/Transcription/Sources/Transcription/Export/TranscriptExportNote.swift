import Foundation

/// One meeting note as exports and the MCP relay carry it.
///
/// Notes belong to the meeting, not to a transcript revision, so they travel
/// beside `CanonicalTranscript` rather than inside it: the canonical schema
/// and its revision numbers are unchanged by a note edit. Only the note's own
/// words, its recording time and the draft it was written in are exported;
/// the draft's prompt, MCP URL and send history never reach this type.
public struct TranscriptExportNote: Equatable, Sendable {
    public let id: UUID
    public let text: String
    /// Recording time; nil for a note written while capture was paused,
    /// stopping or stopped.
    public let offsetMs: Int?
    /// The draft the note was written in. After a combine, the second
    /// meeting's notes keep their own draft.
    public let draftID: UUID

    public init(id: UUID, text: String, offsetMs: Int?, draftID: UUID) {
        self.id = id
        self.text = text
        self.offsetMs = offsetMs
        self.draftID = draftID
    }

    public init(_ note: MeetingNote, draftID: UUID) {
        self.init(id: note.id, text: note.text, offsetMs: note.recordingOffsetMilliseconds, draftID: draftID)
    }

    /// The note's non-blank lines, trimmed. A note with none is not exported.
    var lines: [String] { Self.lines(of: text) }

    /// `[05:50] first line`, later lines indented under the first.
    var plainText: String? { Self.paragraph(text: text, offsetMs: offsetMs) }

    /// The text exports write: line endings normalised, blank lines and
    /// surrounding spaces dropped, line breaks inside the note kept.
    public var exportedText: String { lines.joined(separator: "\n") }

    static func lines(of text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// A note as people read it, in the TXT export and in the agent handoff:
    /// `[05:50] first line`, later lines indented under the first so a reader
    /// can tell where one note ends; `[--:--]` when the note has no time.
    /// Nil for a note with no words.
    static func paragraph(text: String, offsetMs: Int?) -> String? {
        let lines = lines(of: text)
        guard let first = lines.first else { return nil }
        let stamp = "[\(MeetingNotesText.stampText(offsetMs))] "
        let indent = String(repeating: " ", count: stamp.count)
        return ([stamp + first] + lines.dropFirst().map { indent + $0 }).joined(separator: "\n")
    }

    /// Notes with any words in them, in the order given.
    public static func exportable(_ notes: [TranscriptExportNote]) -> [TranscriptExportNote] {
        notes.filter { !$0.lines.isEmpty }
    }
}

public extension MeetingNotesSidecar {
    /// The notes a run of this meeting exports or relays, each with the
    /// draft it came from.
    ///
    /// A run that names its draft shows what that draft's row shows (its own
    /// notes, then any combined into it). A run without a draft, or whose
    /// draft has no entry here, gets every entry in file order: the notes
    /// still belong to the meeting.
    func exportNotes(forRunDraft draftID: UUID?) -> [TranscriptExportNote] {
        if let draftID, entries.contains(where: { $0.displayDraftID == draftID }) {
            let shown = entries.filter { $0.displayDraftID == draftID }
            let ordered = shown.filter { $0.draftID == draftID } + shown.filter { $0.draftID != draftID }
            return ordered.flatMap { entry in entry.notes.map { TranscriptExportNote($0, draftID: entry.draftID) } }
        }
        return entries.flatMap { entry in entry.notes.map { TranscriptExportNote($0, draftID: entry.draftID) } }
    }

    /// `notes` as a row edited them, attributed to the drafts they will be
    /// saved under. The same rule as `setNotes`: a note keeps its entry, and
    /// a note new to the row joins the entry of the note before it (else the
    /// row's own), so an export taken before the write lands agrees with the
    /// file written after it.
    func exportNotes(_ notes: [MeetingNote], shownBy draftID: UUID, recorderSessionID: UUID) -> [TranscriptExportNote] {
        var copy = self
        copy.setNotes(notes, shownBy: draftID, recorderSessionID: recorderSessionID, revision: 0)
        var source: [UUID: UUID] = [:]
        for entry in copy.entries where entry.displayDraftID == draftID {
            for note in entry.notes { source[note.id] = entry.draftID }
        }
        return notes.map { TranscriptExportNote($0, draftID: source[$0.id] ?? draftID) }
    }
}
