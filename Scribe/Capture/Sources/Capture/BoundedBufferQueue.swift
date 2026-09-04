import Foundation
import ScribeAppCore
import Storage

/// A fixed-byte-budget hand-off between the sample-handler queues and the writer.
///
/// A sample handler must never block on disk, and it must never grow without a
/// limit either: a stalled volume would otherwise turn into unbounded memory
/// growth and take the whole recording with it. Enqueue refuses once the budget is
/// reached and counts the refusal, so an overrun is a reported number rather than
/// a crash -- and "no dropped buffers" becomes something a test can assert.
public final class BoundedBufferQueue: @unchecked Sendable {
    public struct Statistics: Sendable, Equatable {
        public var enqueuedBuffers: Int
        public var droppedBuffers: Int
        public var droppedFrames: Int
        public var queuedBytes: Int
        public var peakQueuedBytes: Int
    }

    private let maximumBytes: Int
    private let lock = NSLock()
    private var pending: [OwnedPCMBuffer] = []
    private var statistics = Statistics(enqueuedBuffers: 0, droppedBuffers: 0, droppedFrames: 0, queuedBytes: 0, peakQueuedBytes: 0)

    /// - Parameter maximumBytes: defaults to roughly eight seconds of three-channel
    ///   48 kHz float32 audio, which is far more head room than the measured
    ///   20 ms and 10.67 ms buffer cadence needs, and still bounded.
    public init(maximumBytes: Int = 4 * 1_024 * 1_024) {
        self.maximumBytes = max(1, maximumBytes)
    }

    /// Returns false when the buffer did not fit. The caller has already copied the
    /// samples by this point, so a refusal costs one buffer, never the recording.
    @discardableResult
    public func enqueue(_ buffer: OwnedPCMBuffer) -> Bool {
        lock.withLock {
            let size = buffer.samples.count
            guard statistics.queuedBytes + size <= maximumBytes else {
                statistics.droppedBuffers += 1
                statistics.droppedFrames += buffer.frameCount
                return false
            }
            pending.append(buffer)
            statistics.enqueuedBuffers += 1
            statistics.queuedBytes += size
            statistics.peakQueuedBytes = max(statistics.peakQueuedBytes, statistics.queuedBytes)
            return true
        }
    }

    /// Takes everything queued so far in arrival order.
    public func drain() -> [OwnedPCMBuffer] {
        lock.withLock {
            let taken = pending
            pending.removeAll(keepingCapacity: true)
            statistics.queuedBytes = 0
            return taken
        }
    }

    public var snapshot: Statistics { lock.withLock { statistics } }

    public var isEmpty: Bool { lock.withLock { pending.isEmpty } }
}
