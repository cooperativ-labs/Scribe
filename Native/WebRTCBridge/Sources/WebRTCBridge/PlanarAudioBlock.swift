import Foundation

/// One block of deinterleaved 32-bit float audio.
///
/// The echo canceller works a fixed 10 ms at a time and wants one pointer per
/// channel, so the samples are held channel-major in a single contiguous
/// allocation. That keeps the per-block cost to pointer arithmetic: nothing here
/// allocates once a block exists, which is what lets a multi-hour recording be
/// processed with bounded memory.
public struct PlanarAudioBlock: Equatable, Sendable {
    public let channelCount: Int
    public let frameCount: Int

    /// `channelCount * frameCount` samples, channel-major.
    @usableFromInline
    internal var samples: [Float]

    /// A block of silence.
    public init(channelCount: Int, frameCount: Int) {
        precondition(channelCount > 0, "a block needs at least one channel")
        precondition(frameCount > 0, "a block needs at least one frame")
        self.channelCount = channelCount
        self.frameCount = frameCount
        self.samples = [Float](repeating: 0, count: channelCount * frameCount)
    }

    /// A block built from one array per channel. Every channel must be the same length.
    public init(channels: [[Float]]) {
        precondition(!channels.isEmpty, "a block needs at least one channel")
        let frames = channels[0].count
        precondition(frames > 0, "a block needs at least one frame")
        precondition(channels.allSatisfy { $0.count == frames },
                     "every channel must hold the same number of frames")
        self.channelCount = channels.count
        self.frameCount = frames
        self.samples = channels.flatMap { $0 }
    }

    /// The samples of one channel.
    public subscript(channel channel: Int) -> ArraySlice<Float> {
        precondition(channel >= 0 && channel < channelCount, "channel out of range")
        let start = channel * frameCount
        return samples[start ..< start + frameCount]
    }

    public subscript(channel channel: Int, frame frame: Int) -> Float {
        get {
            precondition(channel >= 0 && channel < channelCount, "channel out of range")
            precondition(frame >= 0 && frame < frameCount, "frame out of range")
            return samples[channel * frameCount + frame]
        }
        set {
            precondition(channel >= 0 && channel < channelCount, "channel out of range")
            precondition(frame >= 0 && frame < frameCount, "frame out of range")
            samples[channel * frameCount + frame] = newValue
        }
    }

    /// Replace one channel's samples.
    public mutating func setChannel(_ channel: Int, to values: [Float]) {
        precondition(channel >= 0 && channel < channelCount, "channel out of range")
        precondition(values.count == frameCount, "wrong frame count for this block")
        let start = channel * frameCount
        samples.replaceSubrange(start ..< start + frameCount, with: values)
    }

    /// Every channel as a separate array. Allocates; for tests and diagnostics.
    public var channels: [[Float]] {
        (0 ..< channelCount).map { Array(self[channel: $0]) }
    }

    /// Run `body` with a C-style array of per-channel pointers.
    ///
    /// The pointer array lives in temporary stack storage, so this is free of
    /// heap traffic on the processing path.
    @inlinable
    public func withUnsafeChannelPointers<R>(
        _ body: (UnsafePointer<UnsafePointer<Float>?>) throws -> R
    ) rethrows -> R {
        let channelCount = self.channelCount
        let frameCount = self.frameCount
        return try samples.withUnsafeBufferPointer { buffer in
            let base = buffer.baseAddress!
            return try withUnsafeTemporaryAllocation(
                of: UnsafePointer<Float>?.self, capacity: channelCount
            ) { pointers in
                for channel in 0 ..< channelCount {
                    pointers[channel] = base + channel * frameCount
                }
                return try body(UnsafePointer(pointers.baseAddress!))
            }
        }
    }

    /// Run `body` with a C-style array of mutable per-channel pointers.
    @inlinable
    public mutating func withUnsafeMutableChannelPointers<R>(
        _ body: (UnsafePointer<UnsafeMutablePointer<Float>?>) throws -> R
    ) rethrows -> R {
        let channelCount = self.channelCount
        let frameCount = self.frameCount
        return try samples.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            return try withUnsafeTemporaryAllocation(
                of: UnsafeMutablePointer<Float>?.self, capacity: channelCount
            ) { pointers in
                for channel in 0 ..< channelCount {
                    pointers[channel] = base + channel * frameCount
                }
                return try body(UnsafePointer(pointers.baseAddress!))
            }
        }
    }
}
