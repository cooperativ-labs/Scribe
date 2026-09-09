import AVFAudio
import AudioToolbox
import Foundation
import Testing

@testable import FLACBridge

@Suite("AAC M4A encoder")
struct AACM4AEncoderTests {
    @Test("publishes AAC-LC in an MPEG-4 audio container with decoder-tolerant timing")
    func encodesAACM4A() throws {
        let root = try workspace("encode")
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("final.m4a")
        let frames = 48_003 // deliberately not an AAC 1,024-sample packet boundary
        let result = try encodeTone(to: output, frames: frames)

        #expect(result.url == output)
        #expect(result.sampleRate == 48_000)
        #expect(result.channelCount == 1)
        #expect(result.bitRate == 64_000)
        #expect(result.frameCount == Int64(frames))
        #expect(abs(result.decodedFrameCount - Int64(frames)) <= AACM4AEncoder.maximumTimingErrorFrames)
        let checksum = try AACM4AEncoder.sha256(ofFileAt: output)
        #expect(result.sha256 == checksum)
        let bytes = try Data(contentsOf: output)
        #expect(bytes.count > 12)
        #expect(Data(bytes[4..<8]) == Data("ftyp".utf8))

        let reader = try AVAudioFile(forReading: output, commonFormat: .pcmFormatFloat32, interleaved: false)
        #expect(reader.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC)
        #expect(reader.fileFormat.sampleRate == 48_000)
        #expect(reader.fileFormat.channelCount == 1)
        #expect(abs(reader.length - Int64(frames)) <= AACM4AEncoder.maximumTimingErrorFrames)
        // This is a lossy quality gate, not FLAC's former bit-exact gate: the
        // decoded signal remains non-silent and has usable speech-band energy.
        let buffer = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: AVAudioFrameCount(reader.length))!
        try reader.read(into: buffer)
        let peak = (0..<Int(buffer.frameLength)).reduce(Float.zero) { max($0, abs(buffer.floatChannelData![0][$1])) }
        #expect(peak > 0.05)
    }

    @Test("failed verification preserves a valid final and removes its temporary sibling")
    func failureDoesNotReplaceExistingOutput() throws {
        let root = try workspace("preserve")
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("final.m4a")
        let good = try encodeTone(to: output, frames: 48_000)
        let rerun = try AACM4AEncoder(outputURL: output, sampleRate: 48_000, channelCount: 1)
        try writeTone(to: rerun, frames: 12_000)
        rerun.testHooks.afterFinalize = { url in try Data().write(to: url) }

        #expect(throws: AACM4AEncoderError.self) { try rerun.finish() }
        #expect(try AACM4AEncoder.sha256(ofFileAt: output) == good.sha256)
        #expect(!FileManager.default.fileExists(atPath: rerun.temporaryURL.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["final.m4a"])
    }

    @Test("cancellation removes an incomplete M4A without publishing")
    func cancellationCleansUp() throws {
        let root = try workspace("cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("final.m4a")
        let encoder = try AACM4AEncoder(outputURL: output, sampleRate: 48_000, channelCount: 1)
        try writeTone(to: encoder, frames: 4_000)
        encoder.cancel()
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(!FileManager.default.fileExists(atPath: encoder.temporaryURL.path))
        #expect(throws: AACM4AEncoderError.self) { try encoder.finish() }
    }
}

private func workspace(_ name: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AACM4AEncoderTests-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func encodeTone(to output: URL, frames: Int) throws -> AACM4AEncodeResult {
    let encoder = try AACM4AEncoder(outputURL: output, sampleRate: 48_000, channelCount: 1)
    try writeTone(to: encoder, frames: frames)
    return try encoder.finish()
}

private func writeTone(to encoder: AACM4AEncoder, frames: Int) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    var offset = 0
    while offset < frames {
        let count = min(997, frames - offset)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        for frame in 0..<count { buffer.floatChannelData![0][frame] = sin(Float(offset + frame) * 0.029) * 0.35 }
        try encoder.write(buffer)
        offset += count
    }
}
