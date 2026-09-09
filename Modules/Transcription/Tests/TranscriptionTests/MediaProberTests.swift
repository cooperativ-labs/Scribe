import AVFoundation
import Foundation
import XCTest
@testable import Transcription

final class MediaProberTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var ffprobeURL: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("Scribe Media Prober \u{1F3B5} \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        ffprobeURL = try findExecutable(named: "ffprobe")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: temporaryDirectory) }

    func testProbesAllSupportedContentTypesWithMonoStereoAndCommonRates() throws {
        let source = try writePCM(name: "source audio.wav", rate: 48_000, channels: 2)
        let formats: [(String, [String], MediaContainer, String)] = [
            ("renamed wav", ["-c:a", "pcm_s16le", "-f", "wav"], .wav, "pcm_s16le"),
            ("flac", ["-c:a", "flac", "-f", "flac"], .flac, "flac"),
            ("mp3", ["-c:a", "libmp3lame", "-f", "mp3"], .mp3, "mp3"),
            ("AAC in unicode \u{65E5}\u{672C}\u{8A9E}", ["-c:a", "aac", "-f", "ipod"], .m4a, "aac"),
            ("aiff", ["-c:a", "pcm_s16be", "-f", "aiff"], .aiff, "pcm_s16be"),
            ("caf", ["-c:a", "pcm_s16le", "-f", "caf"], .caf, "pcm_s16le"),
            ("opus with spaces \u{00FC}", ["-c:a", "libopus", "-f", "ogg"], .ogg, "opus"),
        ]

        for (suffix, rate, channels) in [("mono noext", 44_100.0, 1), ("stereo .blob", 48_000.0, 2)] {
            for (name, formatArguments, container, codec) in formats {
                let output = temporaryDirectory.appendingPathComponent("\(name) \(suffix)")
                // Opus is specified at 48 kHz; its encoder resamples other input rates to that timeline.
                let expectedRate = codec == "opus" ? 48_000.0 : rate
                try transcode(source, to: output, arguments: ["-ac", "\(channels)", "-ar", "\(Int(expectedRate))"] + formatArguments)
                let result = try MediaProber(ffprobeURL: ffprobeURL).probe(output)
                XCTAssertEqual(result.container, container, "\(output.lastPathComponent)")
                XCTAssertEqual(result.audioStreamCount, 1, "\(output.lastPathComponent)")
                XCTAssertEqual(result.audioStreams[0].codec, codec, "\(output.lastPathComponent)")
                XCTAssertEqual(result.audioStreams[0].channels, channels, "\(output.lastPathComponent)")
                XCTAssertEqual(result.audioStreams[0].sampleRate, expectedRate, accuracy: 0.01, "\(output.lastPathComponent)")
                // MP3 encoder delay/padding is part of the encoded media duration.
                XCTAssertEqual(result.duration, 0.25, accuracy: 0.05, "\(output.lastPathComponent)")
            }
        }
    }

    func testRejectsCorruptContentRegardlessOfExtension() throws {
        let corrupt = temporaryDirectory.appendingPathComponent("looks like audio.m4a")
        try Data([0x00, 0xF1, 0xB5, 0x7E]).write(to: corrupt)
        XCTAssertThrowsError(try MediaProber(ffprobeURL: ffprobeURL).probe(corrupt)) { error in
            guard case MediaProbeError.corrupt = error else { return XCTFail("Expected a structured corrupt error, got \(error)") }
        }
    }

    func testProbesFinderFileReferenceURLsForFlacAndM4A() throws {
        let source = try writePCM(name: "reference source.wav", rate: 48_000, channels: 1)
        let samples: [(String, [String], MediaContainer, String)] = [
            ("scribe flac.flac", ["-c:a", "flac", "-f", "flac"], .flac, "flac"),
            ("quicktime.m4a", ["-c:a", "aac", "-f", "ipod"], .m4a, "aac"),
        ]
        for (name, arguments, container, codec) in samples {
            let output = temporaryDirectory.appendingPathComponent(name)
            try transcode(source, to: output, arguments: arguments)
            guard let fileReference = (output as NSURL).fileReferenceURL() as URL? else {
                throw XCTSkip("This host does not produce Finder file-reference URLs.")
            }
            XCTAssertTrue(
                fileReference.path.contains("/.file/id=") || fileReference.path != output.path,
                "expected a file-reference URL, got \(fileReference.path)"
            )
            let result = try MediaProber(ffprobeURL: ffprobeURL).probe(fileReference)
            XCTAssertEqual(result.container, container, name)
            XCTAssertEqual(result.audioStreams[0].codec, codec, name)
        }
    }

    func testProbesPopularVideoContainers() throws {
        let source = try writePCM(name: "container source.wav", rate: 48_000, channels: 1)
        let formats: [(String, [String], MediaContainer, String)] = [
            ("meeting.mkv", ["-c:a", "libopus", "-f", "matroska"], .mkv, "opus"),
            ("clip.webm", ["-c:a", "libopus", "-f", "webm"], .mkv, "opus"),
            ("clip.mp4", ["-c:a", "aac", "-f", "mp4"], .m4a, "aac"),
        ]
        for (name, arguments, container, codec) in formats {
            let output = temporaryDirectory.appendingPathComponent(name)
            try transcode(source, to: output, arguments: arguments)
            let result = try MediaProber(ffprobeURL: ffprobeURL).probe(output)
            XCTAssertEqual(result.container, container, name)
            XCTAssertEqual(result.audioStreams[0].codec, codec, name)
            XCTAssertGreaterThan(result.duration, 0, name)
        }
    }

    func testMapsPopularFormatNamesIncludingVideo() {
        XCTAssertEqual(MediaContainer(formatNames: "flac"), .flac)
        XCTAssertEqual(MediaContainer(formatNames: "mov,mp4,m4a,3gp,3g2,mj2"), .m4a)
        XCTAssertEqual(MediaContainer(formatNames: "matroska,webm"), .mkv)
        XCTAssertEqual(MediaContainer(formatNames: "matroska"), .mkv)
        XCTAssertEqual(MediaContainer(formatNames: "avi"), .avi)
        XCTAssertEqual(MediaContainer(formatNames: "mpegts"), .mpegts)
        XCTAssertEqual(MediaContainer(formatNames: "ogg"), .ogg)
        XCTAssertEqual(MediaContainer(formatNames: "asf"), .asf)
        XCTAssertEqual(MediaContainer(formatNames: "aac"), .aac)
        XCTAssertEqual(MediaContainer(formatNames: "nut"), .generic)
    }

    func testResolvesFileReferenceURLsToAnFFmpegFileInput() throws {
        let file = temporaryDirectory.appendingPathComponent("path test.flac")
        try Data("flac".utf8).write(to: file)
        guard let fileReference = (file as NSURL).fileReferenceURL() as URL? else {
            throw XCTSkip("This host does not produce Finder file-reference URLs.")
        }
        let resolved = MediaSourceURL.resolvedFileURL(for: fileReference)
        XCTAssertEqual(resolved.standardizedFileURL.path, file.resolvingSymlinksInPath().standardizedFileURL.path)
        XCTAssertTrue(MediaSourceURL.ffmpegInput(for: fileReference).hasPrefix("file:"))
        XCTAssertFalse(MediaSourceURL.ffmpegInput(for: fileReference).contains("/.file/id="))
    }

    private func writePCM(name: String, rate: Double, channels: AVAudioChannelCount) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name)
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let frames: AVAudioFrameCount = 12_000
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frames) { buffer.floatChannelData![channel][frame] = sin(Float(frame) * 0.03) }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    private func transcode(_ source: URL, to destination: URL, arguments: [String]) throws {
        let ffmpeg = try findFixtureEncoder()
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-y", "-v", "error", "-i", source.path] + arguments + [destination.path]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FixtureGenerationError(message: String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown")
        }
    }

    private func findExecutable(named name: String) throws -> URL {
        let environmentName = "SCRIBE_\(name.uppercased())"
        if let environmentPath = ProcessInfo.processInfo.environment[environmentName], FileManager.default.isExecutableFile(atPath: environmentPath) { return URL(fileURLWithPath: environmentPath) }
        for path in ["/usr/local/bin/\(name)", "/opt/homebrew/bin/\(name)"] where FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        throw XCTSkip("Install the pinned FFmpeg toolchain with Scripts/build-ffmpeg.sh, then set \(environmentName) for this integration test.")
    }

    /// Scribe's pinned bundle intentionally contains decoders only; matrix fixtures need encoders too.
    private func findFixtureEncoder() throws -> URL {
        if let environmentPath = ProcessInfo.processInfo.environment["SCRIBE_FIXTURE_FFMPEG"], FileManager.default.isExecutableFile(atPath: environmentPath) { return URL(fileURLWithPath: environmentPath) }
        for path in ["/usr/local/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg"] where FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        throw XCTSkip("Set SCRIBE_FIXTURE_FFMPEG to an FFmpeg build with MP3 and Opus encoders for fixture creation.")
    }
}

private struct FixtureGenerationError: Error, LocalizedError { let message: String; var errorDescription: String? { message } }
