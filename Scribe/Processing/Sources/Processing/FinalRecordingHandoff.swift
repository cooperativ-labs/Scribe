import FLACBridge
import Foundation
import ScribeAppCore

/// Why a finished session was *not* handed to transcription.
///
/// Every case is a reason the caller can show a person. That is the point: the
/// handoff refuses far more often than it succeeds during a failed run, and a
/// silent refusal would look identical to "transcription is disabled".
public enum FinalRecordingHandoffRefusal: Error, Equatable, Sendable {
    /// No manifest, or one this build cannot decode.
    case manifestUnreadable(String)
    /// A schema version this build does not recognize. Reading it anyway would
    /// mean guessing at the meaning of the three stable importer fields.
    case unsupportedSchemaVersion(Int)
    /// Processing has not finished yet. Not an error; just not ready.
    case processingIncomplete(ProcessingState)
    /// Cleanup failed. The originals are intact, but there is no verified mix,
    /// so nothing may be handed off: substituting a raw track here is exactly
    /// the silent downgrade the plan forbids.
    case cleanupFailed(String)
    /// Processing reported complete without describing a final track.
    case finalTrackNotDescribed
    case finalFileMissing(String)
    case finalFileUnreadable(String)
    /// The file on disk is not the file the manifest verified.
    case checksumMismatch(expected: String, actual: String)

    public var code: String {
        switch self {
        case .manifestUnreadable: "handoff.manifestUnreadable"
        case .unsupportedSchemaVersion: "handoff.unsupportedSchemaVersion"
        case .processingIncomplete: "handoff.processingIncomplete"
        case .cleanupFailed: "handoff.cleanupFailed"
        case .finalTrackNotDescribed: "handoff.finalTrackNotDescribed"
        case .finalFileMissing: "handoff.finalFileMissing"
        case .finalFileUnreadable: "handoff.finalFileUnreadable"
        case .checksumMismatch: "handoff.checksumMismatch"
        }
    }

    public var message: String {
        switch self {
        case .manifestUnreadable(let reason):
            "The recording's metadata could not be read: \(reason)"
        case .unsupportedSchemaVersion(let version):
            "The recording uses metadata version \(version), which this build does not recognize."
        case .processingIncomplete(let state):
            "Audio cleanup is \(state.rawValue); the final recording is not ready yet."
        case .cleanupFailed(let reason):
            "Audio cleanup failed, so there is no final recording to transcribe: \(reason)"
        case .finalTrackNotDescribed:
            "Audio cleanup reported success but did not describe a final recording."
        case .finalFileMissing(let name):
            "\(name) is missing from the recording folder."
        case .finalFileUnreadable(let reason):
            "The final recording could not be read: \(reason)"
        case .checksumMismatch:
            "The final recording on disk does not match the one that was verified."
        }
    }

    public var recoveryHint: String? {
        switch self {
        case .processingIncomplete:
            nil
        case .cleanupFailed, .finalTrackNotDescribed, .checksumMismatch, .finalFileMissing:
            "The original tracks were kept. Reprocess the session to try again."
        case .manifestUnreadable, .unsupportedSchemaVersion, .finalFileUnreadable:
            "Open the recordings folder to inspect the session."
        }
    }

    /// True while the session may still become handoff-eligible on its own.
    /// Everything else needs a person or a rerun.
    public var isTransient: Bool {
        if case .processingIncomplete = self { return true }
        return false
    }
}

/// The gate between a finished recording and the transcription module.
///
/// It reads only the three fields the transcription importer treats as stable —
/// schema version, processing state, and the `final.flac` checksum — and it
/// re-hashes the published file rather than trusting the manifest's claim that
/// it exists. A `TranscriptionRequest` comes out only when all of that holds.
public struct FinalRecordingHandoff: Sendable {
    /// Identifies the recorder in `TranscriptionProvenance`. The session ID
    /// travels beside it so a transcript can always be traced to its meeting.
    public static let producerID = "com.scribe.recorder"
    /// The transcription module owns the real profile registry; until it lands,
    /// the handoff asks for that module's default.
    public static let defaultModelProfileID = "default"
    public static let supportedSchemaVersions: Set<Int> = [RecorderSessionManifest.currentSchemaVersion]

    private let modelProfileID: String
    private let supportedSchemaVersions: Set<Int>
    private let exportDirectory: URL?
    private let checksumOfFile: @Sendable (URL) throws -> String

    public init(
        modelProfileID: String = FinalRecordingHandoff.defaultModelProfileID,
        supportedSchemaVersions: Set<Int> = FinalRecordingHandoff.supportedSchemaVersions,
        exportDirectory: URL? = nil,
        // Injected so a test can force a mismatch, and so the hash that verifies
        // the file is the same routine that produced the manifest's value.
        checksumOfFile: @escaping @Sendable (URL) throws -> String = { try FLACEncoder.sha256(ofFileAt: $0) }
    ) {
        self.modelProfileID = modelProfileID
        self.supportedSchemaVersions = supportedSchemaVersions
        self.exportDirectory = exportDirectory
        self.checksumOfFile = checksumOfFile
    }

    /// Verifies a session and returns the request to submit for its final mix.
    ///
    /// Throws `FinalRecordingHandoffRefusal` — never a partially trusted result.
    public func request(forSessionAt sessionDirectory: URL) throws -> TranscriptionRequest {
        let manifest = try readManifest(in: sessionDirectory)

        guard supportedSchemaVersions.contains(manifest.schemaVersion) else {
            throw FinalRecordingHandoffRefusal.unsupportedSchemaVersion(manifest.schemaVersion)
        }

        switch manifest.processing.state {
        case .complete:
            break
        case .failed:
            throw FinalRecordingHandoffRefusal.cleanupFailed(Self.failureReason(manifest.processing.errors))
        case .pending, .running:
            throw FinalRecordingHandoffRefusal.processingIncomplete(manifest.processing.state)
        }

        guard let finalTrack = manifest.tracks.finalTrack else {
            throw FinalRecordingHandoffRefusal.finalTrackNotDescribed
        }

        let finalURL = sessionDirectory.appendingPathComponent(finalTrack.fileName)
        guard FileManager.default.fileExists(atPath: finalURL.path) else {
            throw FinalRecordingHandoffRefusal.finalFileMissing(finalTrack.fileName)
        }

        let actual: String
        do {
            actual = try checksumOfFile(finalURL)
        } catch {
            throw FinalRecordingHandoffRefusal.finalFileUnreadable(error.localizedDescription)
        }
        guard actual.caseInsensitiveCompare(finalTrack.checksum) == .orderedSame else {
            throw FinalRecordingHandoffRefusal.checksumMismatch(expected: finalTrack.checksum, actual: actual)
        }

        return TranscriptionRequest(
            sourceURL: finalURL,
            modelProfileID: modelProfileID,
            exportDirectory: exportDirectory,
            provenance: TranscriptionProvenance(producerID: Self.producerID, sessionID: manifest.sessionID)
        )
    }

    private func readManifest(in sessionDirectory: URL) throws -> RecorderSessionManifest {
        let url = sessionDirectory.appendingPathComponent("metadata.json")
        do {
            return try RecorderSessionManifestCodec.decode(Data(contentsOf: url))
        } catch {
            throw FinalRecordingHandoffRefusal.manifestUnreadable(error.localizedDescription)
        }
    }

    /// Prefers the mixdown's own reason over an earlier pipeline error, so the
    /// message a person sees names the stage that actually gave up.
    private static func failureReason(_ errors: [ManifestError]) -> String {
        if let mixdown = errors.last(where: { $0.code.hasPrefix("mixdown.") }) { return mixdown.message }
        if let last = errors.last { return last.message }
        return "no reason was recorded"
    }
}
