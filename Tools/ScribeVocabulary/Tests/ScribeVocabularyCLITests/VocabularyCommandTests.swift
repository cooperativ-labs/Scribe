import Foundation
import Testing
import Vocabulary

@testable import ScribeVocabularyCLI

private struct Workspace: ~Copyable {
    let url: URL

    init(_ name: String) throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ScribeVocabTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

/// Runs the command against a throwaway directory, the way `--directory` does.
private func command(input: String = "") -> VocabularyCommand {
    VocabularyCommand(makeStore: { directory in
        try VocabularyStore(directoryURL: directory ?? URL(fileURLWithPath: NSTemporaryDirectory()))
    }, readStandardInput: { input })
}

@Suite("scribe-vocab")
struct VocabularyCommandTests {
    @Test("add then list reports the term in the text glossary form")
    func addAndList() throws {
        let workspace = try Workspace("add")
        let cli = command()
        _ = try cli.run(["add", "Livmarli", "--alias", "Liv Mali, Liv-Marli", "--directory", workspace.url.path])
        let listed = try cli.run(["list", "--directory", workspace.url.path])
        #expect(listed.standardOutput == "Livmarli: Liv Mali, Liv-Marli\n")
    }

    @Test("add is safe to run twice: the second call merges rather than duplicates")
    func addIsIdempotent() throws {
        let workspace = try Workspace("twice")
        let cli = command()
        _ = try cli.run(["add", "macOS", "--alias", "Mac OS", "--directory", workspace.url.path])
        let second = try cli.run(["add", "macOS", "--alias", "Mac O S", "--directory", workspace.url.path])
        #expect(second.standardOutput == "Updated macOS: Mac OS, Mac O S\n")
        #expect(try cli.run(["list", "--directory", workspace.url.path]).standardOutput == "macOS: Mac OS, Mac O S\n")
    }

    @Test("A term too short to apply is added, marked, and warned about")
    func shortTermWarns() throws {
        let workspace = try Workspace("short")
        let cli = command()
        let added = try cli.run(["add", "AI", "--directory", workspace.url.path])
        #expect(added.standardError.contains("not applied to transcription"))
        #expect(try cli.run(["list", "--directory", workspace.url.path]).standardOutput.contains("[too short to apply]"))
    }

    @Test("list --json is parseable and marks which terms apply")
    func listJSON() throws {
        let workspace = try Workspace("json")
        let cli = command()
        _ = try cli.run(["add", "Parakeet", "--directory", workspace.url.path])
        _ = try cli.run(["add", "AI", "--directory", workspace.url.path])
        let output = try cli.run(["list", "--json", "--directory", workspace.url.path])
        let payload = try #require(
            try JSONSerialization.jsonObject(with: Data(output.standardOutput.utf8)) as? [String: Any]
        )
        let lists = try #require(payload["lists"] as? [[String: Any]])
        let terms = try #require(lists[0]["terms"] as? [[String: Any]])
        #expect(terms.count == 2)
        #expect(terms.first { $0["text"] as? String == "AI" }?["applied"] as? Bool == false)
        #expect(terms.first { $0["text"] as? String == "Parakeet" }?["applied"] as? Bool == true)
    }

    @Test("import reads standard input and reports what it did")
    func importFromStandardInput() throws {
        let workspace = try Workspace("stdin")
        let cli = command(input: "# names\nNVIDIA\nmacOS: Mac OS\n")
        let output = try cli.run(["import", "-", "--directory", workspace.url.path])
        #expect(output.standardOutput == "2 added\n")
        #expect(try cli.run(["export", "--directory", workspace.url.path]).standardOutput == "macOS: Mac OS\nNVIDIA\n")
    }

    @Test("import --replace swaps the list instead of merging")
    func importReplaces() throws {
        let workspace = try Workspace("replace")
        _ = try command(input: "Alpha\nBeta\n").run(["import", "-", "--directory", workspace.url.path])
        let output = try command(input: "Gamma\n").run(["import", "-", "--replace", "--directory", workspace.url.path])
        #expect(output.standardOutput.contains("2 removed"))
        #expect(try command().run(["list", "--directory", workspace.url.path]).standardOutput == "Gamma\n")
    }

    @Test("A term that is not there is a data error, not a usage dump")
    func removeMissingIsDataError() throws {
        let workspace = try Workspace("missing")
        #expect(throws: CLIError.data("“Nope” is not in the vocabulary.")) {
            try command().run(["remove", "Nope", "--directory", workspace.url.path])
        }
    }

    @Test("An unknown command and an unknown option are usage errors")
    func usageErrors() throws {
        let workspace = try Workspace("usage")
        #expect(throws: CLIError.self) { try command().run(["bogus", "--directory", workspace.url.path]) }
        #expect(throws: CLIError.usage("Unknown option --nope.")) {
            try command().run(["list", "--nope", "--directory", workspace.url.path])
        }
        #expect(throws: CLIError.self) { try command().run(["clear", "--directory", workspace.url.path]) }
    }

    @Test("clear needs --force and then reports the count it removed")
    func clearRequiresForce() throws {
        let workspace = try Workspace("clear")
        let cli = command()
        _ = try cli.run(["add", "Alpha", "--directory", workspace.url.path])
        _ = try cli.run(["add", "Beta", "--directory", workspace.url.path])
        let output = try cli.run(["clear", "--force", "--directory", workspace.url.path])
        #expect(output.standardOutput == "Removed 2 terms\n")
    }

    @Test("A pack is created, written into, and disabled without touching the personal list")
    func packLifecycle() throws {
        let workspace = try Workspace("packs")
        let cli = command()
        _ = try cli.run(["add", "Scribe", "--directory", workspace.url.path])
        _ = try cli.run(["pack", "add", "Client glossary", "--directory", workspace.url.path])
        _ = try cli.run(["add", "Livmarli", "--pack", "Client glossary", "--directory", workspace.url.path])
        #expect(try cli.run(["list", "--directory", workspace.url.path]).standardOutput == "Scribe\n")

        _ = try cli.run(["pack", "disable", "Client glossary", "--directory", workspace.url.path])
        let packs = try cli.run(["packs", "--directory", workspace.url.path])
        #expect(packs.standardOutput.contains("Client glossary — disabled, 1 term"))
    }

    @Test("Naming a pack that does not exist is refused rather than written to the personal list")
    func unknownPackIsRefused() throws {
        let workspace = try Workspace("unknownpack")
        #expect(throws: CLIError.self) {
            try command().run(["add", "Alpha", "--pack", "Nowhere", "--directory", workspace.url.path])
        }
        #expect(try command().run(["list", "--directory", workspace.url.path]).standardOutput == "  (no terms)\n")
    }

    @Test("revision is empty until a term that can be applied exists")
    func revisionFollowsContent() throws {
        let workspace = try Workspace("revision")
        let cli = command()
        #expect(try cli.run(["revision", "--directory", workspace.url.path]).standardOutput == "(empty vocabulary)\n")
        _ = try cli.run(["add", "Parakeet", "--directory", workspace.url.path])
        let first = try cli.run(["revision", "--directory", workspace.url.path]).standardOutput
        _ = try cli.run(["add", "Parakeet", "--alias", "Para Keet", "--directory", workspace.url.path])
        #expect(try cli.run(["revision", "--directory", workspace.url.path]).standardOutput != first)
    }

    @Test("--help prints the usage without touching the library")
    func help() throws {
        let output = try command().run(["--help"])
        #expect(output.standardOutput.contains("scribe-vocab — read and edit"))
    }
}
