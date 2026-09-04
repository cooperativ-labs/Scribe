import Foundation

/// Minimal PCM WAV reading and writing, matching what the fixture suite and
/// `Tools/AudioMetrics` use. Foundation only, so the harness needs no packages.
public struct WAVAudio: Sendable {
    public let sampleRate: Int
    public let channels: [[Float]]

    public init(sampleRate: Int, channels: [[Float]]) {
        self.sampleRate = sampleRate
        self.channels = channels
    }

    public var frameCount: Int { channels.first?.count ?? 0 }
    public var channelCount: Int { channels.count }

    public static func read(contentsOf url: URL) throws -> WAVAudio {
        let bytes = [UInt8](try Data(contentsOf: url))
        guard bytes.count >= 12, ascii(bytes, 0, 4) == "RIFF", ascii(bytes, 8, 4) == "WAVE" else {
            throw HarnessError.message("\(url.lastPathComponent) is not a RIFF/WAVE file")
        }
        var code = 1, channelCount = 0, sampleRate = 0, bits = 0
        var payload: ArraySlice<UInt8>?
        var offset = 12
        while offset + 8 <= bytes.count {
            let id = ascii(bytes, offset, 4)
            let declared = Int(uint32(bytes, offset + 4))
            let start = offset + 8
            let size = min(declared, bytes.count - start)
            if id == "fmt " && size >= 16 {
                code = Int(uint16(bytes, start))
                channelCount = Int(uint16(bytes, start + 2))
                sampleRate = Int(uint32(bytes, start + 4))
                bits = Int(uint16(bytes, start + 14))
                if code == 0xFFFE, size >= 40 { code = Int(uint16(bytes, start + 24)) }
            } else if id == "data" {
                payload = bytes[start..<(start + size)]
            }
            offset = start + declared + (declared % 2)
        }
        guard let payload, channelCount > 0, sampleRate > 0, bits % 8 == 0, bits > 0 else {
            throw HarnessError.message("\(url.lastPathComponent) has no usable fmt/data chunk")
        }
        let width = bits / 8
        let stride = width * channelCount
        let frames = payload.count / stride
        var channels = Array(repeating: [Float](repeating: 0, count: frames), count: channelCount)
        let base = payload.startIndex
        for frame in 0..<frames {
            for channel in 0..<channelCount {
                let index = base + frame * stride + channel * width
                channels[channel][frame] = decode(payload, index, code: code, bits: bits)
            }
        }
        return WAVAudio(sampleRate: sampleRate, channels: channels)
    }

    /// Writes 32-bit float WAV, which keeps the harness's own output free of any
    /// quantization the measurement could mistake for a reconstruction error.
    public func write(to url: URL) throws {
        var data = Data()
        let channelCount = max(1, self.channelCount)
        let byteCount = frameCount * channelCount * 4
        data.appendASCII("RIFF"); data.appendUInt32LE(UInt32(36 + byteCount)); data.appendASCII("WAVE")
        data.appendASCII("fmt "); data.appendUInt32LE(16)
        data.appendUInt16LE(3) // IEEE float
        data.appendUInt16LE(UInt16(channelCount))
        data.appendUInt32LE(UInt32(sampleRate))
        data.appendUInt32LE(UInt32(sampleRate * channelCount * 4))
        data.appendUInt16LE(UInt16(channelCount * 4))
        data.appendUInt16LE(32)
        data.appendASCII("data"); data.appendUInt32LE(UInt32(byteCount))
        for frame in 0..<frameCount {
            for channel in 0..<channelCount {
                data.appendUInt32LE(channels[channel][frame].bitPattern)
            }
        }
        try data.write(to: url)
    }

    private static func decode(_ bytes: ArraySlice<UInt8>, _ index: Int, code: Int, bits: Int) -> Float {
        switch (code, bits) {
        case (1, 8): return (Float(bytes[index]) - 128) / 128
        case (1, 16): return Float(Int16(bitPattern: UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8)) / 32_768
        case (1, 24):
            let raw = Int32(bytes[index]) | Int32(bytes[index + 1]) << 8 | Int32(bytes[index + 2]) << 16
            return Float(raw & 0x80_0000 != 0 ? raw - 0x100_0000 : raw) / 8_388_608
        case (1, 32):
            var value: UInt32 = 0
            for byte in 0..<4 { value |= UInt32(bytes[index + byte]) << (8 * UInt32(byte)) }
            return Float(Int32(bitPattern: value)) / 2_147_483_648
        case (3, 32):
            var value: UInt32 = 0
            for byte in 0..<4 { value |= UInt32(bytes[index + byte]) << (8 * UInt32(byte)) }
            return Float(bitPattern: value)
        default: return 0
        }
    }
}

public enum HarnessError: Error, CustomStringConvertible {
    case message(String)
    public var description: String { switch self { case .message(let text): return text } }
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

extension Data {
    mutating func appendASCII(_ value: String) { append(contentsOf: Array(value.utf8)) }
    mutating func appendUInt16LE(_ value: UInt16) { append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)]) }
    mutating func appendUInt32LE(_ value: UInt32) {
        append(contentsOf: (0..<4).map { UInt8((value >> (8 * UInt32($0))) & 0xFF) })
    }
}
