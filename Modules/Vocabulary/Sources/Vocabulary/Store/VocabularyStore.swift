import Foundation

public enum VocabularyStoreError: Error, LocalizedError, Equatable {
    case applicationSupportUnavailable
    case unreadable(String)
    case unwritable(String)
    case emptyTerm
    case termNotFound(String)
    case duplicateTerm(String)
    case listNotFound(String)
    case listNotRemovable(String)

    public var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            "The Application Support folder could not be located, so the vocabulary cannot be stored."
        case .unreadable(let detail):
            "The vocabulary file could not be read: \(detail)"
        case .unwritable(let detail):
            "The vocabulary could not be saved: \(detail)"
        case .emptyTerm:
            "A term needs at least one character."
        case .termNotFound(let text):
            "“\(text)” is not in the vocabulary."
        case .duplicateTerm(let text):
            "“\(text)” is already in the vocabulary."
        case .listNotFound(let name):
            "There is no vocabulary list named “\(name)”."
        case .listNotRemovable(let name):
            "“\(name)” is the personal vocabulary and cannot be removed."
        }
    }
}

/// The durable custom vocabulary, stored as one JSON document under
/// Application Support.
///
/// Both the Settings editor and the `scribe-vocab` command open the same file,
/// so every read-modify-write takes an advisory lock on it: an agent adding a
/// term while the settings window is open must not lose either edit. Writes are
/// atomic, so a reader never sees a half-written library.
public final class VocabularyStore: @unchecked Sendable {
    public static let fileName = "library.json"
    public static let lockFileName = ".library.lock"

    public let directoryURL: URL
    public let fileURL: URL

    private let fileManager: FileManager
    private let lockURL: URL
    /// Guards this process's own callers; the file lock guards the other one.
    private let processLock = NSLock()

    public init(directoryURL: URL, fileManager: FileManager = .default) throws {
        self.directoryURL = directoryURL
        self.fileURL = directoryURL.appendingPathComponent(Self.fileName)
        self.lockURL = directoryURL.appendingPathComponent(Self.lockFileName)
        self.fileManager = fileManager
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            throw VocabularyStoreError.unwritable(error.localizedDescription)
        }
    }

    /// `~/Library/Application Support/Scribe/Vocabulary`, the location the app
    /// and the command line share.
    public static func openApplicationSupportLibrary(fileManager: FileManager = .default) throws -> VocabularyStore {
        try VocabularyStore(
            directoryURL: VocabularyModule.applicationSupportDirectory(fileManager: fileManager),
            fileManager: fileManager
        )
    }

    // MARK: Document

    /// Reads the library, returning an empty one when nothing has been saved.
    ///
    /// A first launch is not an error state, so no caller has to distinguish
    /// "never used" from "failed to read".
    public func load() throws -> VocabularyLibrary {
        guard let data = fileManager.contents(atPath: fileURL.path) else { return VocabularyLibrary() }
        guard !data.isEmpty else { return VocabularyLibrary() }
        do {
            return try Self.decoder.decode(VocabularyLibrary.self, from: data)
        } catch {
            throw VocabularyStoreError.unreadable(error.localizedDescription)
        }
    }

    public func save(_ library: VocabularyLibrary) throws {
        processLock.lock()
        defer { processLock.unlock() }
        try write(library)
    }

    /// Runs `body` against the current library and saves the result, holding an
    /// exclusive lock for the whole cycle.
    @discardableResult
    public func mutate<T>(_ body: (inout VocabularyLibrary) throws -> T) throws -> T {
        processLock.lock()
        defer { processLock.unlock() }
        let handle = try acquireFileLock()
        defer { releaseFileLock(handle) }
        var library = try load()
        let result = try body(&library)
        try write(library)
        return result
    }

    /// The modification date the settings window compares against to notice a
    /// change made by another process. `nil` before anything is written.
    public var lastModified: Date? {
        (try? fileManager.attributesOfItem(atPath: fileURL.path)[.modificationDate]) as? Date
    }

    // MARK: Term operations

    /// Adds a term, or merges aliases into the one already spelled that way.
    @discardableResult
    public func addTerm(
        _ text: String,
        aliases: [String] = [],
        notes: String? = nil,
        listID: UUID? = nil
    ) throws -> VocabularyTerm {
        let term = VocabularyTerm(text: text, aliases: aliases, notes: notes)
        guard !term.text.isEmpty else { throw VocabularyStoreError.emptyTerm }
        return try mutate { library in
            guard let added = library.update(listID: listID, { $0.upsert(term) }) else {
                throw VocabularyStoreError.listNotFound(listID?.uuidString ?? "personal")
            }
            return added
        }
    }

    /// Replaces the spelling, mishearings, and note of an existing term.
    @discardableResult
    public func updateTerm(
        matching text: String,
        newText: String? = nil,
        aliases: [String]? = nil,
        notes: String?? = nil
    ) throws -> VocabularyTerm {
        try mutate { library in
            guard let located = Self.locate(text, in: library) else {
                throw VocabularyStoreError.termNotFound(text)
            }
            let updated = located.term.updating(text: newText, aliases: aliases, notes: notes)
            guard updated.text.isEmpty == false else { throw VocabularyStoreError.emptyTerm }
            let replaced = library.update(listID: located.listID) { $0.replace(id: located.term.id, with: updated) }
            guard replaced == true else { throw VocabularyStoreError.duplicateTerm(updated.text) }
            return updated
        }
    }

    @discardableResult
    public func removeTerm(matching text: String) throws -> VocabularyTerm {
        try mutate { library in
            guard let located = Self.locate(text, in: library) else {
                throw VocabularyStoreError.termNotFound(text)
            }
            guard let removed = library.update(listID: located.listID, { $0.remove(id: located.term.id) }) ?? nil else {
                throw VocabularyStoreError.termNotFound(text)
            }
            return removed
        }
    }

    @discardableResult
    public func removeTerm(id: UUID, listID: UUID? = nil) throws -> VocabularyTerm? {
        try mutate { library in library.update(listID: listID, { $0.remove(id: id) }) ?? nil }
    }

    /// Imports a plain-text glossary. `replacingExisting` swaps the list's whole
    /// contents; otherwise the file is merged into what is already there.
    @discardableResult
    public func importText(
        _ text: String,
        into listID: UUID? = nil,
        replacingExisting: Bool = false
    ) throws -> VocabularyImportSummary {
        let parsed = VocabularyTextFormat.parse(text)
        return try mutate { library in
            let before = library.list(id: listID ?? library.personal.id)?.terms ?? []
            let existingKeys = Set(before.map(\.key))
            let applied = library.update(listID: listID) { list -> Bool in
                if replacingExisting {
                    list.replaceAll(with: parsed.terms)
                } else {
                    for term in parsed.terms { list.upsert(term) }
                }
                return true
            }
            guard applied == true else {
                throw VocabularyStoreError.listNotFound(listID?.uuidString ?? "personal")
            }
            let added = parsed.terms.filter { !existingKeys.contains($0.key) }.count
            return VocabularyImportSummary(
                parsed: parsed.terms.count,
                added: added,
                merged: parsed.terms.count - added,
                removed: replacingExisting ? before.filter { term in !parsed.terms.contains { $0.key == term.key } }.count : 0,
                skippedLines: parsed.skipped.map { "line \($0.line): \($0.reason)" }
            )
        }
    }

    public func exportText(listID: UUID? = nil) throws -> String {
        let library = try load()
        guard let list = library.list(id: listID ?? library.personal.id) else {
            throw VocabularyStoreError.listNotFound(listID?.uuidString ?? "personal")
        }
        return VocabularyTextFormat.render(list.terms)
    }

    /// Empties a list without removing it. The personal list always exists.
    public func removeAllTerms(listID: UUID? = nil) throws {
        try mutate { library in
            let cleared = library.update(listID: listID) { list -> Bool in
                list.replaceAll(with: [])
                return true
            }
            guard cleared == true else {
                throw VocabularyStoreError.listNotFound(listID?.uuidString ?? "personal")
            }
        }
    }

    // MARK: List operations

    @discardableResult
    public func addPack(named name: String) throws -> VocabularyList {
        let sanitized = VocabularyText.sanitize(name)
        guard !sanitized.isEmpty else { throw VocabularyStoreError.emptyTerm }
        return try mutate { library in library.addPack(named: sanitized) }
    }

    public func setPackEnabled(_ enabled: Bool, listID: UUID) throws {
        try mutate { library in
            let applied = library.update(listID: listID) { list -> Bool in
                list.setEnabled(enabled)
                return true
            }
            guard applied == true else {
                throw VocabularyStoreError.listNotFound(listID.uuidString)
            }
        }
    }

    public func removePack(id: UUID) throws {
        try mutate { library in
            guard let list = library.list(id: id) else { throw VocabularyStoreError.listNotFound(id.uuidString) }
            guard library.removeList(id: id) else { throw VocabularyStoreError.listNotRemovable(list.name) }
        }
    }

    /// Resolves a term by spelling across the personal list first, then packs,
    /// so an unqualified `scribe-vocab remove` means what a person expects.
    private static func locate(_ text: String, in library: VocabularyLibrary) -> (listID: UUID, term: VocabularyTerm)? {
        for list in library.lists {
            if let term = list.term(matching: text) { return (list.id, term) }
        }
        return nil
    }

    // MARK: File access

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private func write(_ library: VocabularyLibrary) throws {
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try Self.encoder.encode(library)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw VocabularyStoreError.unwritable(error.localizedDescription)
        }
    }

    /// An advisory `flock` on a sidecar file rather than on `library.json`
    /// itself: the document is replaced atomically, so a lock held on it would
    /// be a lock on a file that no longer exists by the time it is released.
    private func acquireFileLock() throws -> FileHandle? {
        if !fileManager.fileExists(atPath: lockURL.path) {
            fileManager.createFile(atPath: lockURL.path, contents: Data())
        }
        guard let handle = try? FileHandle(forUpdating: lockURL) else { return nil }
        // A failed lock is not a reason to refuse an edit: the atomic write
        // still leaves a valid file, and refusing would strand the editor.
        flock(handle.fileDescriptor, LOCK_EX)
        return handle
    }

    private func releaseFileLock(_ handle: FileHandle?) {
        guard let handle else { return }
        flock(handle.fileDescriptor, LOCK_UN)
        try? handle.close()
    }
}

/// What an import actually did, reported by both the editor and the command.
public struct VocabularyImportSummary: Equatable, Sendable {
    public let parsed: Int
    public let added: Int
    public let merged: Int
    public let removed: Int
    public let skippedLines: [String]

    public init(parsed: Int, added: Int, merged: Int, removed: Int, skippedLines: [String]) {
        self.parsed = parsed
        self.added = added
        self.merged = merged
        self.removed = removed
        self.skippedLines = skippedLines
    }

    public var summaryText: String {
        var parts = ["\(added) added"]
        if merged > 0 { parts.append("\(merged) merged into existing terms") }
        if removed > 0 { parts.append("\(removed) removed") }
        if !skippedLines.isEmpty { parts.append("\(skippedLines.count) line\(skippedLines.count == 1 ? "" : "s") skipped") }
        return parts.joined(separator: ", ")
    }
}
