import Foundation
import ScribeAppCore

/// The role a file plays inside a recognized recorder session.
public enum RecorderSessionTrackRole: String, Codable, Sendable, Equatable, CaseIterable {
    case finalMix
    case system
    case microphone
}

/// Why a recorder session's final mix is not safe to preselect.
///
/// Every case carries a sentence a person can read, because the plan requires a
/// *visible* reason rather than a silently unselected row. This mirrors the
/// recorder-side `FinalRecordingHandoffRefusal` gate; the two are deliberately
/// separate so the module boundary stays one-directional — the recorder decides
/// what it may hand out, the importer decides what it will accept.
public enum RecorderSessionRejection: Equatable, Sendable {
    case manifestUnreadable(String)
    case unsupportedSchemaVersion(Int)
    case processingIncomplete(ProcessingState)
    case cleanupFailed(String)
    case finalTrackNotDescribed
    case finalFileMissing(String)
    case finalFileUnreadable(String)
    case checksumMismatch(expected: String, actual: String)

    public var code: String {
        switch self {
        case .manifestUnreadable: "import.session.manifestUnreadable"
        case .unsupportedSchemaVersion: "import.session.unsupportedSchemaVersion"
        case .processingIncomplete: "import.session.processingIncomplete"
        case .cleanupFailed: "import.session.cleanupFailed"
        case .finalTrackNotDescribed: "import.session.finalTrackNotDescribed"
        case .finalFileMissing: "import.session.finalFileMissing"
        case .finalFileUnreadable: "import.session.finalFileUnreadable"
        case .checksumMismatch: "import.session.checksumMismatch"
        }
    }

    public var message: String {
        switch self {
        case .manifestUnreadable(let reason):
            "This looks like a recording session, but its metadata could not be read: \(reason)"
        case .unsupportedSchemaVersion(let version):
            "This recording uses metadata version \(version), which this build does not recognize."
        case .processingIncomplete(let state):
            "Audio cleanup is \(state.rawValue); the final recording is not ready to transcribe yet."
        case .cleanupFailed(let reason):
            "Audio cleanup failed, so there is no verified final recording: \(reason)"
        case .finalTrackNotDescribed:
            "Audio cleanup reported success but did not describe a final recording."
        case .finalFileMissing(let name):
            "\(name) is missing from the recording folder."
        case .finalFileUnreadable(let reason):
            "The final recording could not be read: \(reason)"
        case .checksumMismatch:
            "The final recording on disk does not match the one the recorder verified."
        }
    }
}

/// A folder recognized as recorder output, together with what may be preselected.
public struct RecorderSession: Equatable, Sendable {
    public let directoryURL: URL
    /// `nil` when `metadata.json` exists but could not be decoded.
    public let manifest: RecorderSessionManifest?
    /// The verified final mix, present only when nothing rejected the session.
    public let finalTrackFileName: String?
    /// Non-`nil` whenever the final mix must stay unselected; `message` is shown.
    public let rejection: RecorderSessionRejection?
    /// File name to role, for every track the session declares.
    public let trackRoles: [String: RecorderSessionTrackRole]

    public var sessionID: UUID? { manifest?.sessionID }
    public var isEligible: Bool { rejection == nil && finalTrackFileName != nil }

    public func role(ofFileNamed name: String) -> RecorderSessionTrackRole? { trackRoles[name] }
}

/// Decides whether a folder is recorder output and whether its final mix is usable.
///
/// Recognition reads only the three fields the plan pins as stable — schema
/// version, `processing.state`, and `tracks.final.checksum` — and re-hashes the
/// published file instead of trusting the manifest's claim about it. A filename
/// is never sufficient on its own: without a `metadata.json` beside them, files
/// called `final.flac` or `system.flac` are ordinary importable audio.
public struct RecorderSessionRecognizer: Sendable {
    public static let manifestFileName = "metadata.json"
    public static let supportedSchemaVersions: Set<Int> = [RecorderSessionManifest.currentSchemaVersion]

    /// Conventional names used only when a `metadata.json` is present but
    /// undecodable. The folder has declared itself as a session, so withholding
    /// preselection from the tracks it conventionally contains is the safe
    /// reading; the user can still select any of them explicitly.
    static let conventionalTrackRoles: [String: RecorderSessionTrackRole] = [
        "final.flac": .finalMix,
        "system.flac": .system,
        "microphone.flac": .microphone,
    ]

    private let supportedSchemaVersions: Set<Int>
    private let checksumOfFile: @Sendable (URL) throws -> String
    // FileManager's documented contract permits concurrent use of an instance's
    // file operations; the reference is held unsafely rather than making the
    // whole service a class just to satisfy the checker.
    nonisolated(unsafe) private let fileManager: FileManager

    public init(
        supportedSchemaVersions: Set<Int> = RecorderSessionRecognizer.supportedSchemaVersions,
        fileManager: FileManager = .default,
        // Injected so a test can force a mismatch without corrupting a fixture,
        // and so the verifying hash is the one that produced the manifest value.
        checksumOfFile: @escaping @Sendable (URL) throws -> String = { try FileContentHash.sha256(ofFileAt: $0).digest }
    ) {
        self.supportedSchemaVersions = supportedSchemaVersions
        self.fileManager = fileManager
        self.checksumOfFile = checksumOfFile
    }

    /// Returns `nil` when the folder is not recorder output at all.
    public func recognizeSession(at directoryURL: URL) -> RecorderSession? {
        let manifestURL = directoryURL.appendingPathComponent(Self.manifestFileName)
        guard fileManager.fileExists(atPath: manifestURL.path) else { return nil }

        let manifest: RecorderSessionManifest
        do {
            manifest = try RecorderSessionManifestCodec.decode(Data(contentsOf: manifestURL))
        } catch {
            return RecorderSession(
                directoryURL: directoryURL,
                manifest: nil,
                finalTrackFileName: nil,
                rejection: .manifestUnreadable(error.localizedDescription),
                trackRoles: Self.conventionalTrackRoles
            )
        }

        var roles: [String: RecorderSessionTrackRole] = [:]
        if let system = manifest.tracks.system { roles[system.fileName] = .system }
        if let microphone = manifest.tracks.microphone { roles[microphone.fileName] = .microphone }
        if let finalTrack = manifest.tracks.finalTrack { roles[finalTrack.fileName] = .finalMix }

        func reject(_ rejection: RecorderSessionRejection) -> RecorderSession {
            RecorderSession(directoryURL: directoryURL, manifest: manifest, finalTrackFileName: nil, rejection: rejection, trackRoles: roles)
        }

        guard supportedSchemaVersions.contains(manifest.schemaVersion) else {
            // An unrecognized version may have moved the fields this gate reads,
            // so the conventional names are the only safe roles to claim.
            return RecorderSession(
                directoryURL: directoryURL,
                manifest: manifest,
                finalTrackFileName: nil,
                rejection: .unsupportedSchemaVersion(manifest.schemaVersion),
                trackRoles: roles.isEmpty ? Self.conventionalTrackRoles : roles
            )
        }

        switch manifest.processing.state {
        case .complete:
            break
        case .failed:
            return reject(.cleanupFailed(Self.failureReason(manifest.processing.errors)))
        case .pending, .running:
            return reject(.processingIncomplete(manifest.processing.state))
        }

        guard let finalTrack = manifest.tracks.finalTrack else { return reject(.finalTrackNotDescribed) }

        let finalURL = directoryURL.appendingPathComponent(finalTrack.fileName)
        guard fileManager.fileExists(atPath: finalURL.path) else { return reject(.finalFileMissing(finalTrack.fileName)) }

        let actual: String
        do { actual = try checksumOfFile(finalURL) } catch { return reject(.finalFileUnreadable(error.localizedDescription)) }
        guard actual.caseInsensitiveCompare(finalTrack.checksum) == .orderedSame else {
            return reject(.checksumMismatch(expected: finalTrack.checksum, actual: actual))
        }

        return RecorderSession(
            directoryURL: directoryURL,
            manifest: manifest,
            finalTrackFileName: finalTrack.fileName,
            rejection: nil,
            trackRoles: roles
        )
    }

    /// Prefers the mixdown's own reason so the message names the stage that gave up.
    private static func failureReason(_ errors: [ManifestError]) -> String {
        if let mixdown = errors.last(where: { $0.code.hasPrefix("mixdown.") }) { return mixdown.message }
        if let last = errors.last { return last.message }
        return "no reason was recorded"
    }
}
