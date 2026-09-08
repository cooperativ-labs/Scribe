import Foundation

/// Sanitizing and matching rules shared by the store, the editor, and the
/// command line, so a term added from an agent's shell and one typed into
/// Settings end up as the same row.
public enum VocabularyText {
    /// Trims, collapses runs of whitespace, and strips control characters.
    ///
    /// Spellings keep their case: "macOS" is the point of the entry. Only the
    /// shape of the whitespace is normalized.
    public static func sanitize(_ value: String) -> String {
        let scalars = value.unicodeScalars.map { scalar -> Character in
            CharacterSet.whitespacesAndNewlines.contains(scalar) ? " " : Character(scalar)
        }
        return String(scalars)
            .filter { !$0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    /// Sanitizes, drops empties, drops anything equal to the canonical spelling,
    /// and keeps the first of any case-insensitive duplicates.
    public static func sanitizeAliases(_ aliases: [String], excluding text: String) -> [String] {
        let excluded = matchKey(text)
        var seen: Set<String> = [excluded]
        var kept: [String] = []
        for alias in aliases {
            let sanitized = sanitize(alias)
            guard !sanitized.isEmpty else { continue }
            let key = matchKey(sanitized)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            kept.append(sanitized)
        }
        return kept
    }

    public static func sanitizeNote(_ note: String?) -> String? {
        guard let note else { return nil }
        let sanitized = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? nil : sanitized
    }

    /// The identity two spellings are compared under: case-folded, with
    /// diacritics kept. "NVIDIA" and "Nvidia" are one entry; "resume" and
    /// "résumé" are not.
    public static func matchKey(_ value: String) -> String {
        sanitize(value).lowercased()
    }

    /// Splits a comma- or semicolon-separated alias argument, the form both the
    /// editor field and `--aliases` accept.
    public static func splitAliases(_ value: String) -> [String] {
        value.split(whereSeparator: { $0 == "," || $0 == ";" }).map(String.init)
    }
}

/// The plain-text glossary format, matching what FluidAudio's own vocabulary
/// files look like so an existing list can be pasted in unchanged.
///
/// ```
/// # Product names
/// NVIDIA
/// macOS: Mac OS, Mac O S, Macos
/// Livmarli: Liv Mali, Liv-Marli
/// ```
///
/// A line is `canonical` or `canonical: mishearing, mishearing`. Blank lines
/// and `#` comments are skipped.
public enum VocabularyTextFormat {
    public struct ParseResult: Equatable, Sendable {
        public let terms: [VocabularyTerm]
        /// One-based line numbers that carried nothing usable, with why. The
        /// importer reports these instead of failing the whole file: a glossary
        /// with one bad line should still bring in the other two hundred.
        public let skipped: [(line: Int, reason: String)]

        public init(terms: [VocabularyTerm], skipped: [(line: Int, reason: String)]) {
            self.terms = terms
            self.skipped = skipped
        }

        public static func == (lhs: ParseResult, rhs: ParseResult) -> Bool {
            lhs.terms == rhs.terms
                && lhs.skipped.count == rhs.skipped.count
                && zip(lhs.skipped, rhs.skipped).allSatisfy { $0.line == $1.line && $0.reason == $1.reason }
        }
    }

    public static func parse(_ text: String) -> ParseResult {
        var terms: [VocabularyTerm] = []
        var skipped: [(line: Int, reason: String)] = []
        for (offset, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let canonical = VocabularyText.sanitize(String(parts[0]))
            guard !canonical.isEmpty else {
                skipped.append((offset + 1, "no term before the colon"))
                continue
            }
            let aliases = parts.count > 1 ? VocabularyText.splitAliases(String(parts[1])) : []
            terms.append(VocabularyTerm(text: canonical, aliases: aliases))
        }
        return ParseResult(terms: VocabularyList.deduplicated(terms), skipped: skipped)
    }

    /// Renders terms back to the same format, so export and import round-trip.
    public static func render(_ terms: [VocabularyTerm]) -> String {
        guard !terms.isEmpty else { return "" }
        return VocabularyList.sorted(terms).map(\.lineDescription).joined(separator: "\n") + "\n"
    }
}
