import Foundation

/// Finds the pinned `ffprobe` and `ffmpeg` executables the importer and the
/// preparation service run.
///
/// A packaged build keeps them in `Contents/Library/Helpers`, beside the
/// transcription helper, so the same search that finds the worker finds these.
/// The environment overrides exist for development runs, where the reviewed
/// binaries sit wherever `Scripts/build-ffmpeg.sh` left them.
public enum MediaToolLocator {
    public static let ffprobeEnvironmentKey = "SCRIBE_FFPROBE_PATH"
    public static let ffmpegEnvironmentKey = "SCRIBE_FFMPEG_PATH"

    public enum Error: Swift.Error, LocalizedError, Equatable {
        case missing(name: String, searchedPaths: [String])

        public var errorDescription: String? {
            switch self {
            case let .missing(name, searchedPaths):
                "The bundled \(name) executable is missing. Searched: \(searchedPaths.joined(separator: ", "))."
            }
        }
    }

    public static func ffprobe(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> URL {
        try locate(named: "ffprobe", overrideKey: ffprobeEnvironmentKey, bundle: bundle, environment: environment, fileManager: fileManager)
    }

    public static func ffmpeg(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> URL {
        try locate(named: "ffmpeg", overrideKey: ffmpegEnvironmentKey, bundle: bundle, environment: environment, fileManager: fileManager)
    }

    static func locate(
        named name: String,
        overrideKey: String,
        bundle: Bundle,
        environment: [String: String],
        fileManager: FileManager
    ) throws -> URL {
        var candidates: [URL] = []
        if let override = environment[overrideKey] { candidates.append(URL(fileURLWithPath: override)) }
        candidates.append(bundle.bundleURL.appending(path: "Contents/Library/Helpers", directoryHint: .isDirectory).appending(path: name))
        if let executableDirectory = bundle.executableURL?.deletingLastPathComponent() {
            candidates.append(executableDirectory.appending(path: name))
        }
        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        throw Error.missing(name: name, searchedPaths: candidates.map(\.path))
    }
}
