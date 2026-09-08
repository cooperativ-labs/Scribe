import Foundation

/// A named group of terms.
///
/// There is exactly one `.personal` list and it can never be turned off: it is
/// the "one vocabulary for all of my work" the design settled on. Packs are the
/// escape hatch for a client glossary someone does not want in every job; they
/// are still merged at job time rather than picked per recording.
public struct VocabularyList: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case personal
        case pack
    }

    public let id: UUID
    public private(set) var name: String
    public let kind: Kind
    /// Ignored for `.personal`, which is always on.
    public private(set) var isEnabled: Bool
    public private(set) var terms: [VocabularyTerm]

    public init(
        id: UUID = UUID(),
        name: String,
        kind: Kind,
        isEnabled: Bool = true,
        terms: [VocabularyTerm] = []
    ) {
        self.id = id
        self.name = VocabularyText.sanitize(name)
        self.kind = kind
        self.isEnabled = kind == .personal ? true : isEnabled
        self.terms = VocabularyList.deduplicated(terms)
    }

    /// The default, empty personal list a first launch creates.
    public static func makePersonal() -> VocabularyList {
        VocabularyList(name: "Personal", kind: .personal)
    }

    /// Whether the transcription pipeline reads this list.
    public var isActive: Bool { kind == .personal || isEnabled }

    public var boostableTerms: [VocabularyTerm] { terms.filter(\.isBoostable) }

    public func term(id: UUID) -> VocabularyTerm? { terms.first { $0.id == id } }

    public func term(matching text: String) -> VocabularyTerm? {
        let key = VocabularyText.matchKey(text)
        return terms.first { $0.key == key }
    }

    // MARK: Mutation

    /// Adds the term, or merges it into an existing entry with the same key.
    ///
    /// Merging rather than duplicating is what makes `scribe-vocab add` safe to
    /// run twice: an agent that re-adds a term with one new mishearing gets a
    /// term with both, not two rows spelled the same.
    @discardableResult
    public mutating func upsert(_ term: VocabularyTerm) -> VocabularyTerm {
        guard let index = terms.firstIndex(where: { $0.key == term.key }) else {
            terms.append(term)
            sort()
            return term
        }
        let merged = terms[index].updating(
            text: term.text,
            aliases: terms[index].aliases + term.aliases,
            // Explicitly wrapped: `notes` takes a double optional, so an
            // unwrapped `??` here would promote the left side and silently
            // clear a note the person had written.
            notes: .some(term.notes ?? terms[index].notes)
        )
        terms[index] = merged
        sort()
        return merged
    }

    /// Replaces a term in place, keeping its identity. Returns false when the
    /// new spelling collides with a different term, which the caller reports
    /// rather than silently merging an edit into someone else's row.
    public mutating func replace(id: UUID, with term: VocabularyTerm) -> Bool {
        guard let index = terms.firstIndex(where: { $0.id == id }) else { return false }
        if terms.contains(where: { $0.id != id && $0.key == term.key }) { return false }
        // Rebuilt against the row's own id: replacing a term must not change
        // which row it is, whatever id the caller happened to construct.
        terms[index] = VocabularyTerm(id: id, text: term.text, aliases: term.aliases, notes: term.notes)
        sort()
        return true
    }

    @discardableResult
    public mutating func remove(id: UUID) -> VocabularyTerm? {
        guard let index = terms.firstIndex(where: { $0.id == id }) else { return nil }
        return terms.remove(at: index)
    }

    @discardableResult
    public mutating func remove(matching text: String) -> VocabularyTerm? {
        guard let existing = term(matching: text) else { return nil }
        return remove(id: existing.id)
    }

    public mutating func replaceAll(with newTerms: [VocabularyTerm]) {
        terms = VocabularyList.deduplicated(newTerms)
    }

    public mutating func setEnabled(_ enabled: Bool) {
        guard kind != .personal else { return }
        isEnabled = enabled
    }

    public mutating func rename(to newName: String) {
        let sanitized = VocabularyText.sanitize(newName)
        guard !sanitized.isEmpty else { return }
        name = sanitized
    }

    private mutating func sort() { terms = VocabularyList.sorted(terms) }

    /// Alphabetical, case-insensitive. The list is a reference a person reads,
    /// so insertion order would only make a term hard to find again.
    static func sorted(_ terms: [VocabularyTerm]) -> [VocabularyTerm] {
        terms.sorted { $0.key == $1.key ? $0.text < $1.text : $0.key < $1.key }
    }

    static func deduplicated(_ terms: [VocabularyTerm]) -> [VocabularyTerm] {
        var merged: [VocabularyTerm] = []
        for term in terms where !term.text.isEmpty {
            if let index = merged.firstIndex(where: { $0.key == term.key }) {
                merged[index] = merged[index].updating(
                    aliases: merged[index].aliases + term.aliases,
                    notes: .some(merged[index].notes ?? term.notes)
                )
            } else {
                merged.append(term)
            }
        }
        return sorted(merged)
    }
}
