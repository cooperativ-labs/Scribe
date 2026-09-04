import Foundation
import ScribeAppCore
import Storage
import Testing
@testable import Capture

@Suite struct BoundedBufferQueueTests {
    private func buffer(frames: Int, track: RecorderTrackKind = .system) throws -> OwnedPCMBuffer {
        let format = PCMFormat(sampleRate: 48_000, channelCount: 2, bitsPerChannel: 32, isFloat: true)
        return try OwnedPCMBuffer(
            track: track,
            presentationTimestampSeconds: 0,
            format: format,
            frameCount: frames,
            samples: Data(count: frames * format.bytesPerFrame)
        )
    }

    @Test func drainReturnsBuffersInArrivalOrderAndFreesTheBudget() throws {
        let queue = BoundedBufferQueue(maximumBytes: 64 * 1_024)
        for frames in [10, 20, 30] { #expect(queue.enqueue(try buffer(frames: frames))) }

        #expect(queue.snapshot.queuedBytes == 60 * 8)
        #expect(queue.drain().map(\.frameCount) == [10, 20, 30])
        #expect(queue.isEmpty)
        #expect(queue.snapshot.queuedBytes == 0)
        #expect(queue.snapshot.peakQueuedBytes == 60 * 8)
        #expect(queue.snapshot.droppedBuffers == 0)
    }

    /// A stalled writer must cost bounded memory, not the machine. The refusal is
    /// counted so "no dropped buffers" is a number a test can assert rather than
    /// an absence of evidence.
    @Test func aFullQueueRefusesAndCountsRatherThanGrowing() throws {
        let format = PCMFormat(sampleRate: 48_000, channelCount: 2, bitsPerChannel: 32, isFloat: true)
        let queue = BoundedBufferQueue(maximumBytes: 100 * format.bytesPerFrame)

        #expect(queue.enqueue(try buffer(frames: 60)))
        #expect(queue.enqueue(try buffer(frames: 40)))
        #expect(!queue.enqueue(try buffer(frames: 1)))

        let statistics = queue.snapshot
        #expect(statistics.enqueuedBuffers == 2)
        #expect(statistics.droppedBuffers == 1)
        #expect(statistics.droppedFrames == 1)
        #expect(statistics.queuedBytes == 100 * format.bytesPerFrame)

        // Draining releases the budget, and the queue accepts again.
        #expect(queue.drain().count == 2)
        #expect(queue.enqueue(try buffer(frames: 100)))
        #expect(queue.snapshot.droppedBuffers == 1)
    }

    @Test func concurrentProducersAndOneDrainerLoseNothing() throws {
        let queue = BoundedBufferQueue(maximumBytes: 8 * 1_024 * 1_024)
        let producers = 4
        let perProducer = 250

        DispatchQueue.concurrentPerform(iterations: producers) { _ in
            for frame in 0..<perProducer {
                _ = queue.enqueue(try! buffer(frames: frame % 32 + 1))
            }
        }

        let drained = queue.drain()
        #expect(drained.count == producers * perProducer)
        #expect(queue.snapshot.droppedBuffers == 0)
        #expect(queue.snapshot.enqueuedBuffers == producers * perProducer)
    }
}
