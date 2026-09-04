import AVFAudio
import CryptoKit
import Foundation
import Testing

@testable import FLACBridge

/// A temporary directory that is removed when the test finishes.
private struct Workspace: ~Copyable {
    let url: URL

    init(_ name: String) throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FLACBridgeTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Everything in the directory, including the hidden temporary files the encoder writes.
    func contents() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Deterministic input that exercises exact integer values, half-LSB rounding
/// boundaries, and near-full-scale values inside the Float32 input domain.
private func inputSample(frame: Int, channel: Int, bitDepth: FLACBitDepth) -> Float {
    let scale = Float(bitDepth.scale)
    let span = Int32(bitDepth.scale)
    let sequence = Int32(truncatingIfNeeded: (frame &* 1_103_515_245 &+ channel &* 12_345) & 0x00FF_FFFF)
    let centered = (sequence % (2 &* span)) - span
    let fractionalLSB: Float = switch frame % 5 {
    case 0: -0.5001
    case 1: -0.4999
    case 2: 0
    case 3: 0.4999
    default: 0.5001
    }
    return min(1, max(-1, (Float(centered) + fractionalLSB) / scale))
}

private func expectedSample(frame: Int, channel: Int, bitDepth: FLACBitDepth) -> Int32 {
    let scale = Float(bitDepth.scale)
    let clipped = min(1, max(-1, inputSample(frame: frame, channel: channel, bitDepth: bitDepth)))
    let rounded = Int32((clipped * scale).rounded(.toNearestOrAwayFromZero))
    return min(bitDepth.maximumSample, max(bitDepth.minimumSample, rounded))
}

/// Feeds `frameCount` frames of the deterministic signal through the encoder in
/// chunks that leave a partial final block.
@discardableResult
private func encodeFixture(
    to url: URL,
    configuration: FLACEncoderConfiguration,
    frameCount: Int,
    chunk: Int = 1_023,
    beforeFinish: ((FLACEncoder) throws -> Void)? = nil
) throws -> FLACEncodeResult {
    let encoder = try FLACEncoder(outputURL: url, configuration: configuration)
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(configuration.sampleRate),
        channels: AVAudioChannelCount(configuration.channelCount),
        interleaved: false
    )!
    var offset = 0
    while offset < frameCount {
        let count = min(chunk, frameCount - offset)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        for channel in 0..<configuration.channelCount {
            let samples = buffer.floatChannelData![channel]
            for frame in 0..<count {
                samples[frame] = inputSample(frame: offset + frame, channel: channel, bitDepth: configuration.bitDepth)
            }
        }
        try encoder.write(buffer)
        offset += count
    }
    try beforeFinish?(encoder)
    return try encoder.finish()
}

/// Decodes a published file independently of the encoder's own verification pass.
private func decodeIntegerSamples(at url: URL, bitDepth: FLACBitDepth) throws -> (frames: Int64, samples: [[Int32]]) {
    let reader = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    let channels = Int(reader.fileFormat.channelCount)
    var decoded = [[Int32]](repeating: [], count: channels)
    let scale = Float(bitDepth.scale)
    var frames: Int64 = 0
    while frames < reader.length {
        let requested = AVAudioFrameCount(min(4_096, reader.length - frames))
        let buffer = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: requested)!
        try reader.read(into: buffer, frameCount: requested)
        guard buffer.frameLength > 0 else { break }
        for channel in 0..<channels {
            let samples = buffer.floatChannelData![channel]
            for frame in 0..<Int(buffer.frameLength) {
                let clipped = min(1, max(-1, samples[frame]))
                let rounded = Int32((clipped * scale).rounded(.toNearestOrAwayFromZero))
                decoded[channel].append(min(bitDepth.maximumSample, max(bitDepth.minimumSample, rounded)))
            }
        }
        frames += Int64(buffer.frameLength)
    }
    return (frames, decoded)
}

@Suite("FLAC encoder")
struct FLACEncoderTests {
    static let matrix: [(rate: Int, channels: Int, depth: FLACBitDepth)] = {
        var cases: [(Int, Int, FLACBitDepth)] = []
        for rate in [44_100, 48_000, 96_000] {
            for channels in [1, 2] {
                for depth in FLACBitDepth.allCases {
                    cases.append((rate, channels, depth))
                }
            }
        }
        return cases
    }()

    @Test("decodes back to the exact integer PCM it was given", arguments: matrix)
    func decodeRoundTrip(rate: Int, channels: Int, depth: FLACBitDepth) throws {
        let workspace = try Workspace("roundtrip-\(rate)-\(channels)-\(depth.rawValue)")
        let output = workspace.url.appendingPathComponent("system.flac")
        let configuration = FLACEncoderConfiguration(sampleRate: rate, channelCount: channels, bitDepth: depth)
        #expect(configuration.isValidated)

        let frameCount = 20_479 // not a multiple of any FLAC block size
        let result = try encodeFixture(to: output, configuration: configuration, frameCount: frameCount)

        #expect(result.url == output)
        #expect(result.frameCount == Int64(frameCount))
        #expect(result.sampleRate == rate)
        #expect(result.channelCount == channels)
        #expect(result.bitDepth == depth)
        #expect(result.streamInfo.bitsPerSample == depth.rawValue)
        #expect(result.streamInfo.sampleRate == rate)
        #expect(result.streamInfo.channelCount == channels)
        #expect(result.streamInfo.totalFrames == UInt64(frameCount))
        #expect(try workspace.contents() == ["system.flac"])

        let decoded = try decodeIntegerSamples(at: output, bitDepth: depth)
        #expect(decoded.frames == Int64(frameCount))
        for channel in 0..<channels {
            #expect(decoded.samples[channel].count == frameCount)
            var mismatches = 0
            var firstMismatch: String?
            for frame in 0..<frameCount {
                let expected = expectedSample(frame: frame, channel: channel, bitDepth: depth)
                if decoded.samples[channel][frame] != expected {
                    mismatches += 1
                    if firstMismatch == nil {
                        firstMismatch = "frame \(frame) channel \(channel): expected \(expected), got \(decoded.samples[channel][frame])"
                    }
                }
            }
            #expect(mismatches == 0, "\(mismatches) mismatched samples; first was \(firstMismatch ?? "none")")
        }
    }

    @Test("reports the checksum and size of the published file")
    func checksumMatchesPublishedBytes() throws {
        let workspace = try Workspace("checksum")
        let output = workspace.url.appendingPathComponent("microphone.flac")
        let result = try encodeFixture(
            to: output,
            configuration: FLACEncoderConfiguration(sampleRate: 48_000, channelCount: 1),
            frameCount: 12_345
        )

        let bytes = try Data(contentsOf: output)
        let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(result.sha256 == expected)
        #expect(result.sha256.count == 64)
        #expect(result.byteCount == UInt64(bytes.count))
        #expect(try FLACEncoder.sha256(ofFileAt: output) == expected)
    }

    @Test("keeps the exact duration when the final block is partial")
    func durationSurvivesPartialFinalBlock() throws {
        let workspace = try Workspace("duration")
        let output = workspace.url.appendingPathComponent("final.flac")
        // 480,003 frames written 1,023 at a time: neither is a FLAC block size, so
        // finalization must flush a partial block and must not pad it out.
        let frameCount = 480_003
        let result = try encodeFixture(
            to: output,
            configuration: FLACEncoderConfiguration(sampleRate: 48_000, channelCount: 2),
            frameCount: frameCount,
            chunk: 1_023
        )

        #expect(result.frameCount == Int64(frameCount))
        #expect(result.streamInfo.totalFrames == UInt64(frameCount))
        #expect(abs(result.duration - Double(frameCount) / 48_000) < 1e-12)

        let reader = try AVAudioFile(forReading: output)
        #expect(reader.length == Int64(frameCount))
        #expect(reader.fileFormat.sampleRate == 48_000)
        #expect(reader.fileFormat.channelCount == 2)
    }

    @Test("accepts Int16, Int32, and interleaved buffers")
    func acceptsIntegerAndInterleavedInput() throws {
        let workspace = try Workspace("integer-input")
        let configuration = FLACEncoderConfiguration(sampleRate: 48_000, channelCount: 2)
        let frames = 5_001 // above the encoder's packet floor, with a partial final packet
        let planar = AVAudioFormat(commonFormat: .pcmFormatInt32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let interleaved = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 2, interleaved: true)!

        // Int32 input is left-aligned in 32 bits; Int16 input scales up to 24 bits.
        func expected(frame: Int, channel: Int) -> Int32 { Int32((frame &* 7 &+ channel &* 3) % 30_000) - 15_000 }

        let int32Output = workspace.url.appendingPathComponent("int32.flac")
        let int32Encoder = try FLACEncoder(outputURL: int32Output, configuration: configuration)
        let int32Buffer = AVAudioPCMBuffer(pcmFormat: planar, frameCapacity: AVAudioFrameCount(frames))!
        int32Buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<2 {
            for frame in 0..<frames {
                int32Buffer.int32ChannelData![channel][frame] = expected(frame: frame, channel: channel) << 8
            }
        }
        try int32Encoder.write(int32Buffer)
        print("DBG int32 temp size", (try? FileManager.default.attributesOfItem(atPath: int32Encoder.temporaryURL.path)[.size]) ?? "none", int32Encoder.temporaryURL.lastPathComponent)
        let int32Result = try int32Encoder.finish()
        #expect(int32Result.frameCount == Int64(frames))

        let int16Output = workspace.url.appendingPathComponent("int16.flac")
        let int16Encoder = try FLACEncoder(outputURL: int16Output, configuration: configuration)
        let int16Buffer = AVAudioPCMBuffer(pcmFormat: interleaved, frameCapacity: AVAudioFrameCount(frames))!
        int16Buffer.frameLength = AVAudioFrameCount(frames)
        for frame in 0..<frames {
            for channel in 0..<2 {
                // Int16 samples become 24-bit samples shifted up by 8 bits.
                int16Buffer.int16ChannelData![0][frame * 2 + channel] = Int16(expected(frame: frame, channel: channel) >> 8)
            }
        }
        try int16Encoder.write(int16Buffer)
        print("DBG int16 temp size", (try? FileManager.default.attributesOfItem(atPath: int16Encoder.temporaryURL.path)[.size]) ?? "none", int16Encoder.temporaryURL.lastPathComponent)
        let int16Result = try int16Encoder.finish()
        #expect(int16Result.frameCount == Int64(frames))

        // Both paths verified internally; confirm the Int32 payload independently.
        let decoded = try decodeIntegerSamples(at: int32Output, bitDepth: .bits24)
        for channel in 0..<2 {
            for frame in 0..<frames {
                #expect(decoded.samples[channel][frame] == expected(frame: frame, channel: channel))
            }
        }
    }

    @Test("rejects buffers that do not match the configured format")
    func rejectsMismatchedBuffers() throws {
        let workspace = try Workspace("mismatch")
        let output = workspace.url.appendingPathComponent("system.flac")
        let encoder = try FLACEncoder(
            outputURL: output,
            configuration: FLACEncoderConfiguration(sampleRate: 48_000, channelCount: 2)
        )
        let wrongRate = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: wrongRate, frameCapacity: 128)!
        buffer.frameLength = 128
        #expect(throws: FLACEncoderError.self) { try encoder.write(buffer) }
        encoder.cancel()
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(try workspace.contents().isEmpty)
    }

    @Test("encodes exactly one packet but reports anything shorter")
    func honoursThePacketFloor() throws {
        let workspace = try Workspace("packet-floor")
        let configuration = FLACEncoderConfiguration(sampleRate: 48_000, channelCount: 1)
        let floor = Int(FLACEncoderConfiguration.minimumFrameCount)

        // Exactly one packet is the shortest file the system encoder can produce.
        let shortest = workspace.url.appendingPathComponent("shortest.flac")
        let result = try encodeFixture(to: shortest, configuration: configuration, frameCount: floor, chunk: 1_023)
        #expect(result.frameCount == Int64(floor))

        // One frame less produces a 42-byte stub with no fLaC magic number, which
        // must be reported rather than published.
        let tooShort = workspace.url.appendingPathComponent("too-short.flac")
        let encoder = try FLACEncoder(outputURL: tooShort, configuration: configuration)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(floor - 1))!
        buffer.frameLength = AVAudioFrameCount(floor - 1)
        try encoder.write(buffer)
        #expect {
            try encoder.finish()
        } throws: { error in
            guard case FLACEncoderError.streamTooShort(let frames, let minimum) = error else { return false }
            return frames == Int64(floor - 1) && minimum == FLACEncoderConfiguration.minimumFrameCount
        }
        #expect(!FileManager.default.fileExists(atPath: tooShort.path))
        #expect(try workspace.contents() == ["shortest.flac"])
    }

    @Test("refuses to write into a directory that does not exist")
    func requiresDestinationDirectory() throws {
        let workspace = try Workspace("missing-directory")
        let output = workspace.url.appendingPathComponent("nope/system.flac")
        #expect(throws: FLACEncoderError.self) {
            try FLACEncoder(outputURL: output, configuration: FLACEncoderConfiguration(sampleRate: 48_000, channelCount: 1))
        }
    }
}

@Suite("FLAC publication safety")
struct FLACPublicationTests {
    @Test("the final name appears only after finalization and verification")
    func finalNameAppearsOnlyAtTheEnd() throws {
        let workspace = try Workspace("publish-order")
        let output = workspace.url.appendingPathComponent("system.flac")
        let configuration = FLACEncoderConfiguration(sampleRate: 48_000, channelCount: 1)

        let result = try encodeFixture(to: output, configuration: configuration, frameCount: 8_191) { encoder in
            // Mid-encode: audio has been written, but only to the temporary sibling.
            #expect(!FileManager.default.fileExists(atPath: output.path))
            #expect(FileManager.default.fileExists(atPath: encoder.temporaryURL.path))
            #expect(encoder.temporaryURL.lastPathComponent.hasPrefix("."))
            #expect(encoder.framesWritten == 8_191)
        }

        #expect(FileManager.default.fileExists(atPath: result.url.path))
        #expect(try workspace.contents() == ["system.flac"])
    }

    @Test("a partially written temporary file never appears under the final name")
    func failedVerificationPublishesNothing() throws {
        let workspace = try Workspace("verification-failure")
        let output = workspace.url.appendingPathComponent("system.flac")
        let configuration = FLACEncoderConfiguration(sampleRate: 48_000, channelCount: 2)
        let encoder = try FLACEncoder(outputURL: output, configuration: configuration)

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192)!
        buffer.frameLength = 8_192
        for channel in 0..<2 {
            for frame in 0..<8_192 {
                buffer.floatChannelData![channel][frame] = inputSample(frame: frame, channel: channel, bitDepth: .bits24)
            }
        }
        try encoder.write(buffer)

        // Stand in for a crash or a full disk during finalization: the temporary
        // file exists and holds a truncated, unusable stream.
        var truncatedSize = 0
        encoder.testHooks.afterFinalize = { url in
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64 ?? 0
            truncatedSize = Int(size / 2)
            try handle.truncate(atOffset: UInt64(truncatedSize))
        }

        #expect(throws: FLACEncoderError.self) { try encoder.finish() }
        #expect(truncatedSize > 0, "the encoder should have produced a temporary file to truncate")

        // Nothing published, and no partial file left anywhere in the directory.
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(!FileManager.default.fileExists(atPath: encoder.temporaryURL.path))
        #expect(try workspace.contents().isEmpty)
    }

    @Test("a failed encode leaves an existing published file untouched")
    func failureDoesNotDisturbAnExistingFile() throws {
        let workspace = try Workspace("existing-file")
        let output = workspace.url.appendingPathComponent("final.flac")
        let configuration = FLACEncoderConfiguration(sampleRate: 48_000, channelCount: 1)

        let original = try encodeFixture(to: output, configuration: configuration, frameCount: 6_000)

        let rerun = try FLACEncoder(outputURL: output, configuration: configuration)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 5_000)!
        buffer.frameLength = 5_000
        try rerun.write(buffer)
        rerun.testHooks.afterFinalize = { url in try Data().write(to: url) }
        #expect(throws: FLACEncoderError.self) { try rerun.finish() }

        #expect(try FLACEncoder.sha256(ofFileAt: output) == original.sha256)
        #expect(try workspace.contents() == ["final.flac"])
    }

    @Test("a cancelled or abandoned encoder leaves nothing behind")
    func abandonedEncoderCleansUp() throws {
        let workspace = try Workspace("abandoned")
        let output = workspace.url.appendingPathComponent("system.flac")
        let configuration = FLACEncoderConfiguration(sampleRate: 44_100, channelCount: 1)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false)!

        do {
            let encoder = try FLACEncoder(outputURL: output, configuration: configuration)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_048)!
            buffer.frameLength = 2_048
            try encoder.write(buffer)
            encoder.cancel()
            #expect(!FileManager.default.fileExists(atPath: encoder.temporaryURL.path))
            #expect(throws: FLACEncoderError.self) { try encoder.finish() }
        }
        #expect(try workspace.contents().isEmpty)

        // The same must hold when the encoder is simply dropped, as it would be if
        // the process unwound through an error path without calling finish().
        var droppedTemporaryURL: URL?
        do {
            let encoder = try FLACEncoder(outputURL: output, configuration: configuration)
            droppedTemporaryURL = encoder.temporaryURL
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_048)!
            buffer.frameLength = 2_048
            try encoder.write(buffer)
        }
        #expect(!FileManager.default.fileExists(atPath: droppedTemporaryURL!.path))
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(try workspace.contents().isEmpty)
    }
}
