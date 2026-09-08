import Foundation

/// The command's argument vector, consumed positionally with a small set of
/// long options.
///
/// Hand-rolled rather than pulled from a package because every other tool in
/// this repository parses its own arguments, and adding a dependency to a
/// helper that takes six flags is not worth the pin.
public struct ArgumentList {
    private var remaining: [String]
    private var options: [String: [String]] = [:]
    private var flags: Set<String> = []

    /// Options that take a value. Everything else beginning with `--` is a flag,
    /// so a typo becomes an "unknown option" rather than eating the next word.
    private static let valueOptions: Set<String> = ["--alias", "--aliases", "--note", "--pack", "--list", "--directory"]
    private static let knownFlags: Set<String> = ["--json", "--all", "--replace", "--clear", "--force", "--help", "-h"]

    public init(_ arguments: [String]) throws {
        var positional: [String] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            if Self.valueOptions.contains(argument) {
                index = arguments.index(after: index)
                guard index < arguments.endIndex else { throw CLIError.usage("\(argument) needs a value.") }
                options[argument, default: []].append(arguments[index])
            } else if Self.knownFlags.contains(argument) {
                flags.insert(argument)
            } else if argument.hasPrefix("--"), argument != "--" {
                throw CLIError.usage("Unknown option \(argument).")
            } else {
                positional.append(argument)
            }
            index = arguments.index(after: index)
        }
        remaining = positional
    }

    public mutating func nextPositional() -> String? {
        remaining.isEmpty ? nil : remaining.removeFirst()
    }

    public var restPositional: [String] {
        remaining
    }

    public func has(_ flag: String) -> Bool { flags.contains(flag) }

    public func value(_ option: String) -> String? { options[option]?.last }

    public func values(_ option: String) -> [String] { options[option] ?? [] }

    /// `--alias a --alias b --alias "c, d"` all mean the same thing, because an
    /// agent writing a shell line and a person typing one reach for different
    /// shapes of the same idea.
    public var aliasArguments: [String] {
        (values("--alias") + values("--aliases")).flatMap(VocabularyTextSplitter.split)
    }

    /// `--pack` and `--list` are accepted for the same thing.
    public var packName: String? { value("--pack") ?? value("--list") }
}

enum VocabularyTextSplitter {
    static func split(_ value: String) -> [String] {
        value.split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

public enum CLIError: Error, Equatable {
    /// Wrong arguments: exit 64, and print the usage.
    case usage(String)
    /// Right arguments, wrong data — an unknown term, a missing file: exit 65.
    case data(String)

    public var message: String {
        switch self {
        case .usage(let text), .data(let text): text
        }
    }

    public var exitCode: Int32 {
        switch self {
        case .usage: 64
        case .data: 65
        }
    }
}
