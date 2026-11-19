import Foundation

/// The durable home of meeting drafts: one owner-only JSON file per draft in
/// `~/Library/Application Support/Scribe/drafts`.
///
/// Every change is applied in memory at once and written after a short
/// per-draft quiet period, so typing does not write a file per keystroke.
/// Callers flush at the points where losing an edit would matter — stop,
/// handoff, send, editor close and termination. A failed write leaves the
/// draft "Not saved" with the edit still in memory until a retry succeeds;
/// forced termination can lose at most one quiet period of edits.
public actor MeetingDraftStore {
    public typealias FileWriter = @Sendable (_ data: Data, _ destination: URL) throws -> Void

    public enum StoreError: LocalizedError, Equatable {
        case unknownDraft(UUID)
        /// The change was made against an older copy of the draft.
        case staleRevision(expected: Int, actual: Int)

        public var errorDescription: String? {
            switch self {
            case .unknownDraft: "This draft no longer exists."
            case .staleRevision: "This draft was changed elsewhere. Try again."
            }
        }
    }

    /// What changed, for clients that mirror the store on the main actor.
    public struct Change: Sendable, Equatable {
        public let draftID: UUID
        /// Nil once the draft was deleted.
        public let draft: MeetingDraft?
        public let saveState: MeetingDraftSaveState
    }

    public static let defaultDebounce: Duration = .milliseconds(500)

    public let directoryURL: URL
    private let debounce: Duration
    private let writeFile: FileWriter
    private var drafts: [UUID: MeetingDraft] = [:]
    private var saveStates: [UUID: MeetingDraftSaveState] = [:]
    private var dirty: Set<UUID> = []
    private var pendingWrites: [UUID: Task<Void, Never>] = [:]
    private var observers: [UUID: AsyncStream<Change>.Continuation] = [:]
    /// Files present at load that could not be decoded. Left on disk untouched.
    public private(set) var unreadableFiles: [URL] = []

    /// `~/Library/Application Support/Scribe/drafts`.
    public static func applicationSupportDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        return base.appending(path: "Scribe/drafts", directoryHint: .isDirectory)
    }

    public init(
        directoryURL: URL = MeetingDraftStore.applicationSupportDirectory(),
        debounce: Duration = MeetingDraftStore.defaultDebounce,
        writeFile: @escaping FileWriter = MeetingDraftStore.writePrivateFile
    ) {
        self.directoryURL = directoryURL
        self.debounce = debounce
        self.writeFile = writeFile
        let (loaded, unreadable) = Self.readAll(in: directoryURL)
        drafts = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { first, second in
            first.revision >= second.revision ? first : second
        })
        saveStates = Dictionary(uniqueKeysWithValues: drafts.keys.map { ($0, .saved) })
        unreadableFiles = unreadable
    }

    // MARK: - Reading

    public func all() -> [MeetingDraft] {
        drafts.values.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    public func draft(id: UUID) -> MeetingDraft? { drafts[id] }

    /// The draft opened for a recorder session, if one was.
    public func draft(forSession sessionID: UUID) -> MeetingDraft? {
        drafts.values.first { $0.recorderSessionID == sessionID }
    }

    public func saveState(id: UUID) -> MeetingDraftSaveState { saveStates[id] ?? .saved }

    public func changes() -> AsyncStream<Change> {
        let token = UUID()
        return AsyncStream { continuation in
            observers[token] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(token) }
            }
        }
    }

    // MARK: - Changing

    /// Opens the draft for a recorder session, or returns the one already
    /// open. Idempotent by session ID, so the `.recording` state that resume
    /// re-emits, or a duplicate start event, never makes a second draft.
    /// A new draft is written immediately rather than after the quiet period.
    @discardableResult
    public func open(
        sessionID: UUID,
        defaultTitle: String,
        handoff: MeetingHandoffSettings = MeetingHandoffSettings(),
        now: Date = Date()
    ) -> (draft: MeetingDraft, created: Bool) {
        if let existing = draft(forSession: sessionID) { return (existing, false) }
        let draft = MeetingDraft(recorderSessionID: sessionID, createdAt: now, defaultTitle: defaultTitle, handoff: handoff)
        drafts[draft.id] = draft
        dirty.insert(draft.id)
        write(draft.id)
        return (draft, true)
    }

    /// Applies one change and increments the revision.
    ///
    /// `expectedRevision`, when given, is the revision the caller read before
    /// it started; a draft changed since then is not overwritten. `flush`
    /// writes now instead of after the quiet period.
    @discardableResult
    public func update(
        id: UUID,
        expectedRevision: Int? = nil,
        flush: Bool = false,
        _ change: @Sendable (inout MeetingDraft) -> Void
    ) throws -> MeetingDraft {
        guard var draft = drafts[id] else { throw StoreError.unknownDraft(id) }
        if let expectedRevision, expectedRevision != draft.revision {
            throw StoreError.staleRevision(expected: expectedRevision, actual: draft.revision)
        }
        let before = draft
        change(&draft)
        guard draft != before else { return draft }
        draft.revision = before.revision + 1
        drafts[id] = draft
        dirty.insert(id)
        if flush {
            write(id)
        } else {
            scheduleWrite(id)
            notify(id)
        }
        return draft
    }

    /// Writes any pending change to this draft now.
    @discardableResult
    public func flush(id: UUID) -> MeetingDraftSaveState {
        if dirty.contains(id) { write(id) }
        return saveState(id: id)
    }

    /// Writes every pending change now; used at termination.
    public func flushAll() {
        for id in dirty { write(id) }
    }

    /// Tries a failed write again.
    @discardableResult
    public func retrySave(id: UUID) -> MeetingDraftSaveState {
        guard drafts[id] != nil else { return .saved }
        dirty.insert(id)
        write(id)
        return saveState(id: id)
    }

    /// Removes the draft and its file. Missing files are not an error.
    public func delete(id: UUID) throws {
        pendingWrites.removeValue(forKey: id)?.cancel()
        let url = fileURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        drafts[id] = nil
        saveStates[id] = nil
        dirty.remove(id)
        for observer in observers.values {
            observer.yield(Change(draftID: id, draft: nil, saveState: .saved))
        }
    }

    // MARK: - Writing

    public func fileURL(for id: UUID) -> URL {
        directoryURL.appending(path: "\(id.uuidString).json")
    }

    private func scheduleWrite(_ id: UUID) {
        pendingWrites[id]?.cancel()
        let debounce = debounce
        pendingWrites[id] = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self?.writeIfDirty(id)
        }
    }

    private func writeIfDirty(_ id: UUID) {
        guard dirty.contains(id) else { return }
        write(id)
    }

    private func write(_ id: UUID) {
        pendingWrites.removeValue(forKey: id)?.cancel()
        guard let draft = drafts[id] else { return }
        do {
            try writeFile(try Self.encode(draft), fileURL(for: id))
            dirty.remove(id)
            saveStates[id] = .saved
        } catch {
            saveStates[id] = .notSaved(message: error.localizedDescription)
        }
        notify(id)
    }

    private func notify(_ id: UUID) {
        let change = Change(draftID: id, draft: drafts[id], saveState: saveState(id: id))
        for observer in observers.values { observer.yield(change) }
    }

    private func removeObserver(_ token: UUID) { observers[token] = nil }

    // MARK: - Files

    static func encode(_ draft: MeetingDraft) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(draft)
    }

    static func decode(_ data: Data) throws -> MeetingDraft {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MeetingDraft.self, from: data)
    }

    private static func readAll(in directory: URL) -> (drafts: [MeetingDraft], unreadable: [URL]) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        var drafts: [MeetingDraft] = []
        var unreadable: [URL] = []
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file), let draft = try? decode(data) {
                drafts.append(draft)
            } else {
                unreadable.append(file)
            }
        }
        return (drafts, unreadable)
    }

    /// Writes through an owner-only (0600) temporary file in the same
    /// directory and renames it over the destination, so a reader sees the old
    /// draft or the new one and never a partial file or a moment of wider
    /// permissions. The directory itself is created owner-only (0700).
    public static let writePrivateFile: FileWriter = { data, destination in
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporary = directory.appending(path: ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard Darwin.rename(temporary.path, destination.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}
