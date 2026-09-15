import Foundation
import ScribeAppCore

/// What one drain of the handoff point did.
public struct TranscriptionHandoffOutcome: Sendable, Equatable {
    public let queued: [UUID]
    public let failures: [(requestID: UUID, message: String)]

    public var isEmpty: Bool { queued.isEmpty && failures.isEmpty }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.queued == rhs.queued && lhs.failures.map(\.requestID) == rhs.failures.map(\.requestID)
    }
}

/// Turns published recordings into queued transcription jobs.
///
/// A request is claimed only after its job record exists on disk. A crash
/// between the two therefore leaves the request in the outbox and the meeting is
/// queued again on the next drain; the alternative — claiming first — loses the
/// recording silently, which is the failure nobody would notice.
///
/// Re-queueing the same source is safe rather than merely tolerable: the
/// importer fingerprints content and configuration, so a repeat is recognizable
/// as a repeat.
public struct TranscriptionHandoffConsumer: Sendable {
    private let source: any TranscriptionHandoffSource
    private let didQueue: @Sendable (TranscriptionRequest, TranscriptionJob) async -> Void

    public init(
        source: any TranscriptionHandoffSource,
        didQueue: @escaping @Sendable (TranscriptionRequest, TranscriptionJob) async -> Void = { _, _ in }
    ) {
        self.source = source
        self.didQueue = didQueue
    }

    @discardableResult
    public func drain(into coordinator: TranscriptionCoordinator) async throws -> TranscriptionHandoffOutcome {
        var queued: [UUID] = []
        var failures: [(requestID: UUID, message: String)] = []
        for request in try await source.pendingRequests() {
            let job: TranscriptionJob
            do {
                job = try await coordinator.enqueue(request)
            } catch {
                // Left in the outbox on purpose. A source that is momentarily
                // unreadable is a reason to try again, not to drop a meeting.
                failures.append((request.requestID, error.localizedDescription))
                continue
            }
            queued.append(request.requestID)
            do {
                try await source.claim(request.requestID)
            } catch {
                // The job is durable, but leave producer-owned files in place
                // while the outbox may still retry this request.
                failures.append((request.requestID, error.localizedDescription))
                continue
            }
            // The private source snapshot is durable and the handoff record is
            // retired. Producer-owned files can now be cleaned up without
            // turning a failed claim into an unreadable request on relaunch.
            await didQueue(request, job)
        }
        return TranscriptionHandoffOutcome(queued: queued, failures: failures)
    }
}
