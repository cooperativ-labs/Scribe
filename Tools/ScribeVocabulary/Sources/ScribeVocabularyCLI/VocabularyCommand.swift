import Foundation
import Vocabulary

/// Runs one `scribe-vocab` invocation against a vocabulary store.
///
/// Output is returned rather than printed so the whole command surface can be
/// tested without a subprocess, and so the executable owns the only call to
/// `exit`.
public struct VocabularyCommand {
    public struct Output: Equatable {
        public var standardOutput: String
        public var standardError: String

        public init(standardOutput: String = "", standardError: String = "") {
            self.standardOutput = standardOutput
            self.standardError = standardError
        }
    }

    private let makeStore: (URL?) throws -> VocabularyStore
    private let readStandardInput: () -> String

    public init(
        makeStore: @escaping (URL?) throws -> VocabularyStore = VocabularyCommand.openStore,
        readStandardInput: @escaping () -> String = { String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? "" }
    ) {
        self.makeStore = makeStore
        self.readStandardInput = readStandardInput
    }

    public static func openStore(directory: URL?) throws -> VocabularyStore {
        if let directory { return try VocabularyStore(directoryURL: directory) }
        return try VocabularyStore.openApplicationSupportLibrary()
    }

    public func run(_ arguments: [String]) throws -> Output {
        var parsed = try ArgumentList(arguments)
        if parsed.has("--help") || parsed.has("-h") {
            return Output(standardOutput: ScribeVocabularyUsage.text + "\n")
        }
        guard let command = parsed.nextPositional() else {
            throw CLIError.usage("No command given.")
        }
        let store = try openStore(&parsed)

        switch command {
        case "list": return try list(store, &parsed)
        case "add": return try add(store, &parsed)
        case "remove", "rm": return try remove(store, &parsed)
        case "rename": return try rename(store, &parsed)
        case "set-aliases": return try setAliases(store, &parsed)
        case "import": return try importGlossary(store, &parsed)
        case "export": return try export(store, &parsed)
        case "clear": return try clear(store, &parsed)
        case "packs": return try packs(store, &parsed)
        case "pack": return try pack(store, &parsed)
        case "revision": return try revision(store, &parsed)
        case "path": return Output(standardOutput: store.fileURL.path + "\n")
        case "help": return Output(standardOutput: ScribeVocabularyUsage.text + "\n")
        default: throw CLIError.usage("Unknown command “\(command)”.")
        }
    }

    // MARK: Commands

    private func list(_ store: VocabularyStore, _ arguments: inout ArgumentList) throws -> Output {
        let library = try load(store)
        let lists = arguments.has("--all") ? library.lists : [library.personal]
        if arguments.has("--json") {
            return Output(standardOutput: try json(lists: lists, revision: library.revision))
        }
        var lines: [String] = []
        for list in lists {
            if arguments.has("--all") {
                let state = list.kind == .personal ? "always on" : (list.isEnabled ? "enabled" : "disabled")
                lines.append("\(list.name) (\(state)) — \(list.terms.count) term\(list.terms.count == 1 ? "" : "s")")
            }
            if list.terms.isEmpty {
                lines.append("  (no terms)")
                continue
            }
            for term in list.terms {
                let prefix = arguments.has("--all") ? "  " : ""
                let marker = term.isBoostable ? "" : "  [too short to apply]"
                lines.append(prefix + term.lineDescription + marker)
            }
        }
        return Output(standardOutput: lines.joined(separator: "\n") + "\n")
    }

    private func add(_ store: VocabularyStore, _ arguments: inout ArgumentList) throws -> Output {
        guard let text = arguments.nextPositional() else { throw CLIError.usage("add needs a term.") }
        let listID = try packID(store, arguments.packName)
        let library = try load(store)
        let existed = library.list(id: listID ?? library.personal.id)?.term(matching: text) != nil
        let term = try wrap { try store.addTerm(text, aliases: arguments.aliasArguments, notes: arguments.value("--note"), listID: listID) }
        var output = Output(standardOutput: "\(existed ? "Updated" : "Added") \(term.lineDescription)\n")
        output.standardError = advisoryText(for: term)
        return output
    }

    private func remove(_ store: VocabularyStore, _ arguments: inout ArgumentList) throws -> Output {
        guard let text = arguments.nextPositional() else { throw CLIError.usage("remove needs a term.") }
        let term = try wrap { try store.removeTerm(matching: text) }
        return Output(standardOutput: "Removed \(term.text)\n")
    }

    private func rename(_ store: VocabularyStore, _ arguments: inout ArgumentList) throws -> Output {
        guard let text = arguments.nextPositional() else { throw CLIError.usage("rename needs a term.") }
        guard let newText = arguments.nextPositional() else { throw CLIError.usage("rename needs the new spelling.") }
        let term = try wrap { try store.updateTerm(matching: text, newText: newText) }
        return Output(standardOutput: "Renamed to \(term.lineDescription)\n", standardError: advisoryText(for: term))
    }

    private func setAliases(_ store: VocabularyStore, _ arguments: inout ArgumentList) throws -> Output {
        guard let text = arguments.nextPositional() else { throw CLIError.usage("set-aliases needs a term.") }
        let aliases = arguments.has("--clear")
            ? []
            : arguments.aliasArguments + arguments.restPositional.flatMap(VocabularyTextSplitter.split)
        if aliases.isEmpty, !arguments.has("--clear") {
            throw CLIError.usage("set-aliases needs mishearings, or --clear to remove them all.")
        }
        let term = try wrap { try store.updateTerm(matching: text, aliases: aliases) }
        return Output(standardOutput: "\(term.lineDescription)\n", standardError: advisoryText(for: term))
    }

    private func importGlossary(_ store: VocabularyStore, _ arguments: inout ArgumentList) throws -> Output {
        guard let path = arguments.nextPositional() else { throw CLIError.usage("import needs a file, or - for standard input.") }
        let text: String
        if path == "-" {
            text = readStandardInput()
        } else {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            do {
                text = try String(contentsOf: url, encoding: .utf8)
            } catch {
                throw CLIError.data("\(path) could not be read: \(error.localizedDescription)")
            }
        }
        let listID = try packID(store, arguments.packName)
        let summary = try wrap {
            try store.importText(text, into: listID, replacingExisting: arguments.has("--replace"))
        }
        return Output(
            standardOutput: "\(summary.summaryText)\n",
            standardError: summary.skippedLines.map { "skipped \($0)\n" }.joined()
        )
    }

    private func export(_ store: VocabularyStore, _ arguments: inout ArgumentList) throws -> Output {
        let listID = try packID(store, arguments.packName)
        let text = try wrap { try store.exportText(listID: listID) }
        guard let path = arguments.nextPositional() else { return Output(standardOutput: text) }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw CLIError.data("\(path) could not be written: \(error.localizedDescription)")
        }
        return Output(standardOutput: "Wrote \(url.path)\n")
    }

    private func clear(_ store: VocabularyStore, _ arguments: inout ArgumentList) throws -> Output {
        guard arguments.has("--force") else {
            throw CLIError.usage("clear removes every term. Pass --force to confirm.")
        }
        let listID = try packID(store, arguments.packName)
        let library = try load(store)
        let count = library.list(id: listID ?? library.personal.id)?.terms.count ?? 0
        try wrap { try store.removeAllTerms(listID: listID) }
        return Output(standardOutput: "Removed \(count) term\(count == 1 ? "" : "s")\n")
    }

    private func packs(_ store: VocabularyStore, _ arguments: inout ArgumentList) throws -> Output {
        let library = try load(store)
        if arguments.has("--json") {
            return Output(standardOutput: try json(lists: library.lists, revision: library.revision))
        }
        let lines = library.lists.map { list in
            let state = list.kind == .personal ? "always on" : (list.isEnabled ? "enabled" : "disabled")
            return "\(list.name) — \(state), \(list.terms.count) term\(list.terms.count == 1 ? "" : "s")"
        }
        return Output(standardOutput: lines.joined(separator: "\n") + "\n")
    }

    private func pack(_ store: VocabularyStore, _ arguments: inout ArgumentList) throws -> Output {
        guard let action = arguments.nextPositional() else {
            throw CLIError.usage("pack needs add, enable, disable, or remove.")
        }
        guard let name = arguments.nextPositional() else { throw CLIError.usage("pack \(action) needs a name.") }
        switch action {
        case "add":
            let list = try wrap { try store.addPack(named: name) }
            return Output(standardOutput: "Added pack \(list.name)\n")
        case "enable", "disable":
            guard let id = try packID(store, name) else { throw CLIError.data("There is no pack named “\(name)”.") }
            try wrap { try store.setPackEnabled(action == "enable", listID: id) }
            return Output(standardOutput: "\(action == "enable" ? "Enabled" : "Disabled") \(name)\n")
        case "remove":
            guard let id = try packID(store, name) else { throw CLIError.data("There is no pack named “\(name)”.") }
            try wrap { try store.removePack(id: id) }
            return Output(standardOutput: "Removed pack \(name)\n")
        default:
            throw CLIError.usage("Unknown pack action “\(action)”.")
        }
    }

    private func revision(_ store: VocabularyStore, _ arguments: inout ArgumentList) throws -> Output {
        let library = try load(store)
        if arguments.has("--json") {
            let payload: [String: Any] = [
                "revision": library.revision ?? NSNull(),
                "activeTermCount": library.activeTerms.count,
            ]
            return Output(standardOutput: try jsonString(payload))
        }
        return Output(standardOutput: (library.revision ?? "(empty vocabulary)") + "\n")
    }

    // MARK: Support

    private func openStore(_ arguments: inout ArgumentList) throws -> VocabularyStore {
        let directory = arguments.value("--directory").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
        do {
            return try makeStore(directory)
        } catch {
            throw CLIError.data(error.localizedDescription)
        }
    }

    private func load(_ store: VocabularyStore) throws -> VocabularyLibrary {
        try wrap { try store.load() }
    }

    /// Resolves `--pack <name>` to a list id. A name that matches no pack is a
    /// data error rather than a silent write into the personal list.
    private func packID(_ store: VocabularyStore, _ name: String?) throws -> UUID? {
        guard let name, !name.isEmpty else { return nil }
        let library = try load(store)
        let key = VocabularyText.matchKey(name)
        guard let list = library.lists.first(where: { VocabularyText.matchKey($0.name) == key }) else {
            throw CLIError.data("There is no vocabulary list named “\(name)”. Run `scribe-vocab packs` to see them.")
        }
        return list.id
    }

    /// Store errors already read as sentences; they become data errors so the
    /// caller does not get a usage dump for a term that simply is not there.
    private func wrap<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError.data(error.localizedDescription)
        }
    }

    private func advisoryText(for term: VocabularyTerm) -> String {
        term.advisories.map { "warning: \($0.message)\n" }.joined()
    }

    private func json(lists: [VocabularyList], revision: String?) throws -> String {
        let payload: [String: Any] = [
            "revision": revision ?? NSNull(),
            "lists": lists.map { list -> [String: Any] in
                [
                    "id": list.id.uuidString,
                    "name": list.name,
                    "kind": list.kind.rawValue,
                    "enabled": list.isActive,
                    "terms": list.terms.map { term -> [String: Any] in
                        [
                            "text": term.text,
                            "aliases": term.aliases,
                            "notes": term.notes ?? NSNull(),
                            "applied": term.isBoostable,
                        ]
                    },
                ]
            },
        ]
        return try jsonString(payload)
    }

    private func jsonString(_ payload: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
        return (String(data: data, encoding: .utf8) ?? "{}") + "\n"
    }
}
