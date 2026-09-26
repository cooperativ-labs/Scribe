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
        if let problem = layoutProblem(at: source) { throw MobileError.message(problem) }
        let staging = directory.deletingLastPathComponent().appending(path: "models-staging-\(UUID().uuidString)")
        try MeetingStore.privateDirectory(staging)
        try StorageCapacity.require(Int64(manifest.totalDeclaredOnDiskBytes) + StorageCapacity.recordingReserve, at: staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        // Files-provider folders (iCloud Drive, third-party providers) can list files that are
        // not yet on this device. Request the whole tree once; each file is then read through
        // a coordinated read, which waits for its download before the copy starts.
        try? FileManager.default.startDownloadingUbiquitousItem(at: source)
        for asset in manifest.assets {
            for file in asset.requiredFiles {
                try Task.checkCancellation()
                let relative = asset.relativePath + "/" + file.relativePath
                let input = source.appending(path: relative)
                let output = staging.appending(path: relative)
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Self.coordinatedRead(of: input) { input in
                    guard FileManager.default.fileExists(atPath: input.path) else {
                        throw MobileError.message(Self.missingFileMessage(relative))
                    }
                    let values = try input.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == file.bytes,
                          input.resolvingSymlinksInPath().path.hasPrefix(source.resolvingSymlinksInPath().path + "/") else {
                        throw MobileError.message("Model file has an unexpected type or size: \(relative)")
                    }
                    try FileManager.default.copyItem(at: input, to: output)
                }
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
    /// Explains a wrong folder choice before any file is touched, instead of surfacing the
    /// first missing file as a bare "no such file" error.
    private func layoutProblem(at source: URL) -> String? {
        let expected = Array(Set(manifest.assets.map(\.relativePath))).sorted()
        let list = expected.map { "“\($0)”" }.joined(separator: " and ")
        func containsAll(_ folder: URL) -> Bool {
            expected.allSatisfy { Self.isDirectory(folder.appending(path: $0)) }
        }
        if containsAll(source) { return nil }
        if expected.contains(source.lastPathComponent) {
            return "You chose the “\(source.lastPathComponent)” folder itself. Choose the folder that contains \(list)."
        }
        let children = (try? FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        if let nested = children.first(where: { Self.isDirectory($0) && containsAll($0) }) {
            return "The model folders are inside “\(nested.lastPathComponent)”. Choose that folder instead."
        }
        let missing = expected.filter { !Self.isDirectory(source.appending(path: $0)) }.map { "“\($0)”" }.joined(separator: ", ")
        return "The chosen folder must contain \(list). Missing: \(missing). If the folder is in iCloud Drive, download it in Files first."
    }
    private static func missingFileMessage(_ relative: String) -> String {
        "Model file is missing: \(relative). If the folder is stored in iCloud Drive or another Files provider, make sure every file has finished downloading, then try again."
    }
    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
    /// A coordinated read materializes provider-backed placeholders before `body` runs.
    private static func coordinatedRead(of url: URL, _ body: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var bodyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { url in
            do { try body(url) } catch { bodyError = error }
        }
        if let coordinationError { throw coordinationError }
        if let bodyError { throw bodyError }
    }
    private static func safeRelativePath(_ path: String) -> Bool {
        !path.hasPrefix("/") && !path.contains("\\") && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }
}
