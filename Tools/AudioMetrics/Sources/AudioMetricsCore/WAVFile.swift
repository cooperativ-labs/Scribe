import Foundation

/// A decoded PCM WAV file held as deinterleaved, normalized ``Double`` channels in -1...1.
public struct WAVFile: Sendable {
    public let sampleRate: Int
    public let channels: [[Double]]
    public let bitsPerSample: Int

    public init(sampleRate: Int, channels: [[Double]], bitsPerSample: Int = 16) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample
    }

    public var channelCount: Int { channels.count }
    public var frameCount: Int { channels.first?.count ?? 0 }
    public var durationSeconds: Double { sampleRate > 0 ? Double(frameCount) / Double(sampleRate) : 0 }

    /// Channel average. A mono file returns its only channel unchanged.
    public var mono: [Double] {
        guard channelCount > 1 else { return channels.first ?? [] }
        let scale = 1.0 / Double(channelCount)
        var result = Array(repeating: 0.0, count: frameCount)
        for channel in channels {
            for index in 0..<frameCount { result[index] += channel[index] * scale }
        }
        return result
    }
}

public enum WAVError: Error, CustomStringConvertible {
    case notRIFF(String)
    case missingChunk(String)
    case unsupported(String)
    case truncated(String)

    public var description: String {
        switch self {
        case .notRIFF(let path): return "\(path) is not a RIFF/WAVE file"
        case .missingChunk(let message): return message
        case .unsupported(let message): return message
        case .truncated(let message): return message
        }
    }
}

extension WAVFile {
    public static func read(contentsOf url: URL) throws -> WAVFile {
        let bytes = [UInt8](try Data(contentsOf: url))
        let path = url.lastPathComponent
        guard bytes.count >= 12, ascii(bytes, 0, 4) == "RIFF", ascii(bytes, 8, 4) == "WAVE" else {
            throw WAVError.notRIFF(path)
        }

        var format: (code: Int, channels: Int, sampleRate: Int, bits: Int)?
        var payload: ArraySlice<UInt8>?
        var offset = 12
        while offset + 8 <= bytes.count {
            let id = ascii(bytes, offset, 4)
            let declared = Int(uint32(bytes, offset + 4))
            let start = offset + 8
            let size = min(declared, bytes.count - start)
            guard size >= 0 else { throw WAVError.truncated("\(path) chunk \(id) is truncated") }
            switch id {
            case "fmt ":
                guard size >= 16 else { throw WAVError.truncated("\(path) has a short fmt chunk") }
                var code = Int(uint16(bytes, start))
                let channels = Int(uint16(bytes, start + 2))
                let rate = Int(uint32(bytes, start + 4))
                let bits = Int(uint16(bytes, start + 14))
                if code == 0xFFFE, size >= 40 { code = Int(uint16(bytes, start + 24)) }
                format = (code, channels, rate, bits)
            case "data":
                payload = bytes[start..<(start + size)]
            default:
                break
            }
            offset = start + declared + (declared % 2)
        }

        guard let format else { throw WAVError.missingChunk("\(path) has no fmt chunk") }
        guard let payload else { throw WAVError.missingChunk("\(path) has no data chunk") }
        guard format.channels > 0, format.sampleRate > 0 else {
            throw WAVError.unsupported("\(path) declares \(format.channels) channels at \(format.sampleRate) Hz")
        }

        let decode = try sampleDecoder(formatCode: format.code, bits: format.bits, path: path)
        let bytesPerSample = format.bits / 8
        let frameStride = bytesPerSample * format.channels
        guard frameStride > 0 else { throw WAVError.unsupported("\(path) declares \(format.bits)-bit samples") }
        let frames = payload.count / frameStride
        var channels = Array(repeating: Array(repeating: 0.0, count: frames), count: format.channels)
        let base = payload.startIndex
        for frame in 0..<frames {
            for channel in 0..<format.channels {
                let index = base + frame * frameStride + channel * bytesPerSample
                channels[channel][frame] = decode(payload, index)
            }
        }
        return WAVFile(sampleRate: format.sampleRate, channels: channels, bitsPerSample: format.bits)
    }

    private static func sampleDecoder(
        formatCode: Int,
        bits: Int,
        path: String
    ) throws -> (ArraySlice<UInt8>, Int) -> Double {
        switch (formatCode, bits) {
        case (1, 8):
            return { bytes, index in (Double(bytes[index]) - 128) / 128 }
        case (1, 16):
            return { bytes, index in
                Double(Int16(bitPattern: UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8)) / 32768
            }
        case (1, 24):
            return { bytes, index in
                let raw = Int32(bytes[index]) | Int32(bytes[index + 1]) << 8 | Int32(bytes[index + 2]) << 16
                let signed = raw & 0x80_0000 != 0 ? raw - 0x100_0000 : raw
                return Double(signed) / 8_388_608
            }
        case (1, 32):
            return { bytes, index in
                var value: UInt32 = 0
                for byte in 0..<4 { value |= UInt32(bytes[index + byte]) << (8 * UInt32(byte)) }
                return Double(Int32(bitPattern: value)) / 2_147_483_648
            }
        case (3, 32):
            return { bytes, index in
                var value: UInt32 = 0
                for byte in 0..<4 { value |= UInt32(bytes[index + byte]) << (8 * UInt32(byte)) }
                return Double(Float(bitPattern: value))
            }
        case (3, 64):
            return { bytes, index in
                var value: UInt64 = 0
                for byte in 0..<8 { value |= UInt64(bytes[index + byte]) << (8 * UInt64(byte)) }
                return Double(bitPattern: value)
            }
        default:
            throw WAVError.unsupported("\(path) uses unsupported format \(formatCode) at \(bits) bits")
        }
    }
}

private func ascii(_ bytes: [UInt8], _ offset: Int, _ count: Int) -> String {
    guard offset + count <= bytes.count else { return "" }
    return String(decoding: bytes[offset..<(offset + count)], as: UTF8.self)
}

private func uint16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
    guard offset + 2 <= bytes.count else { return 0 }
    return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
}

private func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    guard offset + 4 <= bytes.count else { return 0 }
    var value: UInt32 = 0
    for byte in 0..<4 { value |= UInt32(bytes[offset + byte]) << (8 * UInt32(byte)) }
    return value
}
