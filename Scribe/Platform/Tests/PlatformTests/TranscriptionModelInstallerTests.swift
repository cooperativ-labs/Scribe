import CryptoKit
import Foundation
import Testing
@testable import Platform

struct TranscriptionModelInstallerTests {
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
        try settings.setModelsFolder(fixture.destination)
        let relaunched = ScribeSettings(defaults: defaults, defaultRecordingsFolderURL: fixture.root, modelManifestURL: fixture.manifestURL)
        #expect(relaunched.modelsFolderURL == fixture.destination.standardizedFileURL)
        relaunched.modelInstaller.cancel()
        settings.modelInstaller.cancel()
    }

    /// Opt in to downloading the shipping model set; regular tests stay offline.
    @Test func freshHuggingFaceInstallation() async throws {
        guard let path = ProcessInfo.processInfo.environment["SCRIBE_MODEL_INSTALL_SMOKE_DIRECTORY"] else { return }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try TranscriptionModelManifest.load(from: repo.appendingPathComponent("Workers/TranscriptionWorker/model_manifest.json"))
        let downloader = TranscriptionModelDownloader()
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try await downloader.install(manifest: manifest, directory: directory) { completed, total, file in
            print("Model install: \(completed)/\(total) \(file)")
        }
        #expect(try await downloader.isInstalled(manifest: manifest, directory: directory))
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
}
