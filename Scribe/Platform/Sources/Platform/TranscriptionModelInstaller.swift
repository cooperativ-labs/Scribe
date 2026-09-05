import Combine
import CryptoKit
import Foundation

/// Reads the same pinned release manifest as the offline worker. Downloads are
/// explicit host operations; the worker never fetches missing assets itself.
public struct TranscriptionModelManifest: Decodable, Sendable {
    public struct Asset: Decodable, Sendable {
        public struct Upstream: Decodable, Sendable {
            public let repository: String
            public let revision: String
        }
        public struct File: Decodable, Sendable {
            public let relativePath: String
            public let bytes: Int
            public let sha256: String?
        }
        public let relativePath: String
        public let upstream: Upstream
        public let requiredFiles: [File]
    }
    public let assets: [Asset]
    public var totalBytes: Int64 { assets.reduce(0) { $0 + $1.requiredFiles.reduce(0) { $0 + Int64($1.bytes) } } }

    public static func load(from url: URL?) throws -> Self {
        guard let url else { throw ModelInstallationError("The bundled model manifest is missing. Reinstall Scribe.") }
        let manifest = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard !manifest.assets.isEmpty else { throw ModelInstallationError("The model manifest is empty.") }
        for asset in manifest.assets {
            guard let repository = URL(string: asset.upstream.repository),
                  repository.scheme == "https", repository.host == "huggingface.co",
                  asset.upstream.revision.count == 40,
                  asset.upstream.revision.allSatisfy({ $0.isHexDigit }),
                  safePath(asset.relativePath), !asset.requiredFiles.isEmpty else {
                throw ModelInstallationError("The model manifest contains an invalid source or path.")
            }
            for file in asset.requiredFiles {
                guard safePath(file.relativePath), file.bytes > 0 else {
                    throw ModelInstallationError("The model manifest contains an invalid file.")
                }
            }
        }
        return manifest
    }

    private static func safePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") }
    }
}

struct ModelInstallationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Disk-backed downloads keep the 445 MB encoder out of the app's heap.
/// Each file is verified before atomic publication. Retrying reuses verified
/// files, while cancellation/failure can never publish a partial weight file.
public actor TranscriptionModelDownloader {
    public typealias Fetch = @Sendable (URL) async throws -> URL
    private let fetch: Fetch?

    public init(fetch: Fetch? = nil) { self.fetch = fetch }

    private func download(_ url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        let delegate = ModelDownloadProgress(progress: progress)
        let (temporaryURL, response) = try await URLSession.shared.download(from: url, delegate: delegate)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw ModelInstallationError("Hugging Face could not download \(url.lastPathComponent). Please try again.")
        }
        return temporaryURL
    }

    public func isInstalled(manifest: TranscriptionModelManifest, directory: URL) throws -> Bool {
        for asset in manifest.assets {
            for file in asset.requiredFiles {
                try Task.checkCancellation()
                if !valid(file, at: directory.appendingPathComponent(asset.relativePath).appendingPathComponent(file.relativePath)) {
                    return false
                }
            }
        }
        return true
    }

    public func install(
        manifest: TranscriptionModelManifest,
        directory: URL,
        progress: @escaping @Sendable (Int64, Int64, String) async -> Void
    ) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var completed: Int64 = 0
        for asset in manifest.assets {
            for file in asset.requiredFiles {
                try Task.checkCancellation()
                let target = directory.appendingPathComponent(asset.relativePath).appendingPathComponent(file.relativePath)
                await progress(completed, manifest.totalBytes, file.relativePath)
                if !valid(file, at: target) {
                    let remote = URL(string: asset.upstream.repository)!
                        .appendingPathComponent("resolve").appendingPathComponent(asset.upstream.revision)
                        .appendingPathComponent(file.relativePath)
                    let downloaded: URL
                    if let fetch {
                        downloaded = try await fetch(remote)
                    } else {
                        let base = completed
                        downloaded = try await download(remote) { received in
                            Task { await progress(base + min(received, Int64(file.bytes)), manifest.totalBytes, file.relativePath) }
                        }
                    }
                    defer { try? fm.removeItem(at: downloaded) }
                    try Task.checkCancellation()
                    guard valid(file, at: downloaded) else {
                        throw ModelInstallationError("Verification failed for \(file.relativePath). Retry the installation.")
                    }
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    // Stage on the destination volume before the atomic rename.
                    let staged = target.deletingLastPathComponent().appendingPathComponent(".scribe-download-\(UUID().uuidString)")
                    defer { try? fm.removeItem(at: staged) }
                    try fm.copyItem(at: downloaded, to: staged)
                    if fm.fileExists(atPath: target.path) {
                        _ = try fm.replaceItemAt(target, withItemAt: staged)
                    } else {
                        try fm.moveItem(at: staged, to: target)
                    }
                }
                completed += Int64(file.bytes)
                await progress(completed, manifest.totalBytes, file.relativePath)
            }
        }
        try Task.checkCancellation()
    }

    private func valid(_ file: TranscriptionModelManifest.Asset.File, at url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue == file.bytes else { return false }
        guard let expected = file.sha256 else { return true }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        do {
            var hash = SHA256()
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                try Task.checkCancellation()
                hash.update(data: chunk)
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined() == expected.lowercased()
        } catch { return false }
    }
}

@MainActor
public final class TranscriptionModelInstaller: ObservableObject {
    public enum State: Equatable {
        case checking, notInstalled, installing, installed, failed(String)
    }
    @Published public private(set) var state: State = .checking
    @Published public private(set) var completedBytes: Int64 = 0
    @Published public private(set) var totalBytes: Int64 = 0
    @Published public private(set) var currentFile = ""
    public var isBusy: Bool { state == .checking || state == .installing }
    private let manifestURL: URL?
    private let downloader: TranscriptionModelDownloader
    private var task: Task<Void, Never>?
    private var generation = UUID()

    public init(manifestURL: URL? = Bundle.main.url(forResource: "model_manifest", withExtension: "json"),
                downloader: TranscriptionModelDownloader = .init()) {
        self.manifestURL = manifestURL
        self.downloader = downloader
    }

    public func refresh(directory: URL) { start(directory: directory, install: false) }
    public func install(directory: URL) { guard !isBusy else { return }; start(directory: directory, install: true) }
    public func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        state = .notInstalled
    }

    private func start(directory: URL, install: Bool) {
        task?.cancel()
        let generation = UUID()
        self.generation = generation
        state = install ? .installing : .checking
        completedBytes = 0
        task = Task { [weak self, downloader, manifestURL] in
            let accessing = directory.startAccessingSecurityScopedResource()
            defer { if accessing { directory.stopAccessingSecurityScopedResource() } }
            do {
                let manifest = try TranscriptionModelManifest.load(from: manifestURL)
                self?.totalBytes = manifest.totalBytes
                if install {
                    try await downloader.install(manifest: manifest, directory: directory) { [weak self] completed, total, file in
                        await self?.updateProgress(generation: generation, completed: completed, total: total, file: file)
                    }
                }
                let installed = try await downloader.isInstalled(manifest: manifest, directory: directory)
                guard self?.generation == generation else { return }
                self?.state = installed ? .installed : .notInstalled
            } catch {
                guard self?.generation == generation else { return }
                self?.state = Task.isCancelled ? .notInstalled : .failed(error.localizedDescription)
            }
        }
    }

    private func updateProgress(generation: UUID, completed: Int64, total: Int64, file: String) {
        guard self.generation == generation else { return }
        completedBytes = max(completedBytes, completed)
        totalBytes = total
        currentFile = file
    }
}

private final class ModelDownloadProgress: NSObject, URLSessionDownloadDelegate, Sendable {
    let progress: @Sendable (Int64) -> Void
    init(progress: @escaping @Sendable (Int64) -> Void) { self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten)
    }
}
