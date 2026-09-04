import Foundation
import Testing

@testable import Speakers

private let wespeaker = SpeakerEmbeddingModelIdentity(modelID: "wespeaker", revision: "1")
private let wespeakerV2 = SpeakerEmbeddingModelIdentity(modelID: "wespeaker", revision: "2")
private let vector: [Float] = [0.6, 0.4, 0.5, 0.3]

private func makeStore(_ name: String) throws -> (SpeakerProfileStore, URL) {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("SpeakerLibraryViewModelTests-\(name)-\(UUID().uuidString)", isDirectory: true)
    return (try SpeakerProfileStore(directoryURL: url), url)
}

private func signatureDraft(vector: [Float] = vector, model: SpeakerEmbeddingModelIdentity = wespeaker) -> SpeakerSignatureDraft {
    SpeakerSignatureDraft(
        embeddingVector: vector,
        embeddingModel: model,
        preprocessingVersion: "prep-1",
        normalizationVersion: "norm-1",
        transformVersion: "transform-1",
        usableSpeechDuration: 24,
        enrollmentSourceID: "transcript-1",
        selectedTimeRanges: [SpeakerTimeRange(startMs: 1_000, endMs: 25_000)]
    )
}

/// A recording-local cluster whose excerpt is an exact copy of the enrolled
/// vector, so any refusal to name it comes from policy and not from a weak score.
private func perfectLocalSpeaker() -> RecordingLocalSpeaker {
    RecordingLocalSpeaker(
        speakerID: "speaker_1",
        excerpts: [
            SpeakerEmbeddingExcerpt(
                excerptID: "excerpt-1",
                vector: vector,
                format: SpeakerEmbeddingFormat(
                    model: wespeaker,
                    preprocessingVersion: "prep-1",
                    normalizationVersion: "norm-1",
                    transformVersion: "transform-1"
                )
            )
        ]
    )
}

@MainActor
@Test func nameOnlyProfilesAreNeverMatchedAutomatically() async throws {
    let (store, directory) = try makeStore("name-only")
    defer { try? FileManager.default.removeItem(at: directory) }
    let viewModel = SpeakerLibraryViewModel(store: store)

    let person = try #require(await viewModel.addPerson(named: "Sarah"))

    let row = try #require(viewModel.rows.first { $0.id == person.profileID })
    #expect(row.isNameOnly)
    #expect(row.automaticMatchingEnabled, "the toggle can be on; the missing signature is what blocks matching")
    #expect(row.matchingStatus == "Name only — will not match automatically")
    #expect(!row.needsReenrollment)

    let snapshot = try await store.snapshot()
    #expect(snapshot.matchingEligibleProfiles.isEmpty)
    let assignment = SpeakerIdentityMatcher().match(perfectLocalSpeaker(), against: snapshot)
    #expect(assignment.outcome == .unmatched)
    #expect(assignment.person == nil)
    #expect(assignment.evidence.candidates.isEmpty)
}

@MainActor
@Test func turningOffAutomaticMatchingStopsFutureMatchesWithoutDeletingSignatures() async throws {
    let (store, directory) = try makeStore("toggle")
    defer { try? FileManager.default.removeItem(at: directory) }
    let viewModel = SpeakerLibraryViewModel(store: store)
    let person = try #require(await viewModel.addPerson(named: "Sarah"))
    _ = try await store.addSignature(profileID: person.profileID, draft: signatureDraft())
    await viewModel.load()

    #expect(viewModel.rows.first?.matchingStatus == "Matches automatically")
    #expect(try await SpeakerIdentityMatcher().match(perfectLocalSpeaker(), against: store.snapshot()).person == person)

    await viewModel.setAutomaticMatching(false, for: person.profileID)

    let row = try #require(viewModel.rows.first)
    #expect(!row.automaticMatchingEnabled)
    #expect(!row.isNameOnly, "the signature is retained")
    #expect(row.matchingStatus == "Automatic matching off")
    #expect(try await SpeakerIdentityMatcher().match(perfectLocalSpeaker(), against: store.snapshot()).outcome == .unmatched)
}

@MainActor
@Test func removingTheLastSignatureLeavesANameOnlyProfile() async throws {
    let (store, directory) = try makeStore("remove-signature")
    defer { try? FileManager.default.removeItem(at: directory) }
    let viewModel = SpeakerLibraryViewModel(store: store)
    let person = try #require(await viewModel.addPerson(named: "Sarah"))
    let profile = try await store.addSignature(profileID: person.profileID, draft: signatureDraft())
    await viewModel.load()
    let signatureID = try #require(profile.signatures.first?.signatureID)

    #expect(viewModel.rows.first?.signatures.count == 1)
    #expect(viewModel.rows.first?.usableSpeechDuration == 24)

    await viewModel.removeSignature(signatureID, from: person.profileID)

    let row = try #require(viewModel.rows.first)
    #expect(row.signatures.isEmpty)
    #expect(row.isNameOnly)
    #expect(try await SpeakerIdentityMatcher().match(perfectLocalSpeaker(), against: store.snapshot()).outcome == .unmatched)
}

@MainActor
@Test func signaturesFromAnotherEmbeddingModelNeedReenrollmentBeforeMatching() async throws {
    let (store, directory) = try makeStore("model-change")
    defer { try? FileManager.default.removeItem(at: directory) }
    let viewModel = SpeakerLibraryViewModel(store: store)
    let person = try #require(await viewModel.addPerson(named: "Sarah"))
    _ = try await store.addSignature(profileID: person.profileID, draft: signatureDraft())

    _ = try await store.setCurrentEmbeddingModel(wespeakerV2)
    await viewModel.load()

    let row = try #require(viewModel.rows.first)
    #expect(row.needsReenrollment)
    #expect(row.isNameOnly)
    #expect(row.matchingStatus == "Signatures need reenrollment — will not match automatically")
    #expect(try await SpeakerIdentityMatcher().match(perfectLocalSpeaker(), against: store.snapshot()).outcome == .unmatched)
}

@MainActor
@Test func renamingAndDeletingUpdateTheLibraryForFutureMatching() async throws {
    let (store, directory) = try makeStore("rename-delete")
    defer { try? FileManager.default.removeItem(at: directory) }
    let viewModel = SpeakerLibraryViewModel(store: store)
    let person = try #require(await viewModel.addPerson(named: "Sarah"))
    _ = try await store.addSignature(profileID: person.profileID, draft: signatureDraft())
    await viewModel.load()

    await viewModel.rename(profileID: person.profileID, to: "Sarah Chen")
    #expect(viewModel.rows.first?.displayName == "Sarah Chen")
    #expect(try await store.person(id: person.profileID)?.displayName == "Sarah Chen")

    await viewModel.deleteProfile(person.profileID)

    #expect(viewModel.rows.isEmpty)
    #expect(viewModel.selectedProfileID == nil)
    #expect(try await store.profile(id: person.profileID) == nil)
    #expect(try await SpeakerIdentityMatcher().match(perfectLocalSpeaker(), against: store.snapshot()).outcome == .unmatched)
}

@MainActor
@Test func storeFailuresSurfaceAsReadableMessages() async throws {
    let (store, directory) = try makeStore("errors")
    defer { try? FileManager.default.removeItem(at: directory) }
    let viewModel = SpeakerLibraryViewModel(store: store)

    #expect(await viewModel.addPerson(named: "   ") == nil)
    #expect(viewModel.errorMessage == "Enter a name for this person.")

    let person = try #require(await viewModel.addPerson(named: "Sarah"))
    #expect(viewModel.errorMessage == nil)

    await viewModel.removeSignature(UUID(), from: person.profileID)
    #expect(viewModel.errorMessage == "That enrollment sample is no longer stored.")
}
