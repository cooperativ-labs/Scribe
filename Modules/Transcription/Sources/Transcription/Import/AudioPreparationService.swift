import AVFoundation
import Foundation

/// The channel policy used when preparing a single-channel recognizer input.
///
/// `downmix` is explicit so callers can surface a phase-cancellation warning and offer a
/// non-destructive alternative. `left` and `right` are only valid for a stereo source.
public enum AudioChannelSelection: String, Codable, Sendable, CaseIterable {
    case downmix
    case left
    case right
}

public struct AudioPreparationOptions: Codable, Sendable {
    /// The global ffprobe stream index selected by the import UI. A multitrack source requires it.
    public var audioStreamIndex: Int?
    public var channelSelection: AudioChannelSelection
    /// Intended for tests and controlled host environments. `nil` uses the application caches directory.
    public var cacheDirectory: URL?

    public init(
        audioStreamIndex: Int? = nil,
        channelSelection: AudioChannelSelection = .downmix,
        cacheDirectory: URL? = nil
    ) {
        self.audioStreamIndex = audioStreamIndex
        self.channelSelection = channelSelection
        self.cacheDirectory = cacheDirectory
    }
}

/// An affine relation between decoded working frames and the source-media timeline.
///
/// The preparation stage never trims leading silence: frame zero maps to source time zero. The
/// offsets are persisted even when they are zero, so a future decoder with non-zero priming can be
/// represented without changing transcript timestamp semantics.
public struct AudioTimeMapping: Codable, Equatable, Sendable {
    public let sourceTimelineOffset: TimeInterval
    public let decoderOutputOffset: TimeInterval
    public let sourceSampleRate: Double
    public let workingSampleRate: Double

    public init(
        sourceTimelineOffset: TimeInterval = 0,
        decoderOutputOffset: TimeInterval = 0,
        sourceSampleRate: Double,
        workingSampleRate: Double = 16_000
    ) {
        self.sourceTimelineOffset = sourceTimelineOffset
        self.decoderOutputOffset = decoderOutputOffset
        self.sourceSampleRate = sourceSampleRate
        self.workingSampleRate = workingSampleRate
    }

    public var sourceFramesPerWorkingFrame: Double { sourceSampleRate / workingSampleRate }

    public func sourceTime(forWorkingFrame frame: Int64) -> TimeInterval {
        sourceTime(forWorkingSeconds: Double(frame) / workingSampleRate)
    }

    /// Maps a time on the prepared 16 kHz working file onto the source-media timeline.
    public func sourceTime(forWorkingSeconds seconds: TimeInterval) -> TimeInterval {
        sourceTimelineOffset + seconds - decoderOutputOffset
    }

    public func workingFrame(forSourceTime time: TimeInterval) -> Int64 {
        Int64(((time - sourceTimelineOffset + decoderOutputOffset) * workingSampleRate).rounded())
    }

    public func sourceFrame(forWorkingFrame frame: Int64) -> Double {
        (Double(frame) / workingSampleRate) * sourceSampleRate
    }
}

public struct PhaseCancellationWarning: Codable, Equatable, Sendable {
    public let correlation: Double
    public let downmixToStrongestChannelRatio: Double
}

public struct AudioPreparationResult: Codable, Equatable, Sendable {
    /// The original selected file is never modified; this is its stable cache snapshot.
    public let sourceCopyURL: URL
    /// A separate source-format playback copy retained beside the recognizer working stream.
    public let playbackCopyURL: URL
    /// 16 kHz, mono, signed-16-bit PCM WAV for the initial recognition engine.
    public let workingAudioURL: URL
    public let selectedStream: AudioStreamProbe
    public let timeMapping: AudioTimeMapping
    public let phaseCancellationWarning: PhaseCancellationWarning?

    public init(sourceCopyURL: URL, playbackCopyURL: URL, workingAudioURL: URL, selectedStream: AudioStreamProbe, timeMapping: AudioTimeMapping, phaseCancellationWarning: PhaseCancellationWarning?) {
        self.sourceCopyURL = sourceCopyURL
        self.playbackCopyURL = playbackCopyURL
        self.workingAudioURL = workingAudioURL
        self.selectedStream = selectedStream
        self.timeMapping = timeMapping
        self.phaseCancellationWarning = phaseCancellationWarning
    }
}

public enum AudioPreparationError: Error, Equatable, Sendable {
    case streamSelectionRequired(availableStreamIndices: [Int])
    case invalidStreamSelection(Int)
    case invalidChannelSelection(AudioChannelSelection, channelCount: Int)
    case sourceChangedDuringSnapshot
    case executableUnavailable(URL)
    case decodingFailed(details: String)
    case cacheFailure(details: String)
}

extension AudioPreparationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .streamSelectionRequired(let indices): "Select an audio stream before decoding (available: \(indices.map(String.init).joined(separator: ", ")))."
        case .invalidStreamSelection(let index): "Audio stream \(index) is not available in this file."
        case .invalidChannelSelection(let selection, let count): "The \(selection.rawValue) channel selection is not valid for a \(count)-channel stream."
        case .sourceChangedDuringSnapshot: "The source changed while its local processing snapshot was being created."
        case .executableUnavailable(let url): "The bundled ffmpeg executable is unavailable at \(url.path)."
        case .decodingFailed(let details): "Audio decoding failed: \(details)"
        case .cacheFailure(let details): "Unable to prepare the audio cache: \(details)"
        }
    }
}

/// Creates a stable playback snapshot and a 16 kHz mono recognizer stream using the pinned FFmpeg.
public struct AudioPreparationService: Sendable {
    public static let workingSampleRate: Double = 16_000

    public let prober: MediaProber
    public let ffmpegURL: URL

    public init(ffmpegURL: URL, ffprobeURL: URL) {
        self.ffmpegURL = ffmpegURL
        self.prober = MediaProber(ffprobeURL: ffprobeURL)
    }

    public init(ffmpegURL: URL, prober: MediaProber) {
        self.ffmpegURL = ffmpegURL
        self.prober = prober
    }

    public static func defaultCacheDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("Scribe/Transcription/DecodedAudio", isDirectory: true)
    }

    public func prepare(sourceURL: URL, options: AudioPreparationOptions = .init()) throws -> AudioPreparationResult {
        guard FileManager.default.isExecutableFile(atPath: ffmpegURL.path) else {
            throw AudioPreparationError.executableUnavailable(ffmpegURL)
        }
        let probe = try prober.probe(sourceURL)
        let stream = try selectedStream(from: probe, requestedIndex: options.audioStreamIndex)
        guard options.channelSelection == .downmix || stream.channels == 2 else {
            throw AudioPreparationError.invalidChannelSelection(options.channelSelection, channelCount: stream.channels)
        }

        let root = options.cacheDirectory ?? Self.defaultCacheDirectory()
        let destination = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let staging = root.appendingPathComponent(".\(UUID().uuidString).staging", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }

            let suffix = sourceURL.pathExtension.isEmpty ? "media" : sourceURL.pathExtension
            let sourceCopy = staging.appendingPathComponent("source.\(suffix)")
            let playbackCopy = staging.appendingPathComponent("playback.\(suffix)")
            try snapshot(sourceURL, to: sourceCopy)
            try FileManager.default.copyItem(at: sourceCopy, to: playbackCopy)

            let working = staging.appendingPathComponent("working-16khz-mono.wav")
            try decode(source: sourceCopy, stream: stream, selection: options.channelSelection, to: working)
            let warning = try phaseCancellationWarningIfNeeded(source: sourceCopy, stream: stream, selection: options.channelSelection, in: staging)

            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: staging, to: destination)
            return AudioPreparationResult(
                sourceCopyURL: destination.appendingPathComponent(sourceCopy.lastPathComponent),
                playbackCopyURL: destination.appendingPathComponent(playbackCopy.lastPathComponent),
                workingAudioURL: destination.appendingPathComponent(working.lastPathComponent),
                selectedStream: stream,
                timeMapping: AudioTimeMapping(sourceSampleRate: stream.sampleRate, workingSampleRate: Self.workingSampleRate),
                phaseCancellationWarning: warning
            )
        } catch let error as AudioPreparationError {
            throw error
        } catch {
            throw AudioPreparationError.cacheFailure(details: error.localizedDescription)
        }
    }

    private func selectedStream(from probe: MediaProbeResult, requestedIndex: Int?) throws -> AudioStreamProbe {
        if let requestedIndex {
            guard let stream = probe.audioStreams.first(where: { $0.index == requestedIndex }) else {
                throw AudioPreparationError.invalidStreamSelection(requestedIndex)
            }
            return stream
        }
        if probe.audioStreams.count == 1 { return probe.audioStreams[0] }
        else {
            throw AudioPreparationError.streamSelectionRequired(availableStreamIndices: probe.audioStreams.map(\.index))
        }
    }

    private func snapshot(_ source: URL, to destination: URL) throws {
        let before = try snapshotAttributes(for: source)
        try FileManager.default.copyItem(at: source, to: destination)
        let after = try snapshotAttributes(for: source)
        guard before == after else { throw AudioPreparationError.sourceChangedDuringSnapshot }
    }

    private func snapshotAttributes(for url: URL) throws -> SnapshotAttributes {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return SnapshotAttributes(fileSize: values.fileSize, modificationDate: values.contentModificationDate)
    }

    private func decode(source: URL, stream: AudioStreamProbe, selection: AudioChannelSelection, to destination: URL) throws {
        var arguments = ["-y", "-v", "error", "-nostdin", "-i", source.path, "-map", "0:\(stream.index)", "-vn", "-sn", "-dn"]
        if stream.channels == 2 {
            switch selection {
            case .downmix: arguments += ["-filter:a", "pan=mono|c0=0.5*c0+0.5*c1"]
            case .left: arguments += ["-filter:a", "pan=mono|c0=c0"]
            case .right: arguments += ["-filter:a", "pan=mono|c0=c1"]
            }
        } else {
            arguments += ["-ac", "1"]
        }
        arguments += ["-ar", "\(Int(Self.workingSampleRate))", "-c:a", "pcm_s16le", "-f", "wav", destination.path]
        try runFFmpeg(arguments)
    }

    private func phaseCancellationWarningIfNeeded(source: URL, stream: AudioStreamProbe, selection: AudioChannelSelection, in directory: URL) throws -> PhaseCancellationWarning? {
        guard stream.channels == 2, selection == .downmix else { return nil }
        let left = directory.appendingPathComponent("phase-left.wav")
        let right = directory.appendingPathComponent("phase-right.wav")
        try decode(source: source, stream: stream, selection: .left, to: left)
        try decode(source: source, stream: stream, selection: .right, to: right)
        defer {
            try? FileManager.default.removeItem(at: left)
            try? FileManager.default.removeItem(at: right)
        }
        let metrics = try stereoMetrics(left: left, right: right)
        guard metrics.strongestRMS > 0 else { return nil }
        let ratio = metrics.downmixRMS / metrics.strongestRMS
        guard metrics.correlation <= -0.80, ratio < 0.25 else { return nil }
        return PhaseCancellationWarning(correlation: metrics.correlation, downmixToStrongestChannelRatio: ratio)
    }

    private func stereoMetrics(left: URL, right: URL) throws -> (correlation: Double, downmixRMS: Double, strongestRMS: Double) {
        let leftSamples = try pcmSamples(at: left)
        let rightSamples = try pcmSamples(at: right)
        let count = min(leftSamples.count, rightSamples.count)
        guard count > 0 else { return (0, 0, 0) }
        var leftPower = 0.0, rightPower = 0.0, cross = 0.0, mixPower = 0.0
        for index in 0..<count {
            let l = Double(leftSamples[index]), r = Double(rightSamples[index])
            leftPower += l * l; rightPower += r * r; cross += l * r
            let mixed = (l + r) * 0.5
            mixPower += mixed * mixed
        }
        let denominator = sqrt(leftPower * rightPower)
        return (denominator > 0 ? cross / denominator : 0, sqrt(mixPower / Double(count)), max(sqrt(leftPower / Double(count)), sqrt(rightPower / Double(count))))
    }

    private func pcmSamples(at url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.commonFormat == .pcmFormatFloat32, format.channelCount == 1 else {
            throw AudioPreparationError.decodingFailed(details: "The prepared WAV is not readable as mono float PCM.")
        }
        var samples: [Float] = []
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096) else { break }
            let remaining = file.length - file.framePosition
            try file.read(into: buffer, frameCount: min(buffer.frameCapacity, AVAudioFrameCount(remaining)))
            samples.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        return samples
    }

    private func runFFmpeg(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = arguments
        let diagnostics = Pipe()
        process.standardError = diagnostics
        do { try process.run() } catch { throw AudioPreparationError.decodingFailed(details: error.localizedDescription) }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: diagnostics.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown ffmpeg error"
            throw AudioPreparationError.decodingFailed(details: message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

private struct SnapshotAttributes: Equatable {
    let fileSize: Int?
    let modificationDate: Date?
}
