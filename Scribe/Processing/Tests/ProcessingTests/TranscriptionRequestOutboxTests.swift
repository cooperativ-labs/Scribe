import Foundation
import ScribeAppCore
import Testing
@testable import Processing

@Suite("Transcription request outbox") struct TranscriptionRequestOutboxTests {
    @Test func aSubmittedRequestSurvivesTheProcessThatWroteIt() async throws {
        let root = try outboxTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let request = TranscriptionRequest(
            sourceURL: root.appendingPathComponent("session/final.flac"),
            modelProfileID: "default",
            provenance: TranscriptionProvenance(producerID: FinalRecordingHandoff.producerID, sessionID: sessionID)
        )

        try await TranscriptionRequestOutbox.inRecordingsDirectory(root).submit(request)

        // A separate outbox over the same directory stands in for the next launch.
        let reopened = TranscriptionRequestOutbox.inRecordingsDirectory(root)
        let pending = try await reopened.pendingRequests()
        #expect(pending == [request])
        #expect(pending.first?.provenance?.sessionID == sessionID)
    }

    @Test func resubmittingTheSameRequestDoesNotQueueTheMeetingTwice() async throws {
        let root = try outboxTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = TranscriptionRequestOutbox.inRecordingsDirectory(root)
        let request = TranscriptionRequest(
            sourceURL: root.appendingPathComponent("session/final.flac"),
            modelProfileID: "default",
            provenance: TranscriptionProvenance(producerID: FinalRecordingHandoff.producerID, sessionID: UUID())
        )

        try await outbox.submit(request)
        try await outbox.submit(request)

        #expect(try await outbox.pendingRequests().count == 1)
    }

    @Test func aClaimedRequestIsNoLongerPending() async throws {
        let root = try outboxTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = TranscriptionRequestOutbox.inRecordingsDirectory(root)
        let request = TranscriptionRequest(
            sourceURL: root.appendingPathComponent("session/final.flac"),
            modelProfileID: "default"
        )

        try await outbox.submit(request)
        try await outbox.claim(request.requestID)
        // Claiming twice is harmless; a consumer may retry after a crash.
        try await outbox.claim(request.requestID)

        #expect(try await outbox.pendingRequests().isEmpty)
    }

    @Test func anOutboxThatHasNeverBeenWrittenToIsEmptyRatherThanAnError() async throws {
        let root = try outboxTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try await TranscriptionRequestOutbox.inRecordingsDirectory(root).pendingRequests().isEmpty)
    }
}

private func outboxTemporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ScribeOutboxTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
