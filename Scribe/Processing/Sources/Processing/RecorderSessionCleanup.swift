import Foundation

public enum RecorderSessionCleanupError: Error, Equatable, Sendable {
    case unsafeDirectory(String)
}

extension RecorderSessionCleanupError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsafeDirectory(let path):
            "Refused to delete a recording directory outside the configured recordings folder: \(path)"
        }
    }
}

/// Deletes a recorder-owned meeting directory after transcription has made an
/// independent source snapshot. The direct-child check prevents a malformed or
/// historical handoff request from broadening deletion beyond one session.
public enum RecorderSessionCleanup {
    @discardableResult
    public static func removeSession(
        at sessionDirectory: URL,
        from recordingsDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> Bool {
        let root = recordingsDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let session = sessionDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard session != root,
              session.deletingLastPathComponent() == root,
              !session.lastPathComponent.hasPrefix(".")
        else {
            throw RecorderSessionCleanupError.unsafeDirectory(session.path)
        }
        guard fileManager.fileExists(atPath: session.path) else { return false }
        try fileManager.removeItem(at: session)
        return true
    }
}
