import Foundation
import Observation

/// State and actions behind the Vocabulary section in Settings.
///
/// Every mutation goes straight to `VocabularyStore`, because the same file is
/// also edited by `scribe-vocab`: holding an unsaved in-memory copy here would
/// mean an agent's change and a person's change silently overwriting each
/// other. For the same reason the model watches the file and reloads when
/// another process writes it.
@MainActor
@Observable
public final class VocabularyViewModel {
    public private(set) var library: VocabularyLibrary = VocabularyLibrary()
    public private(set) var errorMessage: String?
    public private(set) var statusMessage: String?

    /// Filter over the visible rows. Not persisted: it is a way to find a term
    /// in a long list, not a setting.
    public var searchText = ""

    /// The term open in the editor sheet, if any.
    public var editingTerm: VocabularyTerm?

    /// Fields of the inline "add a term" row.
    public var draftText = ""
    public var draftAliases = ""

    @ObservationIgnored private let store: VocabularyStore
    @ObservationIgnored private var watcher: VocabularyFileWatcher?

    public init(store: VocabularyStore) {
        self.store = store
        reload()
    }

    /// Opens the shared Application Support library, or `nil` when it cannot be
    /// created — Settings then hides the section rather than showing an editor
    /// that can save nothing.
    public static func applicationSupportModel() -> VocabularyViewModel? {
        guard let store = try? VocabularyStore.openApplicationSupportLibrary() else { return nil }
        return VocabularyViewModel(store: store)
    }

    // MARK: Presentation

    public var personalTerms: [VocabularyTerm] { library.personal.terms }

    public var visibleTerms: [VocabularyTerm] {
        let query = VocabularyText.matchKey(searchText)
        guard !query.isEmpty else { return personalTerms }
        return personalTerms.filter { term in
            term.key.contains(query) || term.aliases.contains { VocabularyText.matchKey($0).contains(query) }
        }
    }

    public var activeTermCount: Int { library.activeTerms.count }

    /// Terms held but not applied, because they are shorter than the recognizer
    /// will act on. Surfaced so a list that looks full but boosts nothing is
    /// explained rather than mysterious.
    public var inactiveTermCount: Int { personalTerms.count - personalTerms.filter(\.isBoostable).count }

    public var isEmpty: Bool { personalTerms.isEmpty }

    public var revision: String? { library.revision }

    public var fileURL: URL { store.fileURL }

    /// The count shown beside the section title. Empty while the list is
    /// empty: the list itself already says so, and saying it twice reads as a
    /// warning rather than a status.
    public var summaryDescription: String {
        guard !isEmpty else { return "" }
        let active = library.personal.boostableTerms.count
        var text = "\(active) term\(active == 1 ? "" : "s") applied to new transcriptions"
        if inactiveTermCount > 0 { text += " · \(inactiveTermCount) too short to apply" }
        return text
    }

    // MARK: Loading

    public func reload() {
        do {
            library = try store.load()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Starts watching the library file so a change made by `scribe-vocab`
    /// while the settings window is open shows up without reopening it.
    public func startWatching() {
        reload()
        guard watcher == nil else { return }
        watcher = VocabularyFileWatcher(directoryURL: store.directoryURL) { [weak self] in
            self?.reload()
        }
    }

    public func stopWatching() {
        watcher = nil
    }

    // MARK: Editing

    /// Commits the inline add row. Adding a term that is already present merges
    /// the new mishearings into it rather than making a second row.
    public func addDraftTerm() {
        let text = draftText
        guard !VocabularyText.sanitize(text).isEmpty else { return }
        let aliases = VocabularyText.splitAliases(draftAliases)
        let existed = library.personal.term(matching: text) != nil
        perform {
            let term = try store.addTerm(text, aliases: aliases)
            return existed
                ? "Merged into the existing term “\(term.text)”."
                : "Added “\(term.text)”."
        }
        draftText = ""
        draftAliases = ""
    }

    public func save(_ edited: VocabularyTerm, replacing original: VocabularyTerm) {
        perform {
            let term = try store.updateTerm(
                matching: original.text,
                newText: edited.text,
                aliases: edited.aliases,
                notes: .some(edited.notes)
            )
            return "Saved “\(term.text)”."
        }
    }

    public func remove(_ term: VocabularyTerm) {
        perform {
            _ = try store.removeTerm(id: term.id)
            return "Removed “\(term.text)”."
        }
    }

    public func removeAll() {
        perform {
            try store.removeAllTerms()
            return "Vocabulary cleared."
        }
    }

    public func importGlossary(at url: URL, replacingExisting: Bool = false) {
        perform {
            let granted = url.startAccessingSecurityScopedResource()
            defer { if granted { url.stopAccessingSecurityScopedResource() } }
            let text = try String(contentsOf: url, encoding: .utf8)
            let summary = try store.importText(text, replacingExisting: replacingExisting)
            return "Imported \(url.lastPathComponent): \(summary.summaryText)."
        }
    }

    public func exportGlossary(to url: URL) {
        perform {
            let granted = url.startAccessingSecurityScopedResource()
            defer { if granted { url.stopAccessingSecurityScopedResource() } }
            try store.exportText().write(to: url, atomically: true, encoding: .utf8)
            return "Exported to \(url.lastPathComponent)."
        }
    }

    /// Reports a failure that happened before the store was reached — a file
    /// panel that could not open the chosen file, typically.
    public func importFailed(_ error: Error) {
        errorMessage = error.localizedDescription
        statusMessage = nil
    }

    public func dismissMessages() {
        statusMessage = nil
        errorMessage = nil
    }

    /// One place where a store call becomes either a status line or an error
    /// line, and where the in-memory copy is refreshed from what was written.
    private func perform(_ body: () throws -> String) {
        do {
            statusMessage = try body()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
        }
        reload()
    }
}

/// Notices writes to the vocabulary directory.
///
/// The directory rather than the file: the store replaces `library.json`
/// atomically, so a source watching the file itself would stop firing after the
/// first external edit.
final class VocabularyFileWatcher {
    private let descriptor: CInt
    private let source: DispatchSourceFileSystemObject

    init?(directoryURL: URL, onChange: @escaping @MainActor () -> Void) {
        descriptor = open(directoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { MainActor.assumeIsolated { onChange() } }
        source.setCancelHandler { [descriptor] in close(descriptor) }
        source.resume()
    }

    deinit { source.cancel() }
}
