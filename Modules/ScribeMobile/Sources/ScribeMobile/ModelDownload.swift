import CryptoKit
import Foundation
import ScribeInference

/// Downloads the pinned model set from its Hugging Face revisions, the same explicit,
/// user-started host operation as the desktop installer. Inference never fetches models.
/// Each file is verified against the manifest before an atomic rename publishes it, so a
/// retry reuses verified files and cancellation or failure never leaves a partial weight file.
extension ModelLibrary {
    /// Downloads `url` to a local temporary file, reporting bytes received so far.
    public typealias Fetch = @Sendable (URL, _ received: @escaping @Sendable (Int64) -> Void) async throws -> URL

    public struct DownloadProgress: Sendable, Equatable {
        public let completedBytes: Int64
        public let totalBytes: Int64
        public let file: String
        public init(completedBytes: Int64, totalBytes: Int64, file: String) {
            self.completedBytes = completedBytes; self.totalBytes = totalBytes; self.file = file
        }
    }

    public nonisolated var downloadBytes: Int64 { Self.totalBytes(manifest) }

    /// The on-device “Scribe” folder that Files shows under On My iPad / On My iPhone.
    /// Models live there, like other apps' user-visible data; recordings stay private.
    public static func defaultDirectory() throws -> URL {
        try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "Models", directoryHint: .isDirectory)
    }

    public func download(fetch: Fetch? = nil, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {
        let fm = FileManager.default
        let total = Self.totalBytes(manifest)
        let sources = try manifest.assets.map(Self.resolveBase)
        try MeetingStore.privateDirectory(directory)
        let pending = manifest.assets.flatMap { asset in
            asset.requiredFiles.filter { file in
                let size = (try? directory.appending(path: asset.relativePath + "/" + file.relativePath)
                    .resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
                return size != file.bytes
            }
        }
        try StorageCapacity.require(pending.reduce(0) { $0 + Int64($1.bytes ?? 0) } + StorageCapacity.recordingReserve, at: directory)
        var completed: Int64 = 0
        for (asset, base) in zip(manifest.assets, sources) {
            for file in asset.requiredFiles {
                try Task.checkCancellation()
                let bytes = Int64(file.bytes ?? 0)
                let relative = asset.relativePath + "/" + file.relativePath
                let target = directory.appending(path: relative)
                progress(.init(completedBytes: completed, totalBytes: total, file: relative))
                if !Self.verified(file, at: target) {
                    let remote = file.relativePath.split(separator: "/").reduce(base) { $0.appendingPathComponent(String($1)) }
                    let offset = completed
                    let report: @Sendable (Int64) -> Void = { received in
                        progress(.init(completedBytes: offset + min(received, bytes), totalBytes: total, file: relative))
                    }
                    let downloaded = try await (fetch ?? Self.sessionFetch)(remote, report)
                    defer { try? fm.removeItem(at: downloaded) }
                    try Task.checkCancellation()
                    guard Self.verified(file, at: downloaded) else {
                        throw MobileError.message("Verification failed for \(relative). Try the download again.")
                    }
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    // Stage beside the target so publication is a same-volume atomic rename.
                    let staged = target.deletingLastPathComponent().appending(path: ".scribe-download-\(UUID().uuidString)")
                    defer { try? fm.removeItem(at: staged) }
                    do { try fm.moveItem(at: downloaded, to: staged) } catch { try fm.copyItem(at: downloaded, to: staged) }
                    if fm.fileExists(atPath: target.path) {
                        _ = try fm.replaceItemAt(target, withItemAt: staged)
                    } else {
                        try fm.moveItem(at: staged, to: target)
                    }
                }
                completed += bytes
                progress(.init(completedBytes: completed, totalBytes: total, file: relative))
            }
        }
        try MeetingStore.privateDirectory(directory)
    }

    private static func totalBytes(_ manifest: ModelManifest) -> Int64 {
        manifest.assets.reduce(0) { $0 + $1.requiredFiles.reduce(0) { $0 + Int64($1.bytes ?? 0) } }
    }

    /// Only immutable Hugging Face revisions from the bundled manifest are ever requested.
    private static func resolveBase(_ asset: ModelManifest.Asset) throws -> URL {
        guard let repository = URL(string: asset.upstream.repository), repository.scheme == "https",
              repository.host == "huggingface.co", repository.pathComponents.count == 3,
              asset.upstream.revision.count == 40, asset.upstream.revision.allSatisfy(\.isHexDigit) else {
            throw MobileError.message("The bundled model manifest has an invalid download source.")
        }
        return repository.appendingPathComponent("resolve").appendingPathComponent(asset.upstream.revision)
    }

    /// Streams the file so the 445 MB encoder is never held in memory.
    private static func verified(_ file: ModelManifest.RequiredFile, at url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, values.fileSize == file.bytes, let expected = file.sha256,
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        var hash = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                if Task.isCancelled { return false }
                hash.update(data: chunk)
            }
        } catch { return false }
        return hash.finalize().map { String(format: "%02x", $0) }.joined() == expected.lowercased()
    }

    private static func sessionFetch(_ url: URL, received: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        let operation = DownloadOperation(received)
        // A session-level delegate is required: the task delegate of `download(from:delegate:)`
        // never receives write progress, which would freeze the bar during the 445 MB encoder.
        let session = URLSession(configuration: .default, delegate: operation, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    operation.start(continuation)
                    task.resume()
                }
            } onCancel: { task.cancel() }
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw MobileError.message("The model download was interrupted (\(error.localizedDescription)). Try again; verified files are kept.")
        }
    }
}

private final class DownloadOperation: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let received: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var reported: Int64 = 0
    private var continuation: CheckedContinuation<URL, Error>?
    private var downloaded: Result<URL, Error>?
    init(_ received: @escaping @Sendable (Int64) -> Void) { self.received = received }
    func start(_ continuation: CheckedContinuation<URL, Error>) { lock.withLock { self.continuation = continuation } }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        // Report about every megabyte so progress does not flood the main actor.
        let due = lock.withLock {
            guard totalBytesWritten - reported >= 1_048_576 else { return false }
            reported = totalBytesWritten
            return true
        }
        if due { received(totalBytesWritten) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The system deletes `location` when this returns, so keep the file first.
        let result: Result<URL, Error>
        if let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 {
            let kept = FileManager.default.temporaryDirectory.appending(path: "scribe-model-\(UUID().uuidString)")
            result = Result { try FileManager.default.moveItem(at: location, to: kept); return kept }
        } else {
            let name = downloadTask.originalRequest?.url?.lastPathComponent ?? "a model file"
            result = .failure(MobileError.message("Hugging Face could not provide \(name). Try again later."))
        }
        lock.withLock { downloaded = result }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, downloaded) = lock.withLock {
            defer { self.continuation = nil }
            return (self.continuation, self.downloaded)
        }
        if let error { continuation?.resume(throwing: error) }
        else if let downloaded { continuation?.resume(with: downloaded) }
        else { continuation?.resume(throwing: URLError(.cannotCreateFile)) }
    }
}
