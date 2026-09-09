import Foundation

/// The supported containers are identified from the bytes parsed by `ffprobe`, never from a filename suffix.
public enum MediaContainer: String, Codable, Sendable, CaseIterable {
    case wav, flac, mp3, m4a, aiff, caf, ogg
    case mkv, avi, mpegts, mpeg, flv, asf, aac, amr, ac3
    /// A container `ffprobe` opened that is not one of the named popular formats.
    case generic
}

/// Turns Finder file-reference URLs into a path the bundled FFmpeg tools can open.
///
/// `FileManager` understands `file:///.file/id=…` URLs; `ffprobe` and `ffmpeg` do not.
/// They report "No such file or directory", which the importer previously surfaced as an
/// unsupported format. Resolving first, then passing an explicit `file:` input, keeps
/// Scribe FLAC, QuickTime M4A, and dropped video files readable.
public enum MediaSourceURL {
    public static func resolvedFileURL(for url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    public static func ffmpegInput(for url: URL) -> String {
        "file:" + resolvedFileURL(for: url).path(percentEncoded: false)
    }

    public static func filesystemPath(for url: URL) -> String {
        resolvedFileURL(for: url).path(percentEncoded: false)
    }
}

public struct AudioStreamProbe: Codable, Equatable, Sendable {
    /// The stream index in the source container, suitable for a later explicit selection UI.
    public let index: Int
    public let codec: String
    public let channels: Int
    public let sampleRate: Double
    public let duration: TimeInterval?

    public init(index: Int, codec: String, channels: Int, sampleRate: Double, duration: TimeInterval?) {
        self.index = index
        self.codec = codec
        self.channels = channels
        self.sampleRate = sampleRate
        self.duration = duration
    }
}

public struct MediaProbeResult: Codable, Equatable, Sendable {
    public let container: MediaContainer
    public let audioStreams: [AudioStreamProbe]
    public let duration: TimeInterval

    public init(container: MediaContainer, audioStreams: [AudioStreamProbe], duration: TimeInterval) {
        self.container = container
        self.audioStreams = audioStreams
        self.duration = duration
    }

    public var audioStreamCount: Int { audioStreams.count }
}

/// Errors deliberately distinguish a bad input from an unsupported format and a packaging mistake.
public enum MediaProbeError: Error, Equatable, Sendable {
    case corrupt(details: String)
    case encrypted(details: String)
    case unsupported(details: String)
    case executableUnavailable(URL)
    case executionFailed(details: String)
}

extension MediaProbeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .corrupt(let details): "The media file is corrupt: \(details)"
        case .encrypted(let details): "The media file is encrypted: \(details)"
        case .unsupported(let details): "The media file is unsupported: \(details)"
        case .executableUnavailable(let url): "The bundled ffprobe executable is unavailable at \(url.path)."
        case .executionFailed(let details): "Media probing failed: \(details)"
        }
    }
}

/// Content-based media inspection backed by the pinned, bundled `ffprobe` executable.
///
/// `ffprobe` is launched with an argument array, rather than a shell command, which preserves paths
/// containing spaces and non-ASCII characters. A result includes every audio stream so that callers
/// can require an explicit stream choice before decoding a multitrack container.
public struct MediaProber: Sendable {
    public let ffprobeURL: URL

    public init(ffprobeURL: URL) { self.ffprobeURL = ffprobeURL }

    public func probe(_ sourceURL: URL) throws -> MediaProbeResult {
        guard FileManager.default.isExecutableFile(atPath: ffprobeURL.path) else {
            throw MediaProbeError.executableUnavailable(ffprobeURL)
        }

        let resolvedURL = MediaSourceURL.resolvedFileURL(for: sourceURL)
        let filesystemPath = MediaSourceURL.filesystemPath(for: resolvedURL)
        guard FileManager.default.fileExists(atPath: filesystemPath) else {
            throw MediaProbeError.unsupported(details: "The source file does not exist or is not readable.")
        }

        let process = Process()
        process.executableURL = ffprobeURL
        process.arguments = [
            "-v", "error",
            "-show_entries", "format=format_name,duration:stream=index,codec_type,codec_name,channels,sample_rate,duration",
            "-of", "json",
            "-i", MediaSourceURL.ffmpegInput(for: resolvedURL),
        ]
        let output = Pipe()
        let diagnostics = Pipe()
        process.standardOutput = output
        process.standardError = diagnostics
        do { try process.run() } catch { throw MediaProbeError.executionFailed(details: error.localizedDescription) }
        process.waitUntilExit()

        let standardError = String(data: diagnostics.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else { throw classifyFailure(standardError, filesystemPath: filesystemPath) }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let decoded: FFProbeDocument
        do { decoded = try JSONDecoder().decode(FFProbeDocument.self, from: data) }
        catch { throw MediaProbeError.corrupt(details: "ffprobe returned malformed metadata (\(error.localizedDescription)).") }

        let container = MediaContainer(formatNames: decoded.format.formatName)
        let streams = decoded.streams.compactMap(AudioStreamProbe.init)
        guard !streams.isEmpty else { throw MediaProbeError.unsupported(details: "The detected \(container.rawValue) container has no audio stream.") }
        guard streams.allSatisfy({ !$0.codec.isEmpty && $0.channels > 0 && $0.sampleRate > 0 }) else {
            throw MediaProbeError.corrupt(details: "An audio stream has missing or invalid channel or sample-rate metadata.")
        }
        guard Self.supports(streams) else {
            throw MediaProbeError.unsupported(details: "The \(container.rawValue) container uses an unsupported audio codec (\(streams.map(\.codec).joined(separator: ", "))).")
        }
        let duration = decoded.format.durationValue ?? streams.compactMap(\.duration).max()
        guard let duration, duration.isFinite, duration >= 0 else {
            throw MediaProbeError.corrupt(details: "The container does not report a valid duration.")
        }
        return MediaProbeResult(container: container, audioStreams: streams, duration: duration)
    }

    /// Codecs the pinned LGPL FFmpeg build can decode. Any container may carry them,
    /// including video files whose audio stream is what transcription needs.
    static let supportedAudioCodecs: Set<String> = [
        "pcm_s16le", "pcm_s16be", "pcm_s24le", "pcm_s24be", "pcm_s32le", "pcm_s32be",
        "pcm_f32le", "pcm_f32be", "pcm_f64le", "pcm_f64be", "pcm_u8", "pcm_s8",
        "pcm_mulaw", "pcm_alaw", "pcm_vidc",
        "flac", "alac", "aac", "aac_latm", "mp3", "mp2", "opus", "vorbis",
        "ac3", "eac3", "dca", "truehd", "mlp",
        "wmav1", "wmav2", "wmapro", "amr_nb", "amrnb", "amr_wb", "amrwb",
        "wavpack", "ape", "adpcm_ima_qt", "adpcm_ms", "gsm", "gsm_ms", "nellymoser",
    ]

    static func supports(_ streams: [AudioStreamProbe]) -> Bool {
        streams.allSatisfy { supportedAudioCodecs.contains($0.codec) }
    }

    private func classifyFailure(_ output: String, filesystemPath: String) -> MediaProbeError {
        let message = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = message.lowercased()
        if lower.contains("encrypted") || lower.contains("decryption") || lower.contains("drm") {
            return .encrypted(details: message.isEmpty ? "ffprobe reported encrypted media." : message)
        }
        if lower.contains("invalid data") || lower.contains("moov atom not found") || lower.contains("end of file") || lower.contains("failed to read") {
            return .corrupt(details: message.isEmpty ? "The file is not valid media data." : message)
        }
        if !FileManager.default.fileExists(atPath: filesystemPath) {
            return .unsupported(details: "The source file does not exist or is not readable.")
        }
        return .unsupported(details: message.isEmpty ? "ffprobe could not recognize this media." : message)
    }
}

extension MediaContainer {
    init(formatNames: String) {
        let names = Set(formatNames.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        if names.contains("wav") { self = .wav }
        else if names.contains("flac") { self = .flac }
        else if names.contains("mp3") { self = .mp3 }
        else if names.contains("aiff") { self = .aiff }
        else if names.contains("caf") { self = .caf }
        else if names.contains("ogg") { self = .ogg }
        else if names.contains("matroska") || names.contains("webm") { self = .mkv }
        else if names.contains("avi") { self = .avi }
        else if names.contains("mpegts") { self = .mpegts }
        else if names.contains("mpeg") || names.contains("mpegps") || names.contains("mpegvideo") { self = .mpeg }
        else if names.contains("flv") { self = .flv }
        else if names.contains("asf") { self = .asf }
        else if names.contains("amr") { self = .amr }
        else if names.contains("ac3") { self = .ac3 }
        else if names.contains("aac") && !names.contains("mov") && !names.contains("mp4") && !names.contains("m4a") { self = .aac }
        else if names.contains("m4a") || names.contains("mov") || names.contains("mp4") || names.contains("3gp") || names.contains("3g2") || names.contains("mj2") {
            self = .m4a
        }
        else { self = .generic }
    }
}

private struct FFProbeDocument: Decodable { let streams: [FFProbeStream]; let format: FFProbeFormat }
private struct FFProbeFormat {
    let formatName: String; let duration: String?
    enum CodingKeys: String, CodingKey { case formatName = "format_name", duration }
    var durationValue: TimeInterval? { duration.flatMap(Double.init) }
}
extension FFProbeFormat: Decodable {}
private struct FFProbeStream {
    let index: Int; let codecType: String; let codecName: String?; let channels: Int?; let sampleRate: String?; let duration: String?
    enum CodingKeys: String, CodingKey { case index, channels, duration; case codecType = "codec_type"; case codecName = "codec_name"; case sampleRate = "sample_rate" }
}
extension FFProbeStream: Decodable {}
private extension AudioStreamProbe {
    init?(_ stream: FFProbeStream) {
        guard stream.codecType == "audio", let codec = stream.codecName, let channels = stream.channels, let rateText = stream.sampleRate, let sampleRate = Double(rateText) else { return nil }
        self.init(index: stream.index, codec: codec, channels: channels, sampleRate: sampleRate, duration: stream.duration.flatMap(Double.init))
    }
}
