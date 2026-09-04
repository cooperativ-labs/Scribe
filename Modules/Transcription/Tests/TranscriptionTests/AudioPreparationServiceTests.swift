import AVFoundation
import Foundation
import XCTest
@testable import Transcription

final class AudioPreparationServiceTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var ffmpegURL: URL!
    private var fixtureEncoderURL: URL!
    private var ffprobeURL: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("Scribe Audio Preparation 🎧 \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        ffmpegURL = try findExecutable(named: "ffmpeg")
        fixtureEncoderURL = try findFixtureEncoder()
        ffprobeURL = try findExecutable(named: "ffprobe")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: temporaryDirectory) }

    func testDecodesEveryMatrixFormatAndRoundTripsSourceTimesWithinOneMillisecond() throws {
        let source = try writePCM(name: "source 日本語.wav", rate: 48_000, channels: 2)
        let formats: [(String, [String])] = [
            ("renamed WAV", ["-c:a", "pcm_s16le", "-f", "wav"]),
            ("FLAC", ["-c:a", "flac", "-f", "flac"]),
            ("MP3", ["-c:a", "libmp3lame", "-f", "mp3"]),
            ("AAC M4A", ["-c:a", "aac", "-f", "ipod"]),
            ("AIFF", ["-c:a", "pcm_s16be", "-f", "aiff"]),
            ("CAF", ["-c:a", "pcm_s16le", "-f", "caf"]),
            ("Ogg Opus", ["-c:a", "libopus", "-f", "ogg"]),
        ]

        for (label, formatArguments) in formats {
            let destination = temporaryDirectory.appendingPathComponent("\(label) stereo path ü.data")
            try transcode(source, to: destination, arguments: ["-ac", "2", "-ar", label == "Ogg Opus" ? "48000" : "44100"] + formatArguments)
            let result = try service.prepare(
                sourceURL: destination,
                options: .init(cacheDirectory: temporaryDirectory.appendingPathComponent("cache \(label)", isDirectory: true))
            )

            XCTAssertTrue(FileManager.default.fileExists(atPath: result.sourceCopyURL.path), label)
            XCTAssertTrue(FileManager.default.fileExists(atPath: result.playbackCopyURL.path), label)
            XCTAssertTrue(FileManager.default.fileExists(atPath: result.workingAudioURL.path), label)
            XCTAssertNotEqual(result.sourceCopyURL, result.playbackCopyURL, label)
            let file = try AVAudioFile(forReading: result.workingAudioURL)
            XCTAssertEqual(file.processingFormat.channelCount, 1, label)
            XCTAssertEqual(file.processingFormat.sampleRate, 16_000, accuracy: 0.01, label)

            for originalTime in stride(from: 0.0, through: 0.23, by: 0.017) {
                let frame = result.timeMapping.workingFrame(forSourceTime: originalTime)
                let roundTrip = result.timeMapping.sourceTime(forWorkingFrame: frame)
                XCTAssertEqual(roundTrip, originalTime, accuracy: 0.001, "\(label): \(originalTime)")
            }
            XCTAssertEqual(result.timeMapping.sourceTime(forWorkingFrame: 0), 0, accuracy: 0.000_001, label)
            XCTAssertEqual(result.timeMapping.decoderOutputOffset, 0, accuracy: 0.000_001, label)
        }
    }

    func testPhaseCancellingStereoDownmixIsFlaggedAndChannelSelectionPreservesSpeech() throws {
        let fixture = try writePhaseCancellingStereoFixture()
        let downmix = try service.prepare(sourceURL: fixture, options: .init(cacheDirectory: temporaryDirectory.appendingPathComponent("phase cache", isDirectory: true)))
        let warning = try XCTUnwrap(downmix.phaseCancellationWarning)
        XCTAssertLessThan(warning.correlation, -0.99)
        XCTAssertLessThan(warning.downmixToStrongestChannelRatio, 0.01)

        let left = try service.prepare(sourceURL: fixture, options: .init(channelSelection: .left, cacheDirectory: temporaryDirectory.appendingPathComponent("left cache", isDirectory: true)))
        XCTAssertNil(left.phaseCancellationWarning)
        XCTAssertGreaterThan(try rms(of: left.workingAudioURL), 0.1)
    }

    func testMultitrackSourcesRequireAnExplicitAudioStreamSelection() throws {
        let stereo = try writePCM(name: "multi source.wav", rate: 44_100, channels: 1)
        let second = try writePCM(name: "second source.wav", rate: 44_100, channels: 1)
        let multitrack = temporaryDirectory.appendingPathComponent("multiple streams.m4a")
        try run(
            fixtureEncoderURL,
            arguments: ["-y", "-v", "error", "-i", stereo.path, "-i", second.path, "-map", "0:a", "-map", "1:a", "-c:a", "aac", multitrack.path]
        )

        XCTAssertThrowsError(try service.prepare(sourceURL: multitrack, options: .init(cacheDirectory: temporaryDirectory.appendingPathComponent("multi cache")))) { error in
            guard case AudioPreparationError.streamSelectionRequired(let indices) = error else { return XCTFail("Expected explicit selection, got \(error)") }
            XCTAssertEqual(indices.count, 2)
        }
        let streamIndex = try MediaProber(ffprobeURL: ffprobeURL).probe(multitrack).audioStreams[1].index
        let result = try service.prepare(sourceURL: multitrack, options: .init(audioStreamIndex: streamIndex, cacheDirectory: temporaryDirectory.appendingPathComponent("multi selected cache")))
        XCTAssertEqual(result.selectedStream.index, streamIndex)
    }

    private var service: AudioPreparationService { AudioPreparationService(ffmpegURL: ffmpegURL, ffprobeURL: ffprobeURL) }

    private func writePCM(name: String, rate: Double, channels: AVAudioChannelCount) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name)
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let frames: AVAudioFrameCount = 14_400
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frames) { buffer.floatChannelData![channel][frame] = sin(Float(frame) * 0.031 + Float(channel) * 0.4) * 0.4 }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    private func writePhaseCancellingStereoFixture() throws -> URL {
        let url = temporaryDirectory.appendingPathComponent("phase cancelling stereo.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let frames: AVAudioFrameCount = 24_000
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for frame in 0..<Int(frames) {
            let sample = sin(Float(frame) * 0.05) * 0.6
            buffer.floatChannelData![0][frame] = sample
            buffer.floatChannelData![1][frame] = -sample
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    private func transcode(_ source: URL, to destination: URL, arguments: [String]) throws {
        try run(fixtureEncoderURL, arguments: ["-y", "-v", "error", "-i", source.path] + arguments + [destination.path])
    }

    private func rms(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        return sqrt(samples.reduce(0) { $0 + Double($1 * $1) } / Double(samples.count))
    }

    private func findExecutable(named name: String) throws -> URL {
        let environmentName = "SCRIBE_\(name.uppercased())"
        if let environmentPath = ProcessInfo.processInfo.environment[environmentName], FileManager.default.isExecutableFile(atPath: environmentPath) { return URL(fileURLWithPath: environmentPath) }
        for path in ["/usr/local/bin/\(name)", "/opt/homebrew/bin/\(name)"] where FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        throw XCTSkip("Install the pinned FFmpeg toolchain with Scripts/build-ffmpeg.sh, then set \(environmentName) for this integration test.")
    }

    /// Fixture creation needs MP3 and Opus encoders, deliberately omitted from Scribe's LGPL decoder bundle.
    private func findFixtureEncoder() throws -> URL {
        if let path = ProcessInfo.processInfo.environment["SCRIBE_FIXTURE_FFMPEG"], FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        for path in ["/usr/local/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg"] where FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        throw XCTSkip("Set SCRIBE_FIXTURE_FFMPEG to an FFmpeg build with MP3 and Opus encoders for fixture creation.")
    }

    private func run(_ executable: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FixtureGenerationError(message: String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown")
        }
    }
}

private struct FixtureGenerationError: Error, LocalizedError { let message: String; var errorDescription: String? { message } }
