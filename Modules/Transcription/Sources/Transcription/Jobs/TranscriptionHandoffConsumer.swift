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

    public init(source: any TranscriptionHandoffSource) {
        self.source = source
    }

    @discardableResult
    public func drain(into coordinator: TranscriptionCoordinator) async throws -> TranscriptionHandoffOutcome {
        var queued: [UUID] = []
        var failures: [(requestID: UUID, message: String)] = []
        for request in try await source.pendingRequests() {
            do {
                _ = try await coordinator.enqueue(request)
            } catch {
                // Left in the outbox on purpose. A source that is momentarily
                // unreadable is a reason to try again, not to drop a meeting.
                failures.append((request.requestID, error.localizedDescription))
                continue
            }
            try? await source.claim(request.requestID)
            queued.append(request.requestID)
        }
        return TranscriptionHandoffOutcome(queued: queued, failures: failures)
    }
}
