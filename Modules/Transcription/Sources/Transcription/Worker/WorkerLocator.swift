import Foundation

/// Where the bundled helper and its offline model assets are on this machine.
///
/// `manifestURL` and `modelsDirectoryURL` are optional because the worker
/// resolves its own defaults when they are omitted. Passing them explicitly is
/// what a packaged application does; a development run can leave them nil and
/// let the helper's working directory answer.
public struct WorkerInstallation: Sendable, Equatable {
    public let executableURL: URL
    public let manifestURL: URL?
    public let modelsDirectoryURL: URL?

    public init(executableURL: URL, manifestURL: URL? = nil, modelsDirectoryURL: URL? = nil) {
        self.executableURL = executableURL
        self.manifestURL = manifestURL
        self.modelsDirectoryURL = modelsDirectoryURL
    }

    /// The helper's argument vector. Paths are passed as separate arguments and
    /// never interpolated into a command line, so spaces and non-ASCII
    /// characters in a user's home directory survive.
    public var arguments: [String] {
        var arguments: [String] = []
        if let manifestURL { arguments += ["--manifest", manifestURL.path] }
        if let modelsDirectoryURL { arguments += ["--models-directory", modelsDirectoryURL.path] }
        return arguments
    }
}

public enum WorkerLocatorError: Error, Equatable, Sendable {
    case helperMissing(searchedPaths: [String])
    case helperNotExecutable(URL)

    public var code: String {
        switch self {
        case .helperMissing: "transcription.worker.helperMissing"
        case .helperNotExecutable: "transcription.worker.helperNotExecutable"
        }
    }
}

extension WorkerLocatorError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .helperMissing(searchedPaths):
            "The bundled transcription helper is missing. Searched: \(searchedPaths.joined(separator: ", "))."
        case let .helperNotExecutable(url):
            "The transcription helper at \(url.path) is not an executable file."
        }
    }
}

/// Finds `TranscriptionWorker` inside the application bundle.
///
/// A packaged build keeps the helper in `Contents/Library/Helpers`, beside the
/// bundled FFmpeg tools. The environment override exists for development runs
/// and for the integration test, which drives the helper built by SwiftPM
/// rather than an installed copy.
public enum WorkerLocator {
    public static let helperName = "TranscriptionWorker"
    public static let executablePathEnvironmentKey = "SCRIBE_TRANSCRIPTION_WORKER_PATH"
    public static let manifestEnvironmentKey = "SCRIBE_TRANSCRIPTION_MODEL_MANIFEST"
    public static let modelsDirectoryEnvironmentKey = "SCRIBE_TRANSCRIPTION_MODELS_DIRECTORY"

    public static func locate(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> WorkerInstallation {
        let manifestURL = environment[manifestEnvironmentKey].map { URL(fileURLWithPath: $0) }
            ?? bundle.url(forResource: "model_manifest", withExtension: "json")
        let modelsDirectoryURL = environment[modelsDirectoryEnvironmentKey].map { URL(fileURLWithPath: $0, isDirectory: true) }

        if let override = environment[executablePathEnvironmentKey] {
            let url = URL(fileURLWithPath: override)
            guard fileManager.isExecutableFile(atPath: url.path) else { throw WorkerLocatorError.helperNotExecutable(url) }
            return WorkerInstallation(executableURL: url, manifestURL: manifestURL, modelsDirectoryURL: modelsDirectoryURL)
        }

        let candidates = searchPaths(in: bundle)
        for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
            guard fileManager.isExecutableFile(atPath: candidate.path) else { throw WorkerLocatorError.helperNotExecutable(candidate) }
            return WorkerInstallation(executableURL: candidate, manifestURL: manifestURL, modelsDirectoryURL: modelsDirectoryURL)
        }
        throw WorkerLocatorError.helperMissing(searchedPaths: candidates.map(\.path))
    }

    static func searchPaths(in bundle: Bundle) -> [URL] {
        var candidates = [bundle.bundleURL.appending(path: "Contents/Library/Helpers", directoryHint: .isDirectory).appending(path: helperName)]
        // A command-line or test host has no Helpers directory; the helper then
        // sits beside the running executable.
        if let executableDirectory = bundle.executableURL?.deletingLastPathComponent() {
            candidates.append(executableDirectory.appending(path: helperName))
        }
        return candidates
    }
}
