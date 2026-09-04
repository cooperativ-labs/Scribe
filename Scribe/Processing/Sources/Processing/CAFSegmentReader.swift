import Foundation

public enum CAFReadError: Error, Equatable, CustomStringConvertible {
    case notCAF(String)
    case missingChunk(String, String)
    case unsupportedFormat(String, String)
    case shortRead(String, expectedFrames: Int64, availableFrames: Int64)

    public var description: String {
        switch self {
        case .notCAF(let file): return "\(file) is not a CAF file"
        case let .missingChunk(file, chunk): return "\(file) has no \(chunk) chunk"
        case let .unsupportedFormat(file, detail): return "\(file) declares an unsupported format: \(detail)"
        case let .shortRead(file, expected, available): return "\(file) holds \(available) frames; the journal claims \(expected)"
        }
    }
}

/// Read-only random access to one capture CAF segment.
///
/// The reader opens the file for reading only and never seeks a write handle at
/// it, which is how the plan's "preserve the source archive unchanged" rule is
/// enforced mechanically rather than by convention. Frames are pulled in bounded
/// slices so a two-hour segment set never has to be resident.
public final class CAFSegmentReader {
    public let url: URL
    public let format: CaptureAudioFormat
    /// Total frames of PCM actually present in the file's data chunk.
    public let frameCount: Int64

    private let handle: FileHandle
    private let audioDataOffset: UInt64

    public init(url: URL) throws {
        self.url = url
        let name = url.lastPathComponent
        let handle = try FileHandle(forReadingFrom: url)
        self.handle = handle

        let header = try handle.read(upToCount: 8) ?? Data()
        guard header.count == 8, header.prefix(4) == Data("caff".utf8) else {
            try? handle.close()
            throw CAFReadError.notCAF(name)
        }

        var format: CaptureAudioFormat?
        var dataStart: UInt64?
        var dataByteCount: Int64 = 0
        var offset: UInt64 = 8
        let fileSize = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0

        while offset + 12 <= UInt64(fileSize) {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 12), header.count == 12 else { break }
            let chunkType = String(decoding: header.prefix(4), as: UTF8.self)
            let declared = header.int64(at: 4)
            let bodyStart = offset + 12
            // A CAF chunk size of -1 means "to the end of the file"; the writer only
            // does this for a segment that was still open when the process died.
            let bodySize = declared < 0 ? Int64(UInt64(fileSize) - bodyStart) : declared

            switch chunkType {
            case "desc":
                guard let body = try handle.read(upToCount: 32), body.count == 32 else {
                    try? handle.close()
                    throw CAFReadError.missingChunk(name, "desc")
                }
                // CAF desc: Float64 sample rate, then format ID, format flags,
                // bytes per packet, frames per packet, channels, bits per channel.
                let sampleRate = body.double(at: 0)
                let formatID = body.ascii(at: 8, count: 4)
                let flags = body.uint32(at: 12)
                let channels = Int(body.uint32(at: 24))
                let bits = Int(body.uint32(at: 28))
                guard formatID == "lpcm" else {
                    try? handle.close()
                    throw CAFReadError.unsupportedFormat(name, "format ID \(formatID) is not lpcm")
                }
                guard flags & 0x2 != 0 else {
                    try? handle.close()
                    throw CAFReadError.unsupportedFormat(name, "big-endian PCM is not produced by this recorder")
                }
                format = CaptureAudioFormat(
                    sampleRate: Int(sampleRate.rounded()),
                    channelCount: channels,
                    bitsPerChannel: bits,
                    isFloat: flags & 0x1 != 0
                )
            case "data":
                // The first four bytes of a CAF data chunk are the edit count.
                dataStart = bodyStart + 4
                dataByteCount = max(0, bodySize - 4)
            default:
                break
            }
            guard bodySize >= 0 else { break }
            offset = bodyStart + UInt64(bodySize)
        }

        guard let resolvedFormat = format else {
            try? handle.close()
            throw CAFReadError.missingChunk(name, "desc")
        }
        guard resolvedFormat.isSupported else {
            try? handle.close()
            throw CAFReadError.unsupportedFormat(name, resolvedFormat.description)
        }
        guard let resolvedStart = dataStart else {
            try? handle.close()
            throw CAFReadError.missingChunk(name, "data")
        }
        // Trust the file's own length over the declared chunk size: a segment
        // recovered after a crash has a repaired length, and a truncated one must
        // read as short rather than as garbage past the end.
        let availableBytes = min(dataByteCount, max(0, fileSize - Int64(resolvedStart)))
        self.format = resolvedFormat
        self.audioDataOffset = resolvedStart
        self.frameCount = availableBytes / Int64(resolvedFormat.bytesPerFrame)
    }

    deinit { try? handle.close() }

    public func close() throws { try handle.close() }

    /// Reads up to `frameCount` frames starting at `startFrame`, deinterleaved into
    /// one `Float` array per channel and normalized to -1...1.
    public func readFrames(startingAt startFrame: Int64, count requestedCount: Int) throws -> [[Float]] {
        guard requestedCount > 0, startFrame < frameCount else {
            return Array(repeating: [], count: format.channelCount)
        }
        let available = Int(min(Int64(requestedCount), frameCount - max(0, startFrame)))
        guard available > 0 else { return Array(repeating: [], count: format.channelCount) }

        try handle.seek(toOffset: audioDataOffset + UInt64(max(0, startFrame)) * UInt64(format.bytesPerFrame))
        let byteCount = available * format.bytesPerFrame
        let raw = try handle.read(upToCount: byteCount) ?? Data()
        let frames = raw.count / format.bytesPerFrame
        return decode(raw, frames: frames)
    }

    private func decode(_ raw: Data, frames: Int) -> [[Float]] {
        var channels = Array(repeating: [Float](repeating: 0, count: frames), count: format.channelCount)
        guard frames > 0 else { return channels }
        let stride = format.bytesPerFrame
        let width = format.bytesPerSample
        raw.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            for frame in 0..<frames {
                for channel in 0..<format.channelCount {
                    let offset = frame * stride + channel * width
                    channels[channel][frame] = Self.sample(buffer, at: offset, format: format)
                }
            }
        }
        return channels
    }

    private static func sample(_ buffer: UnsafeRawBufferPointer, at offset: Int, format: CaptureAudioFormat) -> Float {
        if format.isFloat {
            return format.bitsPerChannel == 32
                ? buffer.loadUnaligned(fromByteOffset: offset, as: Float.self)
                : Float(buffer.loadUnaligned(fromByteOffset: offset, as: Double.self))
        }
        switch format.bitsPerChannel {
        case 8:
            return Float(Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt8.self)) - 128) / 128
        case 16:
            return Float(buffer.loadUnaligned(fromByteOffset: offset, as: Int16.self)) / 32_768
        case 24:
            let low = Int32(buffer.loadUnaligned(fromByteOffset: offset, as: UInt8.self))
            let mid = Int32(buffer.loadUnaligned(fromByteOffset: offset + 1, as: UInt8.self))
            let high = Int32(buffer.loadUnaligned(fromByteOffset: offset + 2, as: UInt8.self))
            let raw = low | mid << 8 | high << 16
            let signed = raw & 0x80_0000 != 0 ? raw - 0x100_0000 : raw
            return Float(signed) / 8_388_608
        default:
            return Float(buffer.loadUnaligned(fromByteOffset: offset, as: Int32.self)) / 2_147_483_648
        }
    }
}

private extension Data {
    func uint32(at offset: Int) -> UInt32 {
        let base = startIndex + offset
        return (UInt32(self[base]) << 24) | (UInt32(self[base + 1]) << 16) | (UInt32(self[base + 2]) << 8) | UInt32(self[base + 3])
    }

    func int64(at offset: Int) -> Int64 {
        let base = startIndex + offset
        var value: UInt64 = 0
        for byte in 0..<8 { value = (value << 8) | UInt64(self[base + byte]) }
        return Int64(bitPattern: value)
    }

    func double(at offset: Int) -> Double {
        let base = startIndex + offset
        var value: UInt64 = 0
        for byte in 0..<8 { value = (value << 8) | UInt64(self[base + byte]) }
        return Double(bitPattern: value)
    }

    func ascii(at offset: Int, count: Int) -> String {
        let base = startIndex + offset
        return String(decoding: self[base..<(base + count)], as: UTF8.self)
    }
}
