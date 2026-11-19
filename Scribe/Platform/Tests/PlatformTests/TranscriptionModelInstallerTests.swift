import CryptoKit
import Foundation
import Testing
@testable import Platform

struct TranscriptionModelInstallerTests {
    @Test func cleanupWaitsForVerifiedInstallationAndPreservesUnrelatedFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let manifest = try fixture.manifestWithObsoletePaths(["test-model/Old.mlmodelc"])
        let old = fixture.destination.appendingPathComponent("test-model/Old.mlmodelc/weight.bin")
        let unrelated = fixture.destination.appendingPathComponent("other-model/keep.bin")
        for file in [old, unrelated] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: file)
        }
        let failed = TranscriptionModelDownloader { _ in throw CancellationError() }
        await #expect(throws: CancellationError.self) {
            try await failed.install(manifest: manifest, directory: fixture.destination) { _, _, _ in }
        }
        #expect(FileManager.default.fileExists(atPath: old.path))
        let downloader = TranscriptionModelDownloader { _ in
            let temporary = fixture.root.appendingPathComponent(UUID().uuidString)
            try fixture.payload.write(to: temporary)
            return temporary
        }
        try await downloader.install(manifest: manifest.selecting(.transcription), directory: fixture.destination) { _, _, _ in }
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(try await downloader.isInstalled(manifest: manifest, directory: fixture.destination))
    }

    @Test func obsoletePathsCannotContainRequiredFilesOrEscapeDestination() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for path in ["test-model", "../outside", "test-model/Model.mlmodelc/weights/weight.bin"] {
            #expect(throws: (any Error).self) { try fixture.manifestWithObsoletePaths([path]) }
        }
    }

    @Test func cleanupDoesNotFollowSymbolicLinkParents() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let manifest = try fixture.manifestWithObsoletePaths(["linked/Old.mlmodelc"])
        let outside = fixture.root.appendingPathComponent("outside")
        let old = outside.appendingPathComponent("Old.mlmodelc")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.destination.appendingPathComponent("linked"), withDestinationURL: outside)
        let downloader = TranscriptionModelDownloader { _ in
            let temporary = fixture.root.appendingPathComponent(UUID().uuidString)
            try fixture.payload.write(to: temporary)
            return temporary
        }
        await #expect(throws: (any Error).self) {
            try await downloader.install(manifest: manifest, directory: fixture.destination) { _, _, _ in }
        }
        #expect(FileManager.default.fileExists(atPath: old.path))
    }

    @Test func installationUsesPinnedURLsAndReusesVerifiedFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let requests = Requests()
        let downloader = TranscriptionModelDownloader { url in
            await requests.append(url)
            let temporary = fixture.root.appendingPathComponent(UUID().uuidString)
            try fixture.payload.write(to: temporary)
            return temporary
        }
        try await downloader.install(manifest: fixture.manifest, directory: fixture.destination) { _, _, _ in }
        let installed = try await downloader.isInstalled(manifest: fixture.manifest, directory: fixture.destination)
        #expect(installed)
        try await downloader.install(manifest: fixture.manifest, directory: fixture.destination) { _, _, _ in }
        let urls = await requests.urls
        #expect(urls.count == 1)
        #expect(urls.first?.absoluteString == "https://huggingface.co/FluidInference/test/resolve/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/Model.mlmodelc/weights/weight.bin")
        #expect(try Data(contentsOf: fixture.target) == fixture.payload)
    }

    @Test func corruptDownloadDoesNotReplaceExistingFileAndCanRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = Data("previous".utf8)
        try old.write(to: fixture.target)
        let corrupt = TranscriptionModelDownloader { _ in
            let file = fixture.root.appendingPathComponent(UUID().uuidString)
            try Data(repeating: 0, count: fixture.payload.count).write(to: file)
            return file
        }
        await #expect(throws: (any Error).self) {
            try await corrupt.install(manifest: fixture.manifest, directory: fixture.destination) { _, _, _ in }
        }
        #expect(try Data(contentsOf: fixture.target) == old)
        let repaired = TranscriptionModelDownloader { _ in
            let file = fixture.root.appendingPathComponent(UUID().uuidString)
            try fixture.payload.write(to: file)
            return file
        }
        try await repaired.install(manifest: fixture.manifest, directory: fixture.destination) { _, _, _ in }
        #expect(try await repaired.isInstalled(manifest: fixture.manifest, directory: fixture.destination))
    }

    @Test func cancellationDoesNotPublishPartialFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let requests = Requests()
        let downloader = TranscriptionModelDownloader { url in
            await requests.append(url)
            try await Task.sleep(for: .seconds(30))
            throw CancellationError()
        }
        let task = Task { try await downloader.install(manifest: fixture.manifest, directory: fixture.destination) { _, _, _ in } }
        for _ in 0..<200 {
            if await !requests.urls.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: fixture.target.path))
    }

    @Test func missingManifestAndUnsafePathsAreRejected() throws {
        #expect(throws: (any Error).self) { try TranscriptionModelManifest.load(from: nil) }
        let fixture = try Fixture()
        defer { fixture.remove() }
        let bad = fixture.root.appendingPathComponent("bad.json")
        let text = try String(contentsOf: fixture.manifestURL, encoding: .utf8)
            .replacingOccurrences(of: "test-model", with: "..")
        try text.write(to: bad, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try TranscriptionModelManifest.load(from: bad) }
    }

    @Test @MainActor func folderPreferenceSurvivesRelaunch() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let suite = "ModelFolderTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ScribeSettings(defaults: defaults, defaultRecordingsFolderURL: fixture.root, modelManifestURL: fixture.manifestURL)
        #expect(settings.modelsFolderURL.path.hasSuffix("Library/Application Support/Scribe/Models"))
        settings.modelInstaller.cancel()
        settings.vocabularyInstaller.cancel()
        try settings.setModelsFolder(fixture.destination)
        let relaunched = ScribeSettings(defaults: defaults, defaultRecordingsFolderURL: fixture.root, modelManifestURL: fixture.manifestURL)
        #expect(relaunched.modelsFolderURL == fixture.destination.standardizedFileURL)
        relaunched.modelInstaller.cancel()
        relaunched.vocabularyInstaller.cancel()
        settings.modelInstaller.cancel()
        settings.vocabularyInstaller.cancel()
    }

    @Test func optionalVocabularyGroupDoesNotGateTranscriptionReadiness() async throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try TranscriptionModelManifest.load(from: repo.appendingPathComponent("Workers/TranscriptionWorker/model_manifest.json"))
        let base = manifest.selecting(.transcription)
        let vocabulary = manifest.selecting(.vocabulary)
        #expect(base.assets.allSatisfy { $0.optional != true })
        #expect(vocabulary.assets.count == 1)
        #expect(vocabulary.assets.first?.relativePath == "parakeet-ctc-110m-coreml")
        #expect(vocabulary.totalBytes > 100_000_000)
        #expect(base.totalBytes + vocabulary.totalBytes == manifest.totalBytes)
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(try await !TranscriptionModelDownloader().isInstalled(manifest: vocabulary, directory: fixture.root))
    }

    /// Opt in to downloading the shipping model set; regular tests stay offline.
    @Test func freshHuggingFaceInstallation() async throws {
        guard let path = ProcessInfo.processInfo.environment["SCRIBE_MODEL_INSTALL_SMOKE_DIRECTORY"] else { return }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try TranscriptionModelManifest.load(from: repo.appendingPathComponent("Workers/TranscriptionWorker/model_manifest.json"))
        let downloader = TranscriptionModelDownloader()
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try await downloader.install(manifest: manifest, directory: directory) { _, _, _ in }
        #expect(try await downloader.isInstalled(manifest: manifest, directory: directory))
    }

    /// Opt in with a real previous installation and verified corrected assets.
    @Test func correctedEncoderUpgradeResumesAndRemovesOldEncoder() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rollbackPath = environment["SCRIBE_MODEL_UPGRADE_SMOKE_ROLLBACK"],
              let stagedPath = environment["SCRIBE_MODEL_UPGRADE_SMOKE_STAGED"] else { return }
        let rollback = URL(fileURLWithPath: rollbackPath, isDirectory: true)
        let staged = URL(fileURLWithPath: stagedPath, isDirectory: true)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let previous = try TranscriptionModelManifest.load(from: rollback.appendingPathComponent(
            "Scribe.app/Contents/Resources/model_manifest.json"
        ))
        let current = try TranscriptionModelManifest.load(from: repo.appendingPathComponent(
            "Workers/TranscriptionWorker/model_manifest.json"
        ))
        let encoder = try #require(current.assets.first {
            $0.requiredFiles.contains { $0.relativePath.hasPrefix("Encoder_v2.mlmodelc/") }
        })
        let weight = try #require(encoder.requiredFiles.first { $0.relativePath.hasSuffix("/weight.bin") })
        let metadata = try #require(encoder.requiredFiles.first { $0.relativePath == "Encoder_v2.mlmodelc/coremldata.bin" })
        let remote = try #require(URL(string: encoder.upstream.repository))
            .appendingPathComponent("resolve").appendingPathComponent(encoder.upstream.revision)
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.copyItem(at: rollback.appendingPathComponent("Models"), to: fixture.destination)
        let encoderDirectory = fixture.destination.appendingPathComponent(encoder.relativePath)
        let initialRequests = Requests()
        let interrupted = TranscriptionModelDownloader { url in
            await initialRequests.append(url)
            if url == remote.appendingPathComponent(weight.relativePath) { throw CancellationError() }
            let path = String(url.path.dropFirst(remote.path.count + 1))
            let temporary = fixture.root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: staged.appendingPathComponent(encoder.relativePath)
                .appendingPathComponent(path), to: temporary)
            return temporary
        }
        await #expect(throws: CancellationError.self) {
            try await interrupted.install(manifest: current, directory: fixture.destination) { _, _, _ in }
        }
        #expect(await initialRequests.urls == encoder.requiredFiles.map { remote.appendingPathComponent($0.relativePath) })
        #expect(!FileManager.default.fileExists(atPath: encoderDirectory.appendingPathComponent(weight.relativePath).path))
        #expect(try await interrupted.isInstalled(manifest: previous, directory: fixture.destination))
        #expect(try await !interrupted.isInstalled(manifest: current, directory: fixture.destination))

        try Data(repeating: 0, count: metadata.bytes).write(to: encoderDirectory.appendingPathComponent(metadata.relativePath))
        let retryRequests = Requests()
        let retry = TranscriptionModelDownloader { url in
            await retryRequests.append(url)
            let path = String(url.path.dropFirst(remote.path.count + 1))
            let temporary = fixture.root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: staged.appendingPathComponent(encoder.relativePath)
                .appendingPathComponent(path), to: temporary)
            return temporary
        }
        try await retry.install(manifest: current, directory: fixture.destination) { _, _, _ in }
        #expect(await retryRequests.urls == [metadata, weight].map { remote.appendingPathComponent($0.relativePath) })
        #expect(try await retry.isInstalled(manifest: current, directory: fixture.destination))
        #expect(try await !retry.isInstalled(manifest: previous, directory: fixture.destination))
    }
}

private actor Requests {
    var urls: [URL] = []
    func append(_ url: URL) { urls.append(url) }
}

private struct Fixture: Sendable {
    let root: URL
    let payload = Data("verified model data".utf8)
    let manifestURL: URL
    let manifest: TranscriptionModelManifest
    var destination: URL { root.appendingPathComponent("Custom Models") }
    var target: URL { destination.appendingPathComponent("test-model/Model.mlmodelc/weights/weight.bin") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ModelInstaller-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        manifestURL = root.appendingPathComponent("manifest.json")
        let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let data = try JSONSerialization.data(withJSONObject: ["assets": [[
            "relativePath": "test-model",
            "upstream": ["repository": "https://huggingface.co/FluidInference/test", "revision": String(repeating: "a", count: 40)],
            "requiredFiles": [["relativePath": "Model.mlmodelc/weights/weight.bin", "bytes": payload.count, "sha256": hash]]
        ]]])
        try data.write(to: manifestURL)
        manifest = try TranscriptionModelManifest.load(from: manifestURL)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func manifestWithObsoletePaths(_ paths: [String]) throws -> TranscriptionModelManifest {
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        json["obsoleteTranscriptionPaths"] = paths
        let url = root.appendingPathComponent("obsolete-manifest.json")
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        return try TranscriptionModelManifest.load(from: url)
    }
}
