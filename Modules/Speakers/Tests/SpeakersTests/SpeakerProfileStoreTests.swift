import Foundation
import Testing

@testable import Speakers

private struct Workspace: ~Copyable {
    let url: URL

    init(_ name: String) throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SpeakersTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

private let wespeakerV1 = SpeakerEmbeddingModelIdentity(modelID: "wespeaker", revision: "1")
private let wespeakerV2 = SpeakerEmbeddingModelIdentity(modelID: "wespeaker", revision: "2")

private func signatureDraft(
    vector: [Float] = [0.1, 0.2, 0.3, 0.4],
    model: SpeakerEmbeddingModelIdentity = wespeakerV1,
    clipURL: URL? = nil,
    sourceID: String = "transcript-1",
    ranges: [SpeakerTimeRange] = [SpeakerTimeRange(startMs: 1_000, endMs: 4_000)]
) -> SpeakerSignatureDraft {
    SpeakerSignatureDraft(
        embeddingVector: vector,
        embeddingModel: model,
        preprocessingVersion: "prep-1",
        normalizationVersion: "norm-1",
        transformVersion: "transform-1",
        usableSpeechDuration: 24,
        enrollmentSourceID: sourceID,
        selectedTimeRanges: ranges,
        retainedClipURL: clipURL
    )
}

@Test
func emptyStoreHasZeroRevisionAndNoProfiles() async throws {
    let workspace = try Workspace("empty")
    let store = try SpeakerProfileStore(directoryURL: workspace.url)

    #expect(try await store.revision() == SpeakerLibraryRevision(sequence: 0))
    #expect(try await store.profiles().isEmpty)
    #expect(try await store.people().isEmpty)
    #expect(try await store.matchingEligibleProfiles().isEmpty)
    #expect(try await store.currentEmbeddingModel() == nil)
}

@Test
func createProfileFromEmptyStorePersistsStableIdentity() async throws {
    let workspace = try Workspace("create")
    let store = try SpeakerProfileStore(directoryURL: workspace.url)
    let profileID = UUID()

    let created = try await store.createProfile(
        SpeakerProfileDraft(displayName: " Jake ", profileID: profileID)
    )

    #expect(created.profileID == profileID)
    #expect(created.displayName == "Jake")
    #expect(created.automaticMatchingEnabled)
    #expect(created.signatures.isEmpty)
    #expect(!created.isMatchingEligible)
    #expect(created.personRef == SpeakerPersonRef(profileID: profileID, displayName: "Jake"))
    #expect(try await store.revision() == SpeakerLibraryRevision(sequence: 1))

    let reopened = try SpeakerProfileStore(directoryURL: workspace.url)
    let loaded = try #require(await reopened.profile(id: profileID))
    #expect(loaded.displayName == "Jake")
    #expect(loaded.profileID == profileID)
    #expect(try await reopened.person(id: profileID)?.displayName == "Jake")
}

@Test
func everyWriteBumpsLibraryRevision() async throws {
    let workspace = try Workspace("revision")
    let store = try SpeakerProfileStore(directoryURL: workspace.url)
    #expect(try await store.revision().sequence == 0)

    let profile = try await store.createProfile(SpeakerProfileDraft(displayName: "Sarah"))
    #expect(try await store.revision().sequence == 1)

    try await store.renameProfile(profileID: profile.profileID, displayName: "Sarah K")
    #expect(try await store.revision().sequence == 2)

    try await store.addSignature(profileID: profile.profileID, draft: signatureDraft())
    #expect(try await store.revision().sequence == 3)

    try await store.setAutomaticMatchingEnabled(profileID: profile.profileID, enabled: false)
    #expect(try await store.revision().sequence == 4)

    let signatureID = try #require(await store.profile(id: profile.profileID)?.signatures.first?.signatureID)
    try await store.removeSignature(profileID: profile.profileID, signatureID: signatureID)
    #expect(try await store.revision().sequence == 5)

    try await store.setCurrentEmbeddingModel(wespeakerV1)
    #expect(try await store.revision().sequence == 6)

    try await store.deleteProfile(profileID: profile.profileID)
    #expect(try await store.revision().sequence == 7)
}

@Test
func deletionRemovesProfileSignaturesAndClipsAndPreventsFutureMatching() async throws {
    let workspace = try Workspace("delete")
    let store = try SpeakerProfileStore(directoryURL: workspace.url)
    let clipSource = workspace.url.appendingPathComponent("source.wav")
    try Data("clip".utf8).write(to: clipSource)

    let profile = try await store.createProfile(SpeakerProfileDraft(displayName: "Alex"))
    let enrolled = try await store.addSignature(
        profileID: profile.profileID,
        draft: signatureDraft(clipURL: clipSource)
    )
    let clipURL = try #require(enrolled.signatures.first?.retainedClipURL)
    #expect(FileManager.default.fileExists(atPath: clipURL.path))
    #expect(clipURL.path.contains("/clips/"))
    #expect(clipURL.path.hasPrefix(workspace.url.path))
    #expect(try await store.matchingEligibleProfiles().map(\.profileID) == [profile.profileID])

    try await store.deleteProfile(profileID: profile.profileID)

    #expect(try await store.profile(id: profile.profileID) == nil)
    #expect(try await store.person(id: profile.profileID) == nil)
    #expect(try await store.matchingEligibleProfiles().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: clipURL.path))
    #expect(try await store.revision().sequence == 3)
}

@Test
func disableMatchingLeavesProfileButExcludesItFromAutomaticMatching() async throws {
    let workspace = try Workspace("disable")
    let store = try SpeakerProfileStore(directoryURL: workspace.url)
    let profile = try await store.createProfile(SpeakerProfileDraft(displayName: "Riley"))
    try await store.addSignature(profileID: profile.profileID, draft: signatureDraft())
    #expect(try await store.profile(id: profile.profileID)?.isMatchingEligible == true)

    let disabled = try await store.setAutomaticMatchingEnabled(profileID: profile.profileID, enabled: false)
    #expect(!disabled.automaticMatchingEnabled)
    #expect(!disabled.isMatchingEligible)
    #expect(disabled.signatures.count == 1)
    #expect(try await store.person(id: profile.profileID)?.displayName == "Riley")
    #expect(try await store.matchingEligibleProfiles().isEmpty)
}

@Test
func embeddingModelVersionChangeMarksSignaturesIncompatible() async throws {
    let workspace = try Workspace("incompatible")
    let store = try SpeakerProfileStore(directoryURL: workspace.url)
    let profile = try await store.createProfile(SpeakerProfileDraft(displayName: "Morgan"))
    try await store.addSignature(profileID: profile.profileID, draft: signatureDraft(model: wespeakerV1))
    try await store.setCurrentEmbeddingModel(wespeakerV1)

    var loaded = try #require(await store.profile(id: profile.profileID))
    #expect(loaded.signatures.first?.compatibility == .compatible)
    #expect(loaded.isMatchingEligible)

    try await store.setCurrentEmbeddingModel(wespeakerV2)
    loaded = try #require(await store.profile(id: profile.profileID))
    #expect(loaded.signatures.first?.compatibility == .needsReenrollment)
    #expect(!loaded.isMatchingEligible)
    #expect(loaded.signatures.first?.embeddingVector == [0.1, 0.2, 0.3, 0.4])

    try await store.setCurrentEmbeddingModel(wespeakerV1)
    loaded = try #require(await store.profile(id: profile.profileID))
    #expect(loaded.signatures.first?.compatibility == .compatible)
    #expect(loaded.isMatchingEligible)
}

@Test
func newSignatureFromOldModelIsMarkedIncompatibleWhenCurrentModelChanged() async throws {
    let workspace = try Workspace("stale-enroll")
    let store = try SpeakerProfileStore(directoryURL: workspace.url)
    try await store.setCurrentEmbeddingModel(wespeakerV2)
    let profile = try await store.createProfile(SpeakerProfileDraft(displayName: "Casey"))
    let enrolled = try await store.addSignature(
        profileID: profile.profileID,
        draft: signatureDraft(model: wespeakerV1)
    )
    #expect(enrolled.signatures.first?.compatibility == .needsReenrollment)
    #expect(!enrolled.isMatchingEligible)
}

@Test
func exportIdentityOmitsVectorsAndClips() async throws {
    let workspace = try Workspace("export")
    let store = try SpeakerProfileStore(directoryURL: workspace.url)
    let clipSource = workspace.url.appendingPathComponent("source.wav")
    try Data("clip".utf8).write(to: clipSource)
    let profile = try await store.createProfile(SpeakerProfileDraft(displayName: "Jordan"))
    try await store.addSignature(profileID: profile.profileID, draft: signatureDraft(clipURL: clipSource))
    let loaded = try #require(await store.profile(id: profile.profileID))

    let data = try JSONEncoder().encode(loaded.personRef)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(object.keys) == ["profileID", "displayName"])
    #expect(object["displayName"] as? String == "Jordan")
    #expect(object["embeddingVector"] == nil)
    #expect(object["signatures"] == nil)
    #expect(object["retainedClipURL"] == nil)

    let support = try SpeakersModule.applicationSupportDirectory()
    #expect(support.path.contains("Application Support"))
    #expect(support.lastPathComponent == "Speakers")
    #expect(!support.path.contains("Meeting Transcripts"))
}
