import CryptoKit
import Foundation

/// The whole on-disk document: one personal list, plus any packs.
public struct VocabularyLibrary: Codable, Equatable, Sendable {
    /// Bumped only when the file's shape changes in a way an older build could
    /// not read. Decoding tolerates unknown future terms rather than refusing.
    public static let currentSchemaVersion = 1

    public private(set) var schemaVersion: Int
    public private(set) var lists: [VocabularyList]
    public private(set) var updatedAt: Date

    public init(lists: [VocabularyList] = [.makePersonal()], updatedAt: Date = Date()) {
        self.schemaVersion = Self.currentSchemaVersion
        self.lists = Self.normalized(lists)
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        lists = Self.normalized(try container.decodeIfPresent([VocabularyList].self, forKey: .lists) ?? [])
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    /// The always-on list. Guaranteed to exist: `normalized` creates it when a
    /// file arrives without one, so no caller has to handle its absence.
    public var personal: VocabularyList {
        // swiftlint:disable:next force_unwrapping - normalized() guarantees one.
        lists.first { $0.kind == .personal }!
    }

    public var packs: [VocabularyList] { lists.filter { $0.kind == .pack } }

    public func list(id: UUID) -> VocabularyList? { lists.first { $0.id == id } }

    /// Every term the recognizer will be given: the personal list unioned with
    /// the enabled packs, de-duplicated by spelling. Terms too short to boost
    /// are already excluded.
    public var activeTerms: [VocabularyTerm] {
        VocabularyList.deduplicated(lists.filter(\.isActive).flatMap(\.terms)).filter(\.isBoostable)
    }

    /// A content hash of the active terms, in the shape
    /// `ImportConfiguration.vocabularyRevision` records.
    ///
    /// An empty vocabulary hashes to `nil`, not to the digest of an empty
    /// string: a person who has never added a term must keep the fingerprints
    /// their existing runs were stored under.
    public var revision: String? {
        let terms = activeTerms
        guard !terms.isEmpty else { return nil }
        let body = terms
            .map { "\($0.key)\t\($0.aliases.map(VocabularyText.matchKey).sorted().joined(separator: "\u{1F}"))" }
            .sorted()
            .joined(separator: "\n")
        let digest = SHA256.hash(data: Data("scribe.vocabulary.v1\n\(body)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// What the transcription pipeline is handed. Kept separate from the
    /// document so a job records the terms it actually ran with.
    public var snapshot: VocabularySnapshot {
        VocabularySnapshot(revision: revision, terms: activeTerms)
    }

    // MARK: Mutation

    /// Applies a change to one list and stamps the document.
    ///
    /// Every mutation funnels through here so `updatedAt` can never drift from
    /// the content, which is what the settings window watches to notice an edit
    /// made by `scribe-vocab` while it was open.
    public mutating func update<T>(
        listID: UUID? = nil,
        now: Date = Date(),
        _ body: (inout VocabularyList) -> T
    ) -> T? {
        let targetID = listID ?? personal.id
        guard let index = lists.firstIndex(where: { $0.id == targetID }) else { return nil }
        let result = body(&lists[index])
        updatedAt = now
        return result
    }

    public mutating func addPack(named name: String, now: Date = Date()) -> VocabularyList {
        let pack = VocabularyList(name: name, kind: .pack)
        lists.append(pack)
        lists = Self.normalized(lists)
        updatedAt = now
        return pack
    }

    /// Removes a pack. The personal list is never removable.
    @discardableResult
    public mutating func removeList(id: UUID, now: Date = Date()) -> Bool {
        guard let index = lists.firstIndex(where: { $0.id == id }), lists[index].kind == .pack else { return false }
        lists.remove(at: index)
        updatedAt = now
        return true
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, lists, updatedAt }

    /// Exactly one personal list, first, then packs by name.
    private static func normalized(_ lists: [VocabularyList]) -> [VocabularyList] {
        var personalLists = lists.filter { $0.kind == .personal }
        let packs = lists.filter { $0.kind == .pack }.sorted { $0.name.lowercased() < $1.name.lowercased() }
        if personalLists.isEmpty {
            personalLists = [.makePersonal()]
        } else if personalLists.count > 1 {
            // A hand-merged file can carry two. Fold the extras in rather than
            // discarding terms someone meant to keep.
            var primary = personalLists[0]
            primary.replaceAll(with: personalLists.flatMap(\.terms))
            personalLists = [primary]
        }
        return personalLists + packs
    }
}

/// The immutable view transcription consumes.
public struct VocabularySnapshot: Codable, Equatable, Sendable {
    public let revision: String?
    public let terms: [VocabularyTerm]

    public init(revision: String?, terms: [VocabularyTerm]) {
        self.revision = revision
        self.terms = terms
    }

    public var isEmpty: Bool { terms.isEmpty }
}
