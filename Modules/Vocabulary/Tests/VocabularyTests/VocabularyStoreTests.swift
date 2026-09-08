import Foundation
import Testing

@testable import Vocabulary

private struct Workspace: ~Copyable {
    let url: URL

    init(_ name: String) throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("VocabularyTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

@Suite("Vocabulary store")
struct VocabularyStoreTests {
    @Test("A store with no file yet reads as an empty personal library")
    func emptyLibrary() throws {
        let workspace = try Workspace("empty")
        let store = try VocabularyStore(directoryURL: workspace.url)
        let library = try store.load()
        #expect(library.personal.terms.isEmpty)
        #expect(library.packs.isEmpty)
        #expect(library.revision == nil)
    }

    @Test("Adding a term persists it and survives a reopen")
    func addPersists() throws {
        let workspace = try Workspace("add")
        let store = try VocabularyStore(directoryURL: workspace.url)
        try store.addTerm("Livmarli", aliases: ["Liv Mali", "Liv-Marli"])

        let reopened = try VocabularyStore(directoryURL: workspace.url)
        let term = try #require(try reopened.load().personal.term(matching: "livmarli"))
        #expect(term.text == "Livmarli")
        #expect(term.aliases == ["Liv Mali", "Liv-Marli"])
    }

    @Test("Re-adding a term merges its mishearings instead of duplicating the row")
    func addMerges() throws {
        let workspace = try Workspace("merge")
        let store = try VocabularyStore(directoryURL: workspace.url)
        try store.addTerm("macOS", aliases: ["Mac OS"])
        try store.addTerm("macOS", aliases: ["Mac O S", "Mac OS"])

        let terms = try store.load().personal.terms
        #expect(terms.count == 1)
        #expect(terms[0].aliases == ["Mac OS", "Mac O S"])
    }

    @Test("Merging a term again keeps the note already written for it")
    func mergeKeepsNotes() throws {
        let workspace = try Workspace("notes")
        let store = try VocabularyStore(directoryURL: workspace.url)
        try store.addTerm("Livmarli", notes: "Trial drug, comes back as two words")
        try store.addTerm("Livmarli", aliases: ["Liv Mali"])
        let term = try #require(try store.load().personal.term(matching: "Livmarli"))
        #expect(term.notes == "Trial drug, comes back as two words")
        #expect(term.aliases == ["Liv Mali"])
    }

    @Test("A term is matched case-insensitively when it is edited or removed")
    func caseInsensitiveIdentity() throws {
        let workspace = try Workspace("case")
        let store = try VocabularyStore(directoryURL: workspace.url)
        try store.addTerm("NVIDIA")
        let updated = try store.updateTerm(matching: "nvidia", aliases: ["N Vidia"])
        #expect(updated.aliases == ["N Vidia"])

        let removed = try store.removeTerm(matching: "  NVidia ")
        #expect(removed.text == "NVIDIA")
        #expect(try store.load().personal.terms.isEmpty)
    }

    @Test("Removing a term that is not there names the term rather than failing silently")
    func removeMissing() throws {
        let workspace = try Workspace("missing")
        let store = try VocabularyStore(directoryURL: workspace.url)
        #expect(throws: VocabularyStoreError.termNotFound("Parakeet")) {
            try store.removeTerm(matching: "Parakeet")
        }
    }

    @Test("Renaming onto another term's spelling is refused, not merged")
    func renameCollision() throws {
        let workspace = try Workspace("collision")
        let store = try VocabularyStore(directoryURL: workspace.url)
        try store.addTerm("Parakeet")
        try store.addTerm("Paraquet")
        #expect(throws: VocabularyStoreError.duplicateTerm("Parakeet")) {
            try store.updateTerm(matching: "Paraquet", newText: "Parakeet")
        }
        #expect(try store.load().personal.terms.count == 2)
    }

    @Test("An empty term is refused")
    func emptyTermRefused() throws {
        let workspace = try Workspace("blank")
        let store = try VocabularyStore(directoryURL: workspace.url)
        #expect(throws: VocabularyStoreError.emptyTerm) { try store.addTerm("   ") }
    }

    @Test("Importing merges by default and replaces on request")
    func importModes() throws {
        let workspace = try Workspace("import")
        let store = try VocabularyStore(directoryURL: workspace.url)
        try store.addTerm("Scribe")

        let merged = try store.importText("# a glossary\nNVIDIA\nmacOS: Mac OS\n\n")
        #expect(merged.parsed == 2)
        #expect(merged.added == 2)
        #expect(try store.load().personal.terms.count == 3)

        let replaced = try store.importText("Parakeet\n", replacingExisting: true)
        #expect(replaced.removed == 3)
        #expect(try store.load().personal.terms.map(\.text) == ["Parakeet"])
    }

    @Test("Import round-trips through the text format")
    func exportRoundTrip() throws {
        let workspace = try Workspace("roundtrip")
        let store = try VocabularyStore(directoryURL: workspace.url)
        try store.importText("macOS: Mac OS, Mac O S\nNVIDIA\n")
        let exported = try store.exportText()
        #expect(exported == "macOS: Mac OS, Mac O S\nNVIDIA\n")

        let second = try VocabularyStore(directoryURL: try Workspace("roundtrip2").url)
        try second.importText(exported)
        #expect(try second.exportText() == exported)
    }

    @Test("A hand-edited file with no personal list still opens")
    func recoversMissingPersonalList() throws {
        let workspace = try Workspace("handedited")
        let store = try VocabularyStore(directoryURL: workspace.url)
        try Data(#"{"schemaVersion":1,"lists":[]}"#.utf8).write(to: store.fileURL)
        let library = try store.load()
        #expect(library.personal.kind == .personal)
        #expect(library.personal.terms.isEmpty)
    }

    @Test("A pack is unioned with the personal list only while it is enabled")
    func packsMerge() throws {
        let workspace = try Workspace("packs")
        let store = try VocabularyStore(directoryURL: workspace.url)
        try store.addTerm("Scribe")
        let pack = try store.addPack(named: "Client glossary")
        try store.addTerm("Livmarli", listID: pack.id)
        #expect(try store.load().activeTerms.map(\.text) == ["Livmarli", "Scribe"])

        try store.setPackEnabled(false, listID: pack.id)
        #expect(try store.load().activeTerms.map(\.text) == ["Scribe"])
    }

    @Test("The personal list cannot be removed")
    func personalListIsPermanent() throws {
        let workspace = try Workspace("permanent")
        let store = try VocabularyStore(directoryURL: workspace.url)
        let personalID = try store.load().personal.id
        #expect(throws: VocabularyStoreError.self) { try store.removePack(id: personalID) }
    }
}

@Suite("Vocabulary revision")
struct VocabularyRevisionTests {
    @Test("An empty vocabulary has no revision, so existing fingerprints are unchanged")
    func emptyRevisionIsNil() {
        #expect(VocabularyLibrary().revision == nil)
    }

    @Test("The revision follows content, not spelling case or term order")
    func revisionIsCanonical() {
        var first = VocabularyLibrary()
        _ = first.update { $0.upsert(VocabularyTerm(text: "NVIDIA", aliases: ["N Vidia"])) }
        _ = first.update { $0.upsert(VocabularyTerm(text: "macOS")) }

        var second = VocabularyLibrary()
        _ = second.update { $0.upsert(VocabularyTerm(text: "macOS")) }
        _ = second.update { $0.upsert(VocabularyTerm(text: "nvidia", aliases: ["n vidia"])) }

        #expect(first.revision == second.revision)
    }

    @Test("Adding a mishearing changes the revision")
    func revisionChangesWithAliases() {
        var library = VocabularyLibrary()
        _ = library.update { $0.upsert(VocabularyTerm(text: "Livmarli")) }
        let before = library.revision
        _ = library.update { $0.upsert(VocabularyTerm(text: "Livmarli", aliases: ["Liv Mali"])) }
        #expect(before != library.revision)
    }

    @Test("Terms too short to boost are held but never reach the engine")
    func shortTermsAreInactive() {
        var library = VocabularyLibrary()
        _ = library.update { $0.upsert(VocabularyTerm(text: "AI")) }
        #expect(library.personal.terms.count == 1)
        #expect(library.activeTerms.isEmpty)
        #expect(library.revision == nil)
    }
}

@Suite("Vocabulary text")
struct VocabularyTextTests {
    @Test("Whitespace is collapsed and case is kept")
    func sanitize() {
        #expect(VocabularyText.sanitize("  mac   OS \n") == "mac OS")
        #expect(VocabularyText.sanitize("NVIDIA") == "NVIDIA")
    }

    @Test("An alias equal to its own term, or repeated, is dropped")
    func aliasSanitizing() {
        let term = VocabularyTerm(text: "macOS", aliases: ["MacOS", "Mac OS", "mac os", " ", "Mac OS"])
        #expect(term.aliases == ["Mac OS"])
    }

    @Test("Comments and blank lines are skipped; a bad line is reported, not fatal")
    func parseGlossary() {
        let parsed = VocabularyTextFormat.parse("# names\n\nNVIDIA\n: orphan\nmacOS: Mac OS\n")
        #expect(parsed.terms.map(\.text) == ["macOS", "NVIDIA"])
        #expect(parsed.skipped.count == 1)
        #expect(parsed.skipped[0].line == 4)
    }

    @Test("Common words are flagged without being refused")
    func stopwordAdvisory() {
        let term = VocabularyTerm(text: "there")
        #expect(term.advisories.contains(.commonWord))
        #expect(term.isBoostable)
    }
}
