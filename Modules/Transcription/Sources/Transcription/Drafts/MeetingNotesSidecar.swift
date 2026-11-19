import Foundation

/// One draft's notes inside a meeting's `meeting-notes.json`.
public struct MeetingNotesEntry: Codable, Sendable, Equatable {
    /// The draft the notes were written in.
    public let draftID: UUID
    public let recorderSessionID: UUID
    /// The draft revision the notes were attached from. Lets reconciliation
    /// tell a finished attachment from one a crash cut short.
    public var attachedRevision: Int
    /// The draft whose row shows these notes, when it is not `draftID`: set
    /// on the second meeting's notes after two recordings are combined, so
    /// each note keeps its source draft while the combined meeting shows
    /// both sets.
    public var ownerDraftID: UUID?
    public var notes: [MeetingNote]

    public init(
        draftID: UUID,
        recorderSessionID: UUID,
        attachedRevision: Int,
        ownerDraftID: UUID? = nil,
        notes: [MeetingNote]
    ) {
        self.draftID = draftID
        self.recorderSessionID = recorderSessionID
        self.attachedRevision = attachedRevision
        self.ownerDraftID = ownerDraftID
        self.notes = notes
    }

    /// The row these notes appear on.
    public var displayDraftID: UUID { ownerDraftID ?? draftID }
}

/// The notes that belong to one meeting directory, after transcription.
///
/// Notes belong to the meeting, not to a run: reprocessing and
/// retranscribing make new runs in the same directory and show the same
/// notes without copying them. Entries are keyed by draft because two
/// recordings with identical audio share one content-addressed directory.
/// Prompt, MCP URL and send state are never written here.
public struct MeetingNotesSidecar: Codable, Sendable, Equatable {
    public static let fileName = "meeting-notes.json"
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public var entries: [MeetingNotesEntry]

    public init(entries: [MeetingNotesEntry] = []) {
        schemaVersion = Self.currentSchemaVersion
        self.entries = entries
    }

    public func entry(forDraft draftID: UUID) -> MeetingNotesEntry? {
        entries.first { $0.draftID == draftID }
    }

    /// The notes a draft's row shows: its own entry first, then any entries
    /// combined into it, each in the order written.
    public func notes(shownBy draftID: UUID) -> [MeetingNote] {
        let shown = entries.filter { $0.displayDraftID == draftID }
        return shown.filter { $0.draftID == draftID }.flatMap(\.notes)
            + shown.filter { $0.draftID != draftID }.flatMap(\.notes)
    }

    /// Writes or replaces one draft's entry.
    public mutating func upsert(_ entry: MeetingNotesEntry) {
        if let index = entries.firstIndex(where: { $0.draftID == entry.draftID }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
    }

    /// Replaces what a row shows with `notes`, keeping each note in the
    /// entry it came from. A note new to the row joins the entry of the note
    /// before it in the text (else the row's own), so each entry stays one
    /// contiguous run and the shown order survives the round trip.
    public mutating func setNotes(
        _ notes: [MeetingNote],
        shownBy draftID: UUID,
        recorderSessionID: UUID,
        revision: Int
    ) {
        let isOwn = { (entry: MeetingNotesEntry) in entry.draftID == draftID && entry.displayDraftID == draftID }
        if !entries.contains(where: isOwn), !notes.isEmpty {
            entries.append(MeetingNotesEntry(draftID: draftID, recorderSessionID: recorderSessionID, attachedRevision: revision, notes: []))
        }
        // Own entry first, matching the order `notes(shownBy:)` shows.
        let shown = entries.indices.filter { isOwn(entries[$0]) }
            + entries.indices.filter { entries[$0].displayDraftID == draftID && !isOwn(entries[$0]) }
        var source: [UUID: Int] = [:]
        for index in shown {
            for note in entries[index].notes { source[note.id] = index }
        }
        let own = entries.firstIndex(where: isOwn)
        var distributed: [Int: [MeetingNote]] = [:]
        var current = own ?? shown.first
        for note in notes {
            if let index = source[note.id] { current = index }
            guard let target = current else { continue }
            distributed[target, default: []].append(note)
        }
        for index in shown { entries[index].notes = distributed[index] ?? [] }
    }

    /// The same entries with every timed note moved later by `milliseconds`;
    /// untimed notes stay untimed.
    public func shifted(byMilliseconds milliseconds: Int) -> MeetingNotesSidecar {
        var shifted = self
        for index in shifted.entries.indices {
            shifted.entries[index].notes = shifted.entries[index].notes.map { note in
                var note = note
                note.recordingOffsetMilliseconds = note.recordingOffsetMilliseconds.map { $0 + milliseconds }
                return note
            }
        }
        return shifted
    }
}

/// Reads and writes `meeting-notes.json` in a meeting directory.
public enum MeetingNotesSidecarFile {
    public enum FileError: LocalizedError, Equatable {
        /// The file is there but is not a notes file this version can read.
        /// It is left alone rather than overwritten.
        case unreadable(String)
        /// The meeting directory no longer exists (the meeting was deleted).
        case meetingMissing

        public var errorDescription: String? {
            switch self {
            case .unreadable(let detail): "The meeting's notes could not be read (\(detail))."
            case .meetingMissing: "This meeting no longer exists."
            }
        }
    }

    public static func url(inMeeting meetingDirectory: URL) -> URL {
        meetingDirectory.appending(path: MeetingNotesSidecar.fileName)
    }

    /// The meeting's notes; an empty sidecar when it has none yet.
    public static func read(meetingDirectory: URL) throws -> MeetingNotesSidecar {
        let url = url(inMeeting: meetingDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else { return MeetingNotesSidecar() }
        do {
            let sidecar = try JSONDecoder().decode(MeetingNotesSidecar.self, from: Data(contentsOf: url))
            guard sidecar.schemaVersion <= MeetingNotesSidecar.currentSchemaVersion else {
                throw FileError.unreadable("written by a newer version of Scribe")
            }
            return sidecar
        } catch let error as FileError {
            throw error
        } catch {
            throw FileError.unreadable(error.localizedDescription)
        }
    }

    public static func encode(_ sidecar: MeetingNotesSidecar) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(sidecar)
    }

    /// Writes owner-only (0600) through a temporary file and a rename. Never
    /// creates the meeting directory: a write that arrives after the meeting
    /// was deleted must not bring an empty one back.
    public static func write(_ sidecar: MeetingNotesSidecar, meetingDirectory: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: meetingDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FileError.meetingMissing
        }
        try MeetingDraftStore.writePrivateFile(try encode(sidecar), url(inMeeting: meetingDirectory))
    }
}
