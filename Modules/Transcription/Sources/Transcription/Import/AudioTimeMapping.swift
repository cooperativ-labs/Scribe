import Foundation

/// An affine relation between decoded working frames and the source-media timeline.
///
/// The preparation stage never trims leading silence: frame zero maps to source time zero. The
/// offsets are persisted even when they are zero, so a future decoder with non-zero priming can be
/// represented without changing transcript timestamp semantics.
public struct AudioTimeMapping: Codable, Equatable, Sendable {
    public let sourceTimelineOffset: TimeInterval
    public let decoderOutputOffset: TimeInterval
    public let sourceSampleRate: Double
    public let workingSampleRate: Double

    public init(
        sourceTimelineOffset: TimeInterval = 0,
        decoderOutputOffset: TimeInterval = 0,
        sourceSampleRate: Double,
        workingSampleRate: Double = 16_000
    ) {
        self.sourceTimelineOffset = sourceTimelineOffset
        self.decoderOutputOffset = decoderOutputOffset
        self.sourceSampleRate = sourceSampleRate
        self.workingSampleRate = workingSampleRate
    }

    public var sourceFramesPerWorkingFrame: Double { sourceSampleRate / workingSampleRate }

    public func sourceTime(forWorkingFrame frame: Int64) -> TimeInterval {
        sourceTime(forWorkingSeconds: Double(frame) / workingSampleRate)
    }

    /// Maps a time on the prepared 16 kHz working file onto the source-media timeline.
    public func sourceTime(forWorkingSeconds seconds: TimeInterval) -> TimeInterval {
        sourceTimelineOffset + seconds - decoderOutputOffset
    }

    public func workingFrame(forSourceTime time: TimeInterval) -> Int64 {
        Int64(((time - sourceTimelineOffset + decoderOutputOffset) * workingSampleRate).rounded())
    }

    public func sourceFrame(forWorkingFrame frame: Int64) -> Double {
        (Double(frame) / workingSampleRate) * sourceSampleRate
    }
}
