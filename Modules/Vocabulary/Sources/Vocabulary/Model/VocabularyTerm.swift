import Foundation

/// One spelling transcription should produce, plus the mishearings that stand
/// in for it.
///
/// `text` is the canonical spelling written into the transcript. `aliases` are
/// what the recognizer tends to hear instead — "Liv Mali" for "Livmarli" — not
/// synonyms. A synonym alias over-matches, which is why the editor says so.
public struct VocabularyTerm: Equatable, Hashable, Identifiable, Sendable {
    /// Shortest term the recognizer's word spotter will consider. Anything
    /// shorter is kept in the list, shown as inactive, and left out of the
    /// snapshot rather than silently dropped on save.
    public static let minimumLength = 3

    public let id: UUID
    /// The canonical spelling, already sanitized.
    public private(set) var text: String
    /// Sanitized, de-duplicated, and case-insensitively distinct from `text`.
    public private(set) var aliases: [String]
    /// A person's own note about why the term is here. Never sent to the engine.
    public private(set) var notes: String?

    public init(id: UUID = UUID(), text: String, aliases: [String] = [], notes: String? = nil) {
        self.id = id
        self.text = VocabularyText.sanitize(text)
        self.aliases = VocabularyText.sanitizeAliases(aliases, excluding: self.text)
        self.notes = VocabularyText.sanitizeNote(notes)
    }

    /// A copy with the given fields replaced, re-sanitized and keeping the id.
    /// Editing a term must not make it a new one: the id is what the editor's
    /// selection and the undo of a rename both hold on to.
    public func updating(text: String? = nil, aliases: [String]? = nil, notes: String?? = nil) -> VocabularyTerm {
        VocabularyTerm(
            id: id,
            text: text ?? self.text,
            aliases: aliases ?? self.aliases,
            notes: notes ?? self.notes
        )
    }

    /// Case- and whitespace-insensitive identity. Two terms with the same key
    /// are the same entry, so re-adding a term updates it instead of leaving a
    /// duplicate the person then has to find.
    public var key: String { VocabularyText.matchKey(text) }

    /// Whether this term is long enough for the recognizer to act on it.
    public var isBoostable: Bool { text.count >= Self.minimumLength }

    /// Advisories the editor and the command line both show. They never block a
    /// save: a person adding "AI" should be told it will not be boosted, not
    /// stopped from recording that they tried.
    public var advisories: [VocabularyAdvisory] {
        var found: [VocabularyAdvisory] = []
        if !isBoostable { found.append(.tooShort) }
        if VocabularyStopwords.contains(text) { found.append(.commonWord) }
        for alias in aliases where alias.count < Self.minimumLength {
            found.append(.aliasTooShort(alias))
        }
        return found
    }

    /// `Canonical: alias, other alias`, the line form used by the text glossary
    /// and by `scribe-vocab list`.
    public var lineDescription: String {
        aliases.isEmpty ? text : "\(text): \(aliases.joined(separator: ", "))"
    }
}

extension VocabularyTerm: Codable {
    private enum CodingKeys: String, CodingKey { case id, text, aliases, notes }

    /// Decoding goes back through the sanitizing initializer so a hand-edited
    /// or command-line-written file cannot put ragged whitespace, duplicate
    /// aliases, or an alias equal to its own term into the library.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            text: try container.decode(String.self, forKey: .text),
            aliases: try container.decodeIfPresent([String].self, forKey: .aliases) ?? [],
            notes: try container.decodeIfPresent(String.self, forKey: .notes)
        )
    }
}

/// A reason the editor warns about a term without refusing it.
public enum VocabularyAdvisory: Equatable, Hashable, Sendable {
    case tooShort
    case commonWord
    case aliasTooShort(String)

    public var message: String {
        switch self {
        case .tooShort:
            "Shorter than \(VocabularyTerm.minimumLength) characters — kept in the list, but not applied to transcription."
        case .commonWord:
            "This is a common English word. Boosting it is likely to rewrite ordinary speech."
        case .aliasTooShort(let alias):
            "The mishearing “\(alias)” is shorter than \(VocabularyTerm.minimumLength) characters and will be ignored."
        }
    }
}

/// Advisory only. Short function words are the ones a word spotter mistakes for
/// a boosted term, so the editor names them rather than silently accepting a
/// glossary that will corrupt ordinary speech.
enum VocabularyStopwords {
    static func contains(_ text: String) -> Bool { words.contains(VocabularyText.matchKey(text)) }

    private static let words: Set<String> = [
        "a", "about", "all", "an", "and", "any", "are", "as", "at", "be", "been", "but", "by", "can",
        "did", "do", "does", "for", "from", "get", "had", "has", "have", "he", "her", "here", "him",
        "his", "how", "i", "if", "in", "is", "it", "its", "just", "like", "me", "more", "my", "no",
        "not", "of", "on", "one", "or", "our", "out", "over", "she", "so", "some", "than", "that",
        "the", "their", "them", "then", "there", "these", "they", "this", "to", "too", "up", "us",
        "was", "we", "were", "what", "when", "where", "which", "who", "why", "will", "with", "would",
        "you", "your",
    ]
}
