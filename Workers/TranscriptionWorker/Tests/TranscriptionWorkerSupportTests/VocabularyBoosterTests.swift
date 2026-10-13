import Foundation
import Testing
@testable import ScribeInference
@testable import TranscriptionWorkerSupport

struct VocabularyBoosterTests {
    private struct LoadFailure: Error {}

    private func identity(_ path: String, digest: String = "m") -> OptionalAssetIdentity {
        .init(modelsDirectory: path, manifestDigest: digest, stamps: [])
    }

    @Test func retainedValueIsReusedUntilItsIdentityChanges() async throws {
        let cache = RetainedAssetCache<Int>()
        let (first, firstSource) = try await cache.value(for: identity("/a")) { 1 }
        let (again, againSource) = try await cache.value(for: identity("/a")) { 2 }
        #expect(first == 1 && again == 1)
        #expect(firstSource == .loaded && againSource == .retained)
        let (changed, changedSource) = try await cache.value(for: identity("/a", digest: "new manifest")) { 3 }
        #expect(changed == 3 && changedSource == .reloadedAfterChange)
        let (moved, _) = try await cache.value(for: identity("/b", digest: "new manifest")) { 4 }
        #expect(moved == 4)
        #expect(await cache.loadCount == 3)
    }

    @Test func failureIsRememberedOnlyForTheIdentityThatProducedIt() async throws {
        let cache = RetainedAssetCache<Int>()
        for _ in 0..<2 {
            await #expect(throws: LoadFailure.self) { _ = try await cache.value(for: identity("/broken")) { throw LoadFailure() } }
        }
        #expect(await cache.loadCount == 1, "An unchanged broken install is not re-hashed on every request")
        let (value, source) = try await cache.value(for: identity("/broken", digest: "repaired")) { 7 }
        #expect(value == 7 && source == .recovered)
    }

    @Test func releaseDropsValueAndFailure() async throws {
        let cache = RetainedAssetCache<Int>()
        _ = try await cache.value(for: identity("/a")) { 1 }
        await cache.release()
        #expect(await !cache.isResident)
        let (_, source) = try await cache.value(for: identity("/a")) { 2 }
        #expect(source == .loaded)
        #expect(await cache.loadCount == 2)
    }

    @Test func identityTracksManifestFolderAndReplacedFiles() throws {
        let fixture = try AssetFixture()
        defer { fixture.remove() }
        let manifest = try fixture.manifest()
        let data = try fixture.manifestData()
        let missing = OptionalAssetIdentity.current(manifestData: data, manifest: manifest, modelsDirectory: fixture.models, assetID: VocabularyBooster.assetID)
        try fixture.installTokenizer()
        let installed = OptionalAssetIdentity.current(manifestData: data, manifest: manifest, modelsDirectory: fixture.models, assetID: VocabularyBooster.assetID)
        #expect(missing != installed, "Installing an asset invalidates the cached failure")
        #expect(installed == OptionalAssetIdentity.current(manifestData: data, manifest: manifest, modelsDirectory: fixture.models, assetID: VocabularyBooster.assetID))
        try fixture.installTokenizer(contents: "abd")
        let replaced = OptionalAssetIdentity.current(manifestData: data, manifest: manifest, modelsDirectory: fixture.models, assetID: VocabularyBooster.assetID)
        #expect(installed != replaced, "A same-size replacement is still detected")
        var edited = data
        edited.append(contentsOf: Array(" ".utf8))
        #expect(replaced != OptionalAssetIdentity.current(manifestData: edited, manifest: manifest, modelsDirectory: fixture.models, assetID: VocabularyBooster.assetID))
        #expect(replaced != OptionalAssetIdentity.current(manifestData: data, manifest: manifest, modelsDirectory: fixture.root, assetID: VocabularyBooster.assetID))
    }

    @Test func emptyVocabularyNeverReadsManifestOrLoadsCTC() async {
        let booster = VocabularyBooster()
        for snapshot in [WorkerVocabularySnapshot(), .init(terms: [.init(text: "AI")]), .init(terms: [.init(text: "...")])] {
            let report = await booster.warm(snapshot: snapshot, manifestURL: URL(fileURLWithPath: "/missing/manifest.json"),
                                            modelsDirectory: URL(fileURLWithPath: "/missing"))
            #expect(report.readiness == .notNeeded)
        }
        #expect(await booster.modelLoadCount == 0)
    }

    @Test func missingAssetsAreUnavailableAndRetriedAfterRepair() async throws {
        let fixture = try AssetFixture()
        defer { fixture.remove() }
        let booster = VocabularyBooster()
        let snapshot = WorkerVocabularySnapshot(terms: [.init(text: "Livmarli")])
        for _ in 0..<2 {
            let report = await booster.warm(snapshot: snapshot, manifestURL: fixture.manifestURL, modelsDirectory: fixture.models)
            #expect(report.readiness == .unavailable)
        }
        #expect(await booster.modelLoadCount == 1)
        // The repaired file validates, so the booster tries again. This fixture
        // has no real Core ML model, so loading still fails, but not from cache.
        try fixture.installTokenizer()
        let report = await booster.warm(snapshot: snapshot, manifestURL: fixture.manifestURL, modelsDirectory: fixture.models)
        #expect(report.readiness == .unavailable)
        #expect(await booster.modelLoadCount == 2)
        let output = await OfflineVocabularyRescorer.rescore(booster: booster, fileURL: URL(fileURLWithPath: "/missing.wav"),
            text: "normal speech", tokens: [], snapshot: snapshot, manifestURL: fixture.manifestURL, modelsDirectory: fixture.models)
        #expect(output.text == "normal speech")
        #expect(output.warning == "vocabulary_assets_unavailable")
        #expect(output.replacements.isEmpty)
    }

    @Test func unloadReleasesTheBooster() async throws {
        let session = WorkerDictationSession(configuration: .init(
            manifestURL: URL(fileURLWithPath: "/missing/manifest.json"),
            modelsDirectory: URL(fileURLWithPath: "/missing/models")
        ))
        var responses: [WorkerEnvelope] = []
        await session.handle(operation: "unload", requestID: "unload", payload: [:]) { responses.append($0) }
        #expect(await !session.booster.isResident)
        #expect(responses.first?.kind == .stageResult)
    }

    /// Small manifest whose only CTC file is a three-byte tokenizer.
    private struct AssetFixture {
        let root: URL
        var models: URL { root.appendingPathComponent("models") }
        var manifestURL: URL { root.appendingPathComponent("manifest.json") }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
            let shipping = try Data(contentsOf: repository.appendingPathComponent("Workers/TranscriptionWorker/model_manifest.json"))
            var object = try #require(JSONSerialization.jsonObject(with: shipping) as? [String: Any])
            var asset = try #require((object["assets"] as? [[String: Any]])?.first { $0["id"] as? String == VocabularyBooster.assetID })
            // SHA-256 of "abc".
            asset["requiredFiles"] = [["relativePath": "tokenizer.json", "bytes": 3,
                                       "sha256": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"]]
            object["assets"] = [asset]
            try JSONSerialization.data(withJSONObject: object).write(to: manifestURL)
        }

        func manifestData() throws -> Data { try Data(contentsOf: manifestURL) }
        func manifest() throws -> ModelManifest { try ModelManifest.load(from: manifestURL) }

        func installTokenizer(contents: String = "abc") throws {
            let directory = models.appendingPathComponent("parakeet-ctc-110m-coreml")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: directory.appendingPathComponent("tokenizer.json"), options: .atomic)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

/// Exercises the staged CTC model. Opt in with SCRIBE_REAL_MODEL_TESTS=1; a
/// cold Core ML preparation of this model can take tens of seconds.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SCRIBE_REAL_MODEL_TESTS"] == "1"))
struct VocabularyBoosterModelTests {
    private let manifestURL = repository.appendingPathComponent("Workers/TranscriptionWorker/model_manifest.json")
    private let models = repository.appendingPathComponent("Workers/TranscriptionWorker/models")

    @Test func warmedModelIsRetainedAcrossSnapshotAndAliasEdits() async throws {
        let booster = VocabularyBooster()
        let original = WorkerVocabularySnapshot(revision: "r1", terms: [.init(text: "Livmarli", aliases: ["Liv Marley"])])
        let warmed = await booster.warm(snapshot: original, manifestURL: manifestURL, modelsDirectory: models)
        #expect(warmed.readiness == .ready)
        #expect(warmed.warmInferenceSeconds != nil, "Readiness includes one representative prediction")

        let (_, same) = await booster.prepare(snapshot: original, manifestURL: manifestURL, modelsDirectory: models, warmInference: false)
        #expect(same.source == .retained && same.contextReused)
        #expect(same.modelLoadSeconds < 1, "No model load or full hash on the warmed path")

        // A new alias and term rebuild only the context; the model stays.
        let edited = WorkerVocabularySnapshot(revision: "r1", terms: [.init(text: "Livmarli", aliases: ["Liv Marley", "Liv mar lee"]), .init(text: "Cooperativ")])
        let (prepared, changed) = await booster.prepare(snapshot: edited, manifestURL: manifestURL, modelsDirectory: models, warmInference: false)
        #expect(changed.source == .retained && !changed.contextReused)
        #expect(prepared?.terms == edited.usableTerms)
        #expect(await booster.modelLoadCount == 1)

        await booster.release()
        let (_, reloaded) = await booster.prepare(snapshot: edited, manifestURL: manifestURL, modelsDirectory: models, warmInference: false)
        #expect(reloaded.source == .loaded)
        #expect(await booster.modelLoadCount == 2)
    }

    @Test func corruptCopyIsUnavailableAndRecoversAfterRepair() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let copy = root.appendingPathComponent("parakeet-ctc-110m-coreml")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // APFS clones; no 100 MB duplicate is written.
        try FileManager.default.copyItem(at: models.appendingPathComponent("parakeet-ctc-110m-coreml"), to: copy)
        let tokenizer = copy.appendingPathComponent("tokenizer.json")
        let good = try Data(contentsOf: tokenizer)
        try Data("{}".utf8).write(to: tokenizer, options: .atomic)

        let booster = VocabularyBooster()
        let snapshot = WorkerVocabularySnapshot(terms: [.init(text: "Livmarli")])
        #expect(await booster.warm(snapshot: snapshot, manifestURL: manifestURL, modelsDirectory: root).readiness == .unavailable)
        try good.write(to: tokenizer, options: .atomic)
        let repaired = await booster.warm(snapshot: snapshot, manifestURL: manifestURL, modelsDirectory: root)
        #expect(repaired.readiness == .ready)
        #expect(repaired.source == .recovered)
    }

    @Test func workerUnloadReleasesARetainedBooster() async throws {
        let session = WorkerDictationSession(configuration: .init(manifestURL: manifestURL, modelsDirectory: models))
        let report = await session.booster.warm(snapshot: .init(terms: [.init(text: "Livmarli")]), manifestURL: manifestURL, modelsDirectory: models)
        #expect(report.readiness == .ready)
        #expect(await session.booster.isResident)
        await session.handle(operation: "unload", requestID: "unload", payload: [:]) { _ in }
        #expect(await !session.booster.isResident)
    }
}

private let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
