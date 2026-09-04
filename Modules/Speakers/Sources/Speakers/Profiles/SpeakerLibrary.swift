import Foundation

/// Independent service contract for the speaker library.
///
/// Transcription and other modules depend on this protocol so they share the
/// same person IDs (`SpeakerPersonRef.profileID`) without importing SQLite
/// details or voice embeddings.
public protocol SpeakerLibrary: Sendable {
    func revision() async throws -> SpeakerLibraryRevision
    func snapshot() async throws -> SpeakerLibrarySnapshot
    func people() async throws -> [SpeakerPersonRef]
    func person(id: UUID) async throws -> SpeakerPersonRef?
    func profile(id: UUID) async throws -> SpeakerProfile?
    func profiles() async throws -> [SpeakerProfile]
    func matchingEligibleProfiles() async throws -> [SpeakerProfile]
}
