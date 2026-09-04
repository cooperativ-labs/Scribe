import Foundation
import ScribeAppCore

/// Where a verified `TranscriptionRequest` is handed off to.
///
/// The recorder never calls the transcription module directly: capture and
/// cleanup must not wait on transcription, and the module is not required to be
/// installed. Submission is therefore a one-way handoff behind this protocol.
public protocol TranscriptionRequestSubmitting: Sendable {
    func submit(_ request: TranscriptionRequest) async throws
}

/// A durable, on-disk handoff point for verified transcription requests.
///
/// A request is a fact about a session that has already been published, so it
/// outlives the app: writing it down means a quit, a crash, or a transcription
/// module that is not running yet cannot lose the handoff. Each request is one
/// atomically written file, and the outbox lives beside the processing queue
/// rather than inside any session directory, which the recorder owns.
public actor TranscriptionRequestOutbox: TranscriptionRequestSubmitting {
    public static let directoryName = ".scribe-transcription-requests"

    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static func inRecordingsDirectory(_ recordingsDirectory: URL) -> TranscriptionRequestOutbox {
        TranscriptionRequestOutbox(directory: recordingsDirectory.appendingPathComponent(directoryName, isDirectory: true))
    }

    /// Idempotent by request ID: re-submitting the same request rewrites the
    /// same file rather than queueing the meeting twice.
    public func submit(_ request: TranscriptionRequest) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicReplaceFileWriter().write(
            encoder.encode(request),
            to: directory.appendingPathComponent("\(request.requestID.uuidString).json")
        )
    }

    /// Every request handed off so far and not yet claimed, oldest file first.
    public func pendingRequests() throws -> [TranscriptionRequest] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { try? decoder.decode(TranscriptionRequest.self, from: Data(contentsOf: $0)) }
    }

    /// Removes a request once a consumer has taken responsibility for it.
    public func claim(_ requestID: UUID) throws {
        let url = directory.appendingPathComponent("\(requestID.uuidString).json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

/// The outbox is the consuming side's handoff source too. Declaring it here,
/// rather than in whichever application happens to compose the two modules,
/// keeps one conformance for the app, the tools, and the tests.
extension TranscriptionRequestOutbox: TranscriptionHandoffSource {}
