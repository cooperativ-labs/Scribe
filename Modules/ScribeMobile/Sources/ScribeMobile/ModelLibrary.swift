import Foundation
import ScribeInference

/// Installs only the files enumerated by the app's trusted, pinned manifest.
/// No runtime network access and no user-provided manifest can change the trust root.
public actor ModelLibrary {
    public let directory: URL
    private let manifest: ModelManifest
    public init(directory: URL, manifestURL: URL) throws {
        self.directory = directory
        self.manifest = try ModelManifest.load(from: manifestURL)
        guard manifest.schemaVersion == 1, !manifest.assets.isEmpty,
              !manifest.telemetry.enabled, !manifest.telemetry.runtimeDownloadsAllowed else {
            throw MobileError.message("The bundled model manifest is invalid.")
        }
        for asset in manifest.assets {
            guard Self.safeRelativePath(asset.relativePath), !asset.requiredFiles.isEmpty else {
                throw MobileError.message("Invalid model asset path.")
            }
            for file in asset.requiredFiles {
                guard Self.safeRelativePath(file.relativePath), file.sha256?.count == 64, (file.bytes ?? 0) > 0 else {
                    throw MobileError.message("Model files must have pinned hashes and sizes.")
                }
            }
        }
    }
    public func validatedManifest() throws -> ModelManifest {
        let report = manifest.validate(modelsDirectory: directory)
        guard report.isValid else { throw MobileError.message("Install the verified offline model folder in Settings before transcribing.") }
        return manifest
    }
    public func isInstalled() -> Bool { manifest.validate(modelsDirectory: directory).isValid }
    public func install(from source: URL) throws {
        let staging = directory.deletingLastPathComponent().appending(path: "models-staging-\(UUID().uuidString)")
        try MeetingStore.privateDirectory(staging)
        try StorageCapacity.require(Int64(manifest.totalDeclaredOnDiskBytes) + StorageCapacity.recordingReserve, at: staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        for asset in manifest.assets {
            for file in asset.requiredFiles {
                try Task.checkCancellation()
                let relative = asset.relativePath + "/" + file.relativePath
                let input = source.appending(path: relative)
                let values = try input.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == file.bytes,
                      input.resolvingSymlinksInPath().path.hasPrefix(source.resolvingSymlinksInPath().path + "/") else {
                    throw MobileError.message("Model file has an unexpected type or size: \(relative)")
                }
                let output = staging.appending(path: relative)
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: input, to: output)
            }
        }
        guard manifest.validate(modelsDirectory: staging).isValid else {
            throw MobileError.message("Model verification failed. The installed models were preserved.")
        }
        // Keep the existing install until the verified replacement is durable.
        if FileManager.default.fileExists(atPath: directory.path) {
            _ = try FileManager.default.replaceItemAt(directory, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: directory)
        }
        try MeetingStore.privateDirectory(directory)
    }
    private static func safeRelativePath(_ path: String) -> Bool {
        !path.hasPrefix("/") && !path.contains("\\") && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }
}
