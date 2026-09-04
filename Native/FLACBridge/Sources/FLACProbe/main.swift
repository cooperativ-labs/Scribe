import AVFAudio
import AudioToolbox
import Foundation

/// A device-independent feasibility probe for the system FLAC writer.
///
/// Input is Float32. The expected 24-bit integer value is produced by clamping
/// to [-1, 1], multiplying by 2^23, using `.toNearestOrAwayFromZero`, and then
/// clamping the result to [-2^23, 2^23 - 1]. Decoded Float32 samples are quantized by that
/// same rule before comparison, so the check is against the 24-bit PCM payload,
/// not a lossy Float32 bit-pattern comparison.
enum FLACProbe {
    static let scale = Float(8_388_608)
    static let frameCount: AVAudioFrameCount = 480_003 // ten seconds at 48 kHz; deliberately not a typical FLAC block size
    static let writeChunk: AVAudioFrameCount = 1_023 // leaves a final partial write

    struct Result: Codable {
        let sampleRate: Int
        let channels: Int
        let inputFrames: Int
        let decodedFrames: Int64
        let decodedSampleRate: Double
        let decodedChannels: Int
        let fileFormatID: UInt32
        let encodedBitDepth: UInt32
        let streamInfoFrames: UInt64
        let mismatchCount: Int
        let firstMismatch: String?
        let encodeSeconds: Double
        let timesRealTime: Double
        let fileBytes: UInt64

        var passed: Bool {
            decodedFrames == Int64(inputFrames)
                && abs(decodedSampleRate - Double(sampleRate)) < 0.001
                && decodedChannels == channels
                && mismatchCount == 0
                && fileFormatID == kAudioFormatFLAC
                && encodedBitDepth == 24
                && streamInfoFrames == UInt64(inputFrames)
        }
    }

    static func quantize24(_ sample: Float) -> Int32 {
        let clipped = min(1, max(-1, sample))
        let rounded = Int32((clipped * scale).rounded(.toNearestOrAwayFromZero))
        return min(8_388_607, max(-8_388_608, rounded))
    }

    static func inputSample(frame: Int, channel: Int) -> Float {
        // Exercises exact integer values, values around 0.5 LSB boundaries, and
        // near-full-scale values while staying inside the Float32 input domain.
        let sequence = (frame &* 1_103_515_245 &+ channel &* 12_345) & 0x00FF_FFFF
        let centered = Int32(sequence) - 8_388_608
        let fractionalLSB: Float = switch frame % 5 {
        case 0: -0.5001
        case 1: -0.4999
        case 2: 0
        case 3: 0.4999
        default: 0.5001
        }
        return (Float(centered) + fractionalLSB) / scale
    }

    static func streamInfo(at url: URL) throws -> (bitDepth: UInt32, frames: UInt64) {
        let bytes = Array(try Data(contentsOf: url))
        guard bytes.count >= 42, Array(bytes[0..<4]) == [0x66, 0x4C, 0x61, 0x43], bytes[4] & 0x7F == 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // STREAMINFO packs sample rate (20 bits), channels minus one (3 bits),
        // bits per sample minus one (5 bits), and total samples (36 bits).
        var packed: UInt64 = 0
        for byte in bytes[18..<26] { packed = (packed << 8) | UInt64(byte) }
        return (UInt32((packed >> 36) & 0x1F) + 1, packed & 0x0000_000F_FFFF_FFFF)
    }

    static func run(sampleRate: Int, channels: Int, directory: URL) throws -> Result {
        let url = directory.appendingPathComponent("system-\(sampleRate)-\(channels)ch.flac")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: Double(sampleRate),
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let writeFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt32,
            sampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(channels),
            interleaved: false
        )!
        let start = ContinuousClock.now
        let fileFormat: AudioStreamBasicDescription = try {
            var writer: AVAudioFile? = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt32, interleaved: false)
            var offset: AVAudioFrameCount = 0
            while offset < frameCount {
                let count = min(writeChunk, frameCount - offset)
                let buffer = AVAudioPCMBuffer(pcmFormat: writeFormat, frameCapacity: count)!
                buffer.frameLength = count
                for channel in 0..<channels {
                    let samples = buffer.int32ChannelData![channel]
                    for frame in 0..<Int(count) {
                        // AVAudioPCMBuffer represents 24 valid bits in an Int32
                        // container left-aligned, matching AudioToolbox PCM.
                        samples[frame] = quantize24(inputSample(frame: Int(offset) + frame, channel: channel)) << 8
                    }
                }
                try writer!.write(from: buffer)
                offset += count
            }
            let format = writer!.fileFormat.streamDescription.pointee
            // Finalization is part of encoder timing, including the partial block.
            writer = nil
            return format
        }()
        let elapsed = start.duration(to: .now).components
        let encodeSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1_000_000_000_000_000_000
        let streamInfo = try streamInfo(at: url)

        let reader = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let readFormat = reader.processingFormat
        var decodedFrames: Int64 = 0
        var mismatches = 0
        var firstMismatch: String?
        while decodedFrames < reader.length {
            let requested = AVAudioFrameCount(min(Int64(writeChunk), reader.length - decodedFrames))
            let buffer = AVAudioPCMBuffer(pcmFormat: readFormat, frameCapacity: requested)!
            try reader.read(into: buffer, frameCount: requested)
            guard buffer.frameLength > 0 else { break }
            for channel in 0..<channels {
                let samples = buffer.floatChannelData![channel]
                for frame in 0..<Int(buffer.frameLength) {
                    let expected = quantize24(inputSample(frame: Int(decodedFrames) + frame, channel: channel))
                    let actual = quantize24(samples[frame])
                    if expected != actual {
                        mismatches += 1
                        if firstMismatch == nil {
                            firstMismatch = "frame \(decodedFrames + Int64(frame)), channel \(channel): expected \(expected), got \(actual)"
                        }
                    }
                }
            }
            decodedFrames += Int64(buffer.frameLength)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return Result(
            sampleRate: sampleRate,
            channels: channels,
            inputFrames: Int(frameCount),
            decodedFrames: decodedFrames,
            decodedSampleRate: reader.fileFormat.sampleRate,
            decodedChannels: Int(reader.fileFormat.channelCount),
            fileFormatID: fileFormat.mFormatID,
            encodedBitDepth: streamInfo.bitDepth,
            streamInfoFrames: streamInfo.frames,
            mismatchCount: mismatches,
            firstMismatch: firstMismatch,
            encodeSeconds: encodeSeconds,
            timesRealTime: (Double(frameCount) / Double(sampleRate)) / encodeSeconds,
            fileBytes: (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        )
    }
}

do {
    let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/flac-probe", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    var results: [FLACProbe.Result] = []
    for rate in [44_100, 48_000, 96_000] {
        for channels in [1, 2] {
            results.append(try FLACProbe.run(sampleRate: rate, channels: channels, directory: output))
        }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(results), as: UTF8.self))
    guard results.allSatisfy(\.passed) else { exit(1) }
} catch {
    fputs("FLACProbe failed: \(error)\n", stderr)
    exit(1)
}
