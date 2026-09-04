import Foundation

/// SQLite speaker library stored under a local directory.
///
/// The production directory is Application Support; tests pass a temporary
/// folder. Signature vectors and enrollment clips are files in that directory
/// and are never part of `SpeakerPersonRef`.
public actor SpeakerProfileStore: SpeakerLibrary {
    public nonisolated static let databaseFileName = "library.sqlite"
    public nonisolated static let clipsDirectoryName = "clips"

    public nonisolated let directoryURL: URL
    public nonisolated let databaseURL: URL

    private let database: SQLiteDatabase
    private let jsonEncoder: JSONEncoder
    private let jsonDecoder: JSONDecoder

    public init(directoryURL: URL) throws {
        self.directoryURL = directoryURL
        self.databaseURL = directoryURL.appendingPathComponent(Self.databaseFileName)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        self.database = try SQLiteDatabase(fileURL: databaseURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.jsonEncoder = encoder
        self.jsonDecoder = JSONDecoder()
        try database.execute(Self.schemaSQL)
    }

    nonisolated public static func openApplicationSupportLibrary() throws -> SpeakerProfileStore {
        try SpeakerProfileStore(directoryURL: SpeakersModule.applicationSupportDirectory())
    }

    public func revision() throws -> SpeakerLibraryRevision {
        try loadRevision()
    }

    public func snapshot() throws -> SpeakerLibrarySnapshot {
        SpeakerLibrarySnapshot(revision: try loadRevision(), profiles: try loadProfiles(profileID: nil))
    }

    public func people() throws -> [SpeakerPersonRef] {
        try loadProfiles(profileID: nil).map(\.personRef)
    }

    public func person(id: UUID) throws -> SpeakerPersonRef? {
        try loadProfiles(profileID: id).first?.personRef
    }

    public func profile(id: UUID) throws -> SpeakerProfile? {
        try loadProfiles(profileID: id).first
    }

    public func profiles() throws -> [SpeakerProfile] {
        try loadProfiles(profileID: nil)
    }

    public func matchingEligibleProfiles() throws -> [SpeakerProfile] {
        try loadProfiles(profileID: nil).filter(\.isMatchingEligible)
    }

    public func currentEmbeddingModel() throws -> SpeakerEmbeddingModelIdentity? {
        try loadCurrentEmbeddingModel()
    }

    @discardableResult
    public func createProfile(_ draft: SpeakerProfileDraft) throws -> SpeakerProfile {
        let displayName = try Self.normalizedDisplayName(draft.displayName)
        let now = Date()
        try database.transaction {
            if try loadProfiles(profileID: draft.profileID).first != nil {
                throw SpeakerProfileStoreError.profileAlreadyExists(draft.profileID)
            }
            let statement = try database.prepare(
                """
                INSERT INTO profiles (
                    profile_id, display_name, automatic_matching_enabled, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?);
                """
            )
            try statement.bind(index: 1, text: draft.profileID.uuidString)
            try statement.bind(index: 2, text: displayName)
            try statement.bind(index: 3, bool: draft.automaticMatchingEnabled)
            try statement.bind(index: 4, double: now.timeIntervalSince1970)
            try statement.bind(index: 5, double: now.timeIntervalSince1970)
            try statement.step()
            try bumpRevision()
        }
        return try requiredProfile(draft.profileID)
    }

    @discardableResult
    public func renameProfile(profileID: UUID, displayName: String) throws -> SpeakerProfile {
        let displayName = try Self.normalizedDisplayName(displayName)
        try mutateProfile(
            profileID: profileID,
            sql: "UPDATE profiles SET display_name = ?, updated_at = ? WHERE profile_id = ?;"
        ) { statement in
            try statement.bind(index: 1, text: displayName)
            try statement.bind(index: 2, double: Date().timeIntervalSince1970)
            try statement.bind(index: 3, text: profileID.uuidString)
        }
        return try requiredProfile(profileID)
    }

    @discardableResult
    public func setAutomaticMatchingEnabled(profileID: UUID, enabled: Bool) throws -> SpeakerProfile {
        try mutateProfile(
            profileID: profileID,
            sql: "UPDATE profiles SET automatic_matching_enabled = ?, updated_at = ? WHERE profile_id = ?;"
        ) { statement in
            try statement.bind(index: 1, bool: enabled)
            try statement.bind(index: 2, double: Date().timeIntervalSince1970)
            try statement.bind(index: 3, text: profileID.uuidString)
        }
        return try requiredProfile(profileID)
    }

    @discardableResult
    public func addSignature(profileID: UUID, draft: SpeakerSignatureDraft) throws -> SpeakerProfile {
        guard !draft.embeddingVector.isEmpty else {
            throw SpeakerProfileStoreError.emptyEmbeddingVector
        }
        _ = try requiredProfile(profileID)

        var copiedClipPath: String?
        do {
            if let sourceURL = draft.retainedClipURL {
                copiedClipPath = try copyClip(from: sourceURL, signatureID: draft.signatureID)
            }
            let qualityJSON = try encodeJSON(draft.qualityIndicators)
            let rangesJSON = try encodeJSON(draft.selectedTimeRanges)
            let compatibility = try compatibility(for: draft.embeddingModel)
            let vector = Self.encodeVector(draft.embeddingVector)
            try database.transaction {
                let statement = try database.prepare(
                    """
                    INSERT INTO signatures (
                        signature_id, profile_id, embedding_vector,
                        embedding_model_id, embedding_model_revision,
                        preprocessing_version, normalization_version, transform_version,
                        usable_speech_duration, quality_indicators,
                        enrollment_source_id, selected_time_ranges,
                        retained_clip_path, confirmed_at, compatibility
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """
                )
                try statement.bind(index: 1, text: draft.signatureID.uuidString)
                try statement.bind(index: 2, text: profileID.uuidString)
                try statement.bind(index: 3, data: vector)
                try statement.bind(index: 4, text: draft.embeddingModel.modelID)
                try statement.bind(index: 5, text: draft.embeddingModel.revision)
                try statement.bind(index: 6, text: draft.preprocessingVersion)
                try statement.bind(index: 7, text: draft.normalizationVersion)
                try statement.bind(index: 8, text: draft.transformVersion)
                try statement.bind(index: 9, double: draft.usableSpeechDuration)
                try statement.bind(index: 10, text: qualityJSON)
                try statement.bind(index: 11, text: draft.enrollmentSourceID)
                try statement.bind(index: 12, text: rangesJSON)
                try statement.bind(index: 13, optionalText: copiedClipPath)
                try statement.bind(index: 14, double: draft.confirmedAt.timeIntervalSince1970)
                try statement.bind(index: 15, text: compatibility.rawValue)
                try statement.step()
                try touchProfile(profileID: profileID)
                try bumpRevision()
            }
        } catch {
            if let copiedClipPath {
                removeClip(relativePath: copiedClipPath)
            }
            throw error
        }
        return try requiredProfile(profileID)
    }

    public func removeSignature(profileID: UUID, signatureID: UUID) throws {
        let existing = try requiredProfile(profileID)
        guard let signature = existing.signatures.first(where: { $0.signatureID == signatureID }) else {
            throw SpeakerProfileStoreError.signatureNotFound(signatureID)
        }
        try database.transaction {
            let statement = try database.prepare(
                "DELETE FROM signatures WHERE signature_id = ? AND profile_id = ?;"
            )
            try statement.bind(index: 1, text: signatureID.uuidString)
            try statement.bind(index: 2, text: profileID.uuidString)
            try statement.step()
            try touchProfile(profileID: profileID)
            try bumpRevision()
        }
        if let clipURL = signature.retainedClipURL {
            try? FileManager.default.removeItem(at: clipURL)
        }
    }

    public func deleteProfile(profileID: UUID) throws {
        let existing = try requiredProfile(profileID)
        try database.transaction {
            let statement = try database.prepare("DELETE FROM profiles WHERE profile_id = ?;")
            try statement.bind(index: 1, text: profileID.uuidString)
            try statement.step()
            try bumpRevision()
        }
        for signature in existing.signatures {
            if let clipURL = signature.retainedClipURL {
                try? FileManager.default.removeItem(at: clipURL)
            }
        }
    }

    /// Records the embedding model currently in use and marks signatures from
    /// any other model ID or revision as needing reenrollment.
    @discardableResult
    public func setCurrentEmbeddingModel(
        _ model: SpeakerEmbeddingModelIdentity
    ) throws -> SpeakerLibraryRevision {
        try database.transaction {
            let statement = try database.prepare(
                """
                UPDATE library_meta
                SET current_embedding_model_id = ?, current_embedding_model_revision = ?
                WHERE id = 1;
                """
            )
            try statement.bind(index: 1, text: model.modelID)
            try statement.bind(index: 2, text: model.revision)
            try statement.step()

            let mark = try database.prepare(
                """
                UPDATE signatures
                SET compatibility = CASE
                    WHEN embedding_model_id = ? AND embedding_model_revision = ?
                    THEN 'compatible'
                    ELSE 'needsReenrollment'
                END;
                """
            )
            try mark.bind(index: 1, text: model.modelID)
            try mark.bind(index: 2, text: model.revision)
            try mark.step()
            try bumpRevision()
        }
        return try loadRevision()
    }

    // MARK: - Private

    private func requiredProfile(_ profileID: UUID) throws -> SpeakerProfile {
        guard let profile = try loadProfiles(profileID: profileID).first else {
            throw SpeakerProfileStoreError.profileNotFound(profileID)
        }
        return profile
    }

    private func mutateProfile(
        profileID: UUID,
        sql: String,
        bind: (SQLiteStatement) throws -> Void
    ) throws {
        _ = try requiredProfile(profileID)
        try database.transaction {
            let statement = try database.prepare(sql)
            try bind(statement)
            try statement.step()
            try bumpRevision()
        }
    }

    private func touchProfile(profileID: UUID) throws {
        let statement = try database.prepare(
            "UPDATE profiles SET updated_at = ? WHERE profile_id = ?;"
        )
        try statement.bind(index: 1, double: Date().timeIntervalSince1970)
        try statement.bind(index: 2, text: profileID.uuidString)
        try statement.step()
    }

    private func loadRevision() throws -> SpeakerLibraryRevision {
        let statement = try database.prepare("SELECT revision FROM library_meta WHERE id = 1;")
        guard try statement.step() else {
            throw SpeakerProfileStoreError.sqlite("library_meta is missing")
        }
        return SpeakerLibraryRevision(sequence: statement.int64(at: 0))
    }

    private func bumpRevision() throws {
        try database.execute("UPDATE library_meta SET revision = revision + 1 WHERE id = 1;")
    }

    private func loadCurrentEmbeddingModel() throws -> SpeakerEmbeddingModelIdentity? {
        let statement = try database.prepare(
            """
            SELECT current_embedding_model_id, current_embedding_model_revision
            FROM library_meta WHERE id = 1;
            """
        )
        guard try statement.step() else { return nil }
        guard let modelID = statement.optionalString(at: 0),
              let revision = statement.optionalString(at: 1)
        else {
            return nil
        }
        return SpeakerEmbeddingModelIdentity(modelID: modelID, revision: revision)
    }

    private func compatibility(
        for model: SpeakerEmbeddingModelIdentity
    ) throws -> SpeakerSignatureCompatibility {
        guard let current = try loadCurrentEmbeddingModel() else {
            return .compatible
        }
        return current == model ? .compatible : .needsReenrollment
    }

    private func loadProfiles(profileID: UUID?) throws -> [SpeakerProfile] {
        let statement: SQLiteStatement
        if let profileID {
            statement = try database.prepare(
                """
                SELECT profile_id, display_name, automatic_matching_enabled, created_at, updated_at
                FROM profiles
                WHERE profile_id = ?
                ORDER BY created_at, profile_id;
                """
            )
            try statement.bind(index: 1, text: profileID.uuidString)
        } else {
            statement = try database.prepare(
                """
                SELECT profile_id, display_name, automatic_matching_enabled, created_at, updated_at
                FROM profiles
                ORDER BY created_at, profile_id;
                """
            )
        }

        var profiles: [SpeakerProfile] = []
        while try statement.step() {
            let id = try uuid(statement.string(at: 0), field: "profile_id")
            profiles.append(
                SpeakerProfile(
                    profileID: id,
                    displayName: statement.string(at: 1),
                    automaticMatchingEnabled: statement.bool(at: 2),
                    signatures: [],
                    createdAt: Date(timeIntervalSince1970: statement.double(at: 3)),
                    updatedAt: Date(timeIntervalSince1970: statement.double(at: 4))
                )
            )
        }

        let signaturesByProfile = try loadSignatures(profileID: profileID)
        return profiles.map { profile in
            SpeakerProfile(
                profileID: profile.profileID,
                displayName: profile.displayName,
                automaticMatchingEnabled: profile.automaticMatchingEnabled,
                signatures: signaturesByProfile[profile.profileID] ?? [],
                createdAt: profile.createdAt,
                updatedAt: profile.updatedAt
            )
        }
    }

    private func loadSignatures(profileID: UUID?) throws -> [UUID: [SpeakerSignature]] {
        let statement: SQLiteStatement
        if let profileID {
            statement = try database.prepare(
                """
                SELECT signature_id, profile_id, embedding_vector,
                    embedding_model_id, embedding_model_revision,
                    preprocessing_version, normalization_version, transform_version,
                    usable_speech_duration, quality_indicators,
                    enrollment_source_id, selected_time_ranges,
                    retained_clip_path, confirmed_at, compatibility
                FROM signatures
                WHERE profile_id = ?
                ORDER BY confirmed_at, signature_id;
                """
            )
            try statement.bind(index: 1, text: profileID.uuidString)
        } else {
            statement = try database.prepare(
                """
                SELECT signature_id, profile_id, embedding_vector,
                    embedding_model_id, embedding_model_revision,
                    preprocessing_version, normalization_version, transform_version,
                    usable_speech_duration, quality_indicators,
                    enrollment_source_id, selected_time_ranges,
                    retained_clip_path, confirmed_at, compatibility
                FROM signatures
                ORDER BY confirmed_at, signature_id;
                """
            )
        }

        var grouped: [UUID: [SpeakerSignature]] = [:]
        while try statement.step() {
            let profileID = try uuid(statement.string(at: 1), field: "profile_id")
            let relativeClipPath = statement.optionalString(at: 12)
            let signature = SpeakerSignature(
                signatureID: try uuid(statement.string(at: 0), field: "signature_id"),
                embeddingVector: Self.decodeVector(statement.data(at: 2)),
                embeddingModel: SpeakerEmbeddingModelIdentity(
                    modelID: statement.string(at: 3),
                    revision: statement.string(at: 4)
                ),
                preprocessingVersion: statement.string(at: 5),
                normalizationVersion: statement.string(at: 6),
                transformVersion: statement.string(at: 7),
                usableSpeechDuration: statement.double(at: 8),
                qualityIndicators: try decodeJSON(statement.string(at: 9), as: SpeakerSignatureQuality.self),
                enrollmentSourceID: statement.string(at: 10),
                selectedTimeRanges: try decodeJSON(statement.string(at: 11), as: [SpeakerTimeRange].self),
                retainedClipURL: relativeClipPath.map { directoryURL.appendingPathComponent($0) },
                confirmedAt: Date(timeIntervalSince1970: statement.double(at: 13)),
                compatibility: SpeakerSignatureCompatibility(rawValue: statement.string(at: 14)) ?? .needsReenrollment
            )
            grouped[profileID, default: []].append(signature)
        }
        return grouped
    }

    private func copyClip(from sourceURL: URL, signatureID: UUID) throws -> String {
        let fileManager = FileManager.default
        let clips = directoryURL.appendingPathComponent(Self.clipsDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: clips, withIntermediateDirectories: true)
        let ext = sourceURL.pathExtension
        let filename = ext.isEmpty ? signatureID.uuidString : "\(signatureID.uuidString).\(ext)"
        let destination = clips.appendingPathComponent(filename)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        do {
            try fileManager.copyItem(at: sourceURL, to: destination)
        } catch {
            throw SpeakerProfileStoreError.io("Could not retain enrollment clip: \(error.localizedDescription)")
        }
        return "\(Self.clipsDirectoryName)/\(filename)"
    }

    private func removeClip(relativePath: String) {
        let url = directoryURL.appendingPathComponent(relativePath)
        try? FileManager.default.removeItem(at: url)
    }

    private func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let data = try jsonEncoder.encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw SpeakerProfileStoreError.io("Could not encode JSON")
        }
        return text
    }

    private func decodeJSON<T: Decodable>(_ text: String, as type: T.Type) throws -> T {
        guard let data = text.data(using: .utf8) else {
            throw SpeakerProfileStoreError.sqlite("Invalid JSON encoding")
        }
        return try jsonDecoder.decode(type, from: data)
    }

    private func uuid(_ text: String, field: String) throws -> UUID {
        guard let value = UUID(uuidString: text) else {
            throw SpeakerProfileStoreError.sqlite("Invalid UUID in \(field)")
        }
        return value
    }

    private static func normalizedDisplayName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SpeakerProfileStoreError.invalidDisplayName
        }
        return trimmed
    }

    private static func encodeVector(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }

    private static func decodeVector(_ data: Data) -> [Float] {
        guard data.count >= MemoryLayout<Float>.size else { return [] }
        let count = data.count / MemoryLayout<Float>.size
        return data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self).prefix(count))
        }
    }

    private static let schemaSQL = """
        CREATE TABLE IF NOT EXISTS library_meta (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            schema_version INTEGER NOT NULL,
            revision INTEGER NOT NULL,
            current_embedding_model_id TEXT,
            current_embedding_model_revision TEXT
        );
        INSERT OR IGNORE INTO library_meta (id, schema_version, revision)
        VALUES (1, 1, 0);

        CREATE TABLE IF NOT EXISTS profiles (
            profile_id TEXT PRIMARY KEY,
            display_name TEXT NOT NULL,
            automatic_matching_enabled INTEGER NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS signatures (
            signature_id TEXT PRIMARY KEY,
            profile_id TEXT NOT NULL REFERENCES profiles(profile_id) ON DELETE CASCADE,
            embedding_vector BLOB NOT NULL,
            embedding_model_id TEXT NOT NULL,
            embedding_model_revision TEXT NOT NULL,
            preprocessing_version TEXT NOT NULL,
            normalization_version TEXT NOT NULL,
            transform_version TEXT NOT NULL,
            usable_speech_duration REAL NOT NULL,
            quality_indicators TEXT NOT NULL,
            enrollment_source_id TEXT NOT NULL,
            selected_time_ranges TEXT NOT NULL,
            retained_clip_path TEXT,
            confirmed_at REAL NOT NULL,
            compatibility TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS signatures_profile_id ON signatures(profile_id);
        """
}
