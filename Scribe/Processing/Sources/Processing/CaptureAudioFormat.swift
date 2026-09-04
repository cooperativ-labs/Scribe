import Foundation

/// The native interleaved linear-PCM layout of one capture segment.
///
/// This mirrors what `SessionStore` writes into each CAF description chunk. It is
/// re-declared here rather than imported so the processing pipeline depends on the
/// on-disk archive format, not on the writer that produced it.
public struct CaptureAudioFormat: Sendable, Equatable, CustomStringConvertible {
    public let sampleRate: Int
    public let channelCount: Int
    public let bitsPerChannel: Int
    public let isFloat: Bool

    public init(sampleRate: Int, channelCount: Int, bitsPerChannel: Int, isFloat: Bool) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitsPerChannel = bitsPerChannel
        self.isFloat = isFloat
    }

    public var bytesPerSample: Int { bitsPerChannel / 8 }
    public var bytesPerFrame: Int { bytesPerSample * channelCount }

    public var description: String {
        "lpcm \(sampleRate) Hz, \(channelCount) ch, \(isFloat ? "float" : "int")\(bitsPerChannel), interleaved"
    }

    public var isSupported: Bool {
        guard sampleRate > 0, channelCount > 0, bitsPerChannel > 0, bitsPerChannel.isMultiple(of: 8) else { return false }
        if isFloat { return bitsPerChannel == 32 || bitsPerChannel == 64 }
        return bitsPerChannel == 8 || bitsPerChannel == 16 || bitsPerChannel == 24 || bitsPerChannel == 32
    }
}
