import AVFoundation
import XCTest
@testable import Transcription

@MainActor
final class TranscriptPlaybackTests: XCTestCase {
    func testFLACRandomAccessReturnsTheAudioAtTheTranscriptTimestamp() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-playback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("variable-bitrate.flac")
        let sampleRate = 48_000
        let samples = try writeFLAC(to: source, sampleRate: sampleRate)

        let playback = AVFoundationTranscriptPlayback()
        playback.load(sourceSnapshotURL: source)
        let item = try XCTUnwrap(playback.player.currentItem)
        let tracks = try await item.asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)

        // Check decoded content, not just the reported seek time: approximate
        // FLAC access can return the wrong audio stamped with the requested PTS.
        // Deliberately visit late, early, and non-frame-aligned positions.
        for milliseconds in [57_123, 12_345, 37_777, 2_468, 0] {
            let reader = try AVAssetReader(asset: item.asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
            reader.add(output)
            reader.timeRange = CMTimeRange(
                start: CMTime(value: Int64(milliseconds), timescale: 1_000),
                duration: CMTime(value: 1, timescale: 1)
            )
            XCTAssertTrue(reader.startReading())
            var decoded = Data()
            while let buffer = output.copyNextSampleBuffer() {
                let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(buffer))
                var bytes = Data(count: CMBlockBufferGetDataLength(block))
                let status = bytes.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
                }
                XCTAssertEqual(status, kCMBlockBufferNoErr)
                decoded.append(bytes)
            }
            XCTAssertEqual(reader.status, .completed, "\(String(describing: reader.error))")
            let startFrame = milliseconds * sampleRate / 1_000
            let expected = Array(samples[startFrame..<(startFrame + sampleRate)]).withUnsafeBytes { Data($0) }
            XCTAssertEqual(decoded.count, expected.count)
            XCTAssertTrue(decoded == expected, "Wrong audio at \(milliseconds) ms")
        }
        playback.player.replaceCurrentItem(with: nil)
    }

    /// Changing compressibility prevents a byte-offset estimate from being an
    /// adequate substitute for a sample index, as in a meeting with quiet turns.
    private func writeFLAC(to url: URL, sampleRate: Int) throws -> [Int16] {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ))
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: Double(sampleRate),
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
        ], commonFormat: .pcmFormatInt16, interleaved: false)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate)))
        buffer.frameLength = buffer.frameCapacity
        var samples: [Int16] = []
        samples.reserveCapacity(sampleRate * 60)
        var random: UInt32 = 42
        for second in 0..<60 {
            let channel = try XCTUnwrap(buffer.int16ChannelData)[0]
            for frame in 0..<sampleRate {
                random = random &* 1_664_525 &+ 1_013_904_223
                let noise = Int16(truncatingIfNeeded: random >> 16)
                let sample = second % 10 < 7 ? noise / 256 : noise
                channel[frame] = sample
                samples.append(sample)
            }
            try file.write(from: buffer)
        }
        // The writer leaves scope and finalizes STREAMINFO before playback opens it.
        return samples
    }
}
