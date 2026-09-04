import Foundation

/// The supported containers are identified from the bytes parsed by `ffprobe`, never from a filename suffix.
public enum MediaContainer: String, Codable, Sendable, CaseIterable {
    case wav, flac, mp3, m4a, aiff, caf, ogg
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

        let process = Process()
        process.executableURL = ffprobeURL
        process.arguments = [
            "-v", "error",
            "-show_entries", "format=format_name,duration:stream=index,codec_type,codec_name,channels,sample_rate,duration",
            "-of", "json", "--", sourceURL.path,
        ]
        let output = Pipe()
        let diagnostics = Pipe()
        process.standardOutput = output
        process.standardError = diagnostics
        do { try process.run() } catch { throw MediaProbeError.executionFailed(details: error.localizedDescription) }
        process.waitUntilExit()

        let standardError = String(data: diagnostics.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else { throw classifyFailure(standardError, sourceURL: sourceURL) }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let decoded: FFProbeDocument
        do { decoded = try JSONDecoder().decode(FFProbeDocument.self, from: data) }
        catch { throw MediaProbeError.corrupt(details: "ffprobe returned malformed metadata (\(error.localizedDescription)).") }

        guard let container = MediaContainer(formatNames: decoded.format.formatName) else {
            throw MediaProbeError.unsupported(details: "Detected container \"\(decoded.format.formatName)\" is not in the import matrix.")
        }
        let streams = decoded.streams.compactMap(AudioStreamProbe.init)
        guard !streams.isEmpty else { throw MediaProbeError.unsupported(details: "The detected \(container.rawValue) container has no audio stream.") }
        guard streams.allSatisfy({ !$0.codec.isEmpty && $0.channels > 0 && $0.sampleRate > 0 }) else {
            throw MediaProbeError.corrupt(details: "An audio stream has missing or invalid channel or sample-rate metadata.")
        }
        guard supports(streams, in: container) else {
            throw MediaProbeError.unsupported(details: "The \(container.rawValue) container uses an unsupported audio codec (\(streams.map(\.codec).joined(separator: ", "))).")
        }
        guard let duration = decoded.format.durationValue, duration.isFinite, duration >= 0 else {
            throw MediaProbeError.corrupt(details: "The container does not report a valid duration.")
        }
        return MediaProbeResult(container: container, audioStreams: streams, duration: duration)
    }

    private func supports(_ streams: [AudioStreamProbe], in container: MediaContainer) -> Bool {
        let permitted: Set<String>
        switch container {
        case .wav, .aiff, .caf: permitted = ["pcm_s16le", "pcm_s16be", "pcm_s24le", "pcm_s24be", "pcm_s32le", "pcm_s32be", "pcm_f32le", "pcm_f32be", "pcm_f64le", "pcm_f64be", "alac", "aac"]
        case .flac: permitted = ["flac"]
        case .mp3: permitted = ["mp3"]
        case .m4a: permitted = ["aac", "alac"]
        case .ogg: permitted = ["opus"]
        }
        return streams.allSatisfy { permitted.contains($0.codec) }
    }

    private func classifyFailure(_ output: String, sourceURL: URL) -> MediaProbeError {
        let message = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = message.lowercased()
        if lower.contains("encrypted") || lower.contains("decryption") || lower.contains("drm") { return .encrypted(details: message.isEmpty ? "ffprobe reported encrypted media." : message) }
        if lower.contains("invalid data") || lower.contains("moov atom not found") || lower.contains("end of file") || lower.contains("failed to read") { return .corrupt(details: message.isEmpty ? "The file is not valid media data." : message) }
        if lower.contains("no such file") || !FileManager.default.fileExists(atPath: sourceURL.path) { return .unsupported(details: "The source file does not exist or is not readable.") }
        return .unsupported(details: message.isEmpty ? "ffprobe could not recognize this media." : message)
    }
}

private extension MediaContainer {
    init?(formatNames: String) {
        let names = Set(formatNames.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        if names.contains("wav") { self = .wav }
        else if names.contains("flac") { self = .flac }
        else if names.contains("mp3") { self = .mp3 }
        else if names.contains("aiff") { self = .aiff }
        else if names.contains("caf") { self = .caf }
        else if names.contains("ogg") { self = .ogg }
        else if names.contains("m4a") || names.contains("mov") || names.contains("mp4") { self = .m4a }
        else { return nil }
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
