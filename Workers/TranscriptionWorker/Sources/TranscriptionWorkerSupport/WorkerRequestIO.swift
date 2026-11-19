import Foundation
import ScribeAppCore

/// Thread-safe request and cancellation state shared by the stdin reader and
/// the request-processing loop.
final class WorkerRequestState: @unchecked Sendable {
    private let condition = NSCondition()
    private var queue: [WorkerEnvelope] = []
    private var cancelledRequestIDs = Set<String>()
    private var isClosed = false

    func enqueue(_ envelope: WorkerEnvelope) {
        condition.withLock {
            queue.append(envelope)
            condition.signal()
        }
    }

    func cancel(_ requestID: String) {
        condition.withLock {
            _ = cancelledRequestIDs.insert(requestID)
        }
    }

    func isCancelled(_ requestID: String) -> Bool {
        condition.withLock { cancelledRequestIDs.contains(requestID) }
    }

    func finish() {
        condition.withLock {
            isClosed = true
            condition.broadcast()
        }
    }

    func next() -> WorkerEnvelope? {
        condition.withLock {
            while queue.isEmpty && !isClosed {
                condition.wait()
            }
            return queue.isEmpty ? nil : queue.removeFirst()
        }
    }
}

/// Serializes stdout writes so progress and control responses cannot interleave.
final class WorkerEnvelopeWriter: @unchecked Sendable {
    private let lock = NSLock()

    func write(_ envelope: WorkerEnvelope) {
        lock.withLock {
            do {
                let data = try WorkerWireFormat.encode(envelope)
                FileHandle.standardOutput.write(data)
            } catch let error as WorkerWireFormatError {
                FileHandle.standardError.write(Data("Failed to write worker response: \(error.workerDiagnostic)\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("Failed to write worker response: \(error.localizedDescription)\n".utf8))
            }
        }
    }
}

extension WorkerJSONValue {
    static func encoding<Value: Encodable>(_ value: Value) throws -> WorkerJSONValue {
        try JSONDecoder().decode(WorkerJSONValue.self, from: JSONEncoder().encode(value))
    }
}
