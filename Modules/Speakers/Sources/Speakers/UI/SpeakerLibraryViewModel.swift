import Foundation
import Observation

/// One profile as the Speakers view presents it.
///
/// The row deliberately exposes matching eligibility as its own state so a
/// name-only profile reads as "will not match automatically" rather than as a
/// profile whose toggle is simply off.
public struct SpeakerLibraryRow: Identifiable, Equatable, Sendable {
    public let profile: SpeakerProfile

    public var id: UUID { profile.profileID }
    public var displayName: String { profile.displayName }
    public var automaticMatchingEnabled: Bool { profile.automaticMatchingEnabled }
    public var signatures: [SpeakerSignature] { profile.signatures }

    /// A profile with a name and no compatible signature can never be matched
    /// automatically, whatever its toggle says.
    public var isNameOnly: Bool { !profile.signatures.contains(where: \.isCompatible) }

    public var needsReenrollment: Bool {
        !profile.signatures.isEmpty && !profile.signatures.contains(where: \.isCompatible)
    }

    public var usableSpeechDuration: TimeInterval {
        profile.signatures.reduce(0) { $0 + $1.usableSpeechDuration }
    }

    public var matchingStatus: String {
        if isNameOnly {
            return needsReenrollment
                ? "Signatures need reenrollment — will not match automatically"
                : "Name only — will not match automatically"
        }
        return automaticMatchingEnabled ? "Matches automatically" : "Automatic matching off"
    }

    public init(profile: SpeakerProfile) {
        self.profile = profile
    }
}

/// State and actions behind the Speakers view.
///
/// Every mutation goes through `SpeakerProfileStore`, so deletions and toggles
/// take effect for future matching immediately while transcripts keep the
/// labels their revisions already recorded.
@MainActor
@Observable
public final class SpeakerLibraryViewModel {
    public private(set) var rows: [SpeakerLibraryRow] = []
    public private(set) var revision: SpeakerLibraryRevision?
    public private(set) var errorMessage: String?
    public var selectedProfileID: UUID?

    @ObservationIgnored private let store: SpeakerProfileStore

    public init(store: SpeakerProfileStore) {
        self.store = store
    }

    public var selectedRow: SpeakerLibraryRow? {
        guard let selectedProfileID else { return nil }
        return rows.first { $0.id == selectedProfileID }
    }

    public func load() async {
        await perform(clearingError: false) {
            let snapshot = try await self.store.snapshot()
            self.revision = snapshot.revision
            self.rows = snapshot.profiles
                .map(SpeakerLibraryRow.init)
                .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            if let selected = self.selectedProfileID, !self.rows.contains(where: { $0.id == selected }) {
                self.selectedProfileID = nil
            }
        }
    }

    /// Adds a person by name only. Enrollment is a separate, explicit action,
    /// so this profile stays out of automatic matching until it has signatures.
    @discardableResult
    public func addPerson(named name: String) async -> SpeakerPersonRef? {
        var created: SpeakerPersonRef?
        guard await perform({
            created = try await self.store.createProfile(SpeakerProfileDraft(displayName: name)).personRef
        }) else { return nil }
        await load()
        selectedProfileID = created?.profileID
        return created
    }

    public func rename(profileID: UUID, to name: String) async {
        await reloading { _ = try await self.store.renameProfile(profileID: profileID, displayName: name) }
    }

    public func setAutomaticMatching(_ enabled: Bool, for profileID: UUID) async {
        await reloading { _ = try await self.store.setAutomaticMatchingEnabled(profileID: profileID, enabled: enabled) }
    }

    public func removeSignature(_ signatureID: UUID, from profileID: UUID) async {
        await reloading { try await self.store.removeSignature(profileID: profileID, signatureID: signatureID) }
    }

    public func deleteProfile(_ profileID: UUID) async {
        await reloading { try await self.store.deleteProfile(profileID: profileID) }
    }

    public func clearError() {
        errorMessage = nil
    }

    /// Reloads only after a successful write, so a failure's message survives.
    private func reloading(_ work: () async throws -> Void) async {
        guard await perform(work) else { return }
        await load()
    }

    @discardableResult
    private func perform(clearingError: Bool = true, _ work: () async throws -> Void) async -> Bool {
        do {
            try await work()
            if clearingError { errorMessage = nil }
            return true
        } catch {
            errorMessage = Self.describe(error)
            return false
        }
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? LocalizedError, let description = error.errorDescription { return description }
        if let error = error as? SpeakerProfileStoreError {
            return switch error {
            case .invalidDisplayName: "Enter a name for this person."
            case .profileNotFound: "That person is no longer in the library."
            case .signatureNotFound: "That enrollment sample is no longer stored."
            case .profileAlreadyExists: "A person with that identifier already exists."
            case .emptyEmbeddingVector: "The enrollment sample had no usable voice data."
            case .applicationSupportUnavailable: "The speaker library location is unavailable."
            case let .sqlite(message): "The speaker library could not be updated: \(message)"
            case let .io(message): "The speaker library could not be written: \(message)"
            }
        }
        return error.localizedDescription
    }
}
