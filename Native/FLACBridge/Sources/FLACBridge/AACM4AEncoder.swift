import AVFAudio
import AudioToolbox
import CryptoKit
import Darwin
import Foundation

/// Streams PCM into an AAC-LC stream in an MPEG-4 audio (`.m4a`) container.
///
/// Scribe deliberately uses AAC-LC at 64 kbps CBR for its mono, 48 kHz speech
/// mix.  The original CAF capture remains the lossless reprocessing archive;
/// this file is the compact interchange and transcription handoff artifact.
///
/// Like `FLACEncoder`, this type writes to a hidden sibling and publishes with a
/// same-volume rename only after it has been finalized and decoded. AAC is
/// lossy, so verification proves container/codec, decodability, layout, and
/// timing within one AAC packet rather than comparing samples bit-for-bit.
public final class AACM4AEncoder {
    private enum State { case writing, closed }

    /// The AAC-LC profile selected for recorder output. `kAudioFormatMPEG4AAC`
    /// is AAC-LC, rather than the HE-AAC or ALAC format identifiers.
    public static let codecDescription = "AAC-LC, 64 kbps CBR"
    public static let defaultBitRate = 64_000
    /// AAC-LC access units contain 1,024 PCM samples. Priming/padding is
    /// signalled in the M4A edit list, but readers which expose it can differ by
    /// a packet, so this is the verification timing tolerance.
    public static let maximumTimingErrorFrames: Int64 = 1_024

    struct TestHooks { var afterFinalize: ((URL) throws -> Void)? }

    public let outputURL: URL
    public let temporaryURL: URL
    public let sampleRate: Int
    public let channelCount: Int
    public let bitRate: Int
    public private(set) var framesWritten: Int64 = 0

    var testHooks = TestHooks()
    private let processingFormat: AVAudioFormat
    private var file: AVAudioFile?
    private var state: State = .writing

    public init(outputURL: URL, sampleRate: Int, channelCount: Int, bitRate: Int = AACM4AEncoder.defaultBitRate) throws {
        guard sampleRate > 0 else { throw AACM4AEncoderError.invalidConfiguration("sample rate must be positive") }
        guard (1...2).contains(channelCount) else { throw AACM4AEncoderError.invalidConfiguration("AAC recorder output supports mono or stereo") }
        guard bitRate > 0 else { throw AACM4AEncoderError.invalidConfiguration("bit rate must be positive") }
        let directory = outputURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AACM4AEncoderError.missingDestinationDirectory(directory)
        }
        guard outputURL.pathExtension.lowercased() == "m4a" else {
            throw AACM4AEncoderError.invalidConfiguration("output must use the .m4a extension so AVFoundation writes an MPEG-4 audio container")
        }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: AVAudioChannelCount(channelCount), interleaved: false) else {
            throw AACM4AEncoderError.invalidConfiguration("could not create a PCM input format")
        }

        self.outputURL = outputURL
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitRate = bitRate
        self.processingFormat = format
        let token = UUID().uuidString.prefix(8)
        self.temporaryURL = directory.appendingPathComponent(".\(outputURL.deletingPathExtension().lastPathComponent).\(token).partial.m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Double(sampleRate),
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitRateKey: bitRate,
            AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_Constant,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        self.file = try AVAudioFile(forWriting: temporaryURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    deinit {
        file = nil
        if case .writing = state { try? FileManager.default.removeItem(at: temporaryURL) }
    }

    public func write(_ buffer: AVAudioPCMBuffer) throws {
        guard case .writing = state, let file else { throw AACM4AEncoderError.encoderNotWritable }
        guard buffer.frameLength > 0 else { return }
        guard Int(buffer.format.channelCount) == channelCount, abs(buffer.format.sampleRate - Double(sampleRate)) < 0.001 else {
            throw AACM4AEncoderError.formatMismatch("buffer is \(buffer.format.sampleRate) Hz / \(buffer.format.channelCount) channels; encoder expects \(sampleRate) Hz / \(channelCount) channels")
        }
        // AVAudioFile converts compatible PCM integer and float formats. The
        // mixdown supplies Float32, avoiding a second lossy quantization stage.
        try file.write(from: buffer)
        framesWritten += Int64(buffer.frameLength)
    }

    @discardableResult
    public func finish() throws -> AACM4AEncodeResult {
        guard case .writing = state else { throw AACM4AEncoderError.encoderNotWritable }
        state = .closed
        do {
            guard framesWritten > 0 else { throw AACM4AEncoderError.emptyStream }
            file = nil
            try testHooks.afterFinalize?(temporaryURL)
            let decodedFrames = try verifyFinalizedFile()
            let byteCount = try FileManager.default.attributesOfItem(atPath: temporaryURL.path)[.size] as? UInt64 ?? 0
            let checksum = try Self.sha256(ofFileAt: temporaryURL)
            try publish()
            return AACM4AEncodeResult(url: outputURL, sampleRate: sampleRate, channelCount: channelCount, bitRate: bitRate, frameCount: framesWritten, decodedFrameCount: decodedFrames, byteCount: byteCount, sha256: checksum)
        } catch {
            file = nil
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    public func cancel() {
        guard case .writing = state else { return }
        state = .closed
        file = nil
        try? FileManager.default.removeItem(at: temporaryURL)
    }

    private func verifyFinalizedFile() throws -> Int64 {
        let bytes = try Data(contentsOf: temporaryURL, options: .mappedIfSafe)
        guard bytes.count >= 12, bytes[4...7] == Data("ftyp".utf8) else {
            throw AACM4AEncoderError.verificationFailed(.notMPEG4Container)
        }
        let reader: AVAudioFile
        do { reader = try AVAudioFile(forReading: temporaryURL, commonFormat: .pcmFormatFloat32, interleaved: false) }
        catch { throw AACM4AEncoderError.verificationFailed(.unreadableStream("\(error)")) }
        let format = reader.fileFormat.streamDescription.pointee
        guard format.mFormatID == kAudioFormatMPEG4AAC else {
            throw AACM4AEncoderError.verificationFailed(.codecMismatch(expected: "AAC-LC", foundFormatID: format.mFormatID))
        }
        guard Int(reader.fileFormat.channelCount) == channelCount else {
            throw AACM4AEncoderError.verificationFailed(.channelCountMismatch(expected: channelCount, found: Int(reader.fileFormat.channelCount)))
        }
        guard abs(reader.fileFormat.sampleRate - Double(sampleRate)) < 0.001 else {
            throw AACM4AEncoderError.verificationFailed(.sampleRateMismatch(expected: sampleRate, found: reader.fileFormat.sampleRate))
        }
        let delta = abs(reader.length - framesWritten)
        guard delta <= Self.maximumTimingErrorFrames else {
            throw AACM4AEncoderError.verificationFailed(.durationMismatch(expected: framesWritten, decoded: reader.length, tolerance: Self.maximumTimingErrorFrames))
        }
        // Read all reported frames. This catches a structurally valid header with
        // an undecodable/truncated payload without asserting lossless samples.
        var decoded: Int64 = 0
        while decoded < reader.length {
            let wanted = AVAudioFrameCount(min(4_096, reader.length - decoded))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: wanted) else {
                throw AACM4AEncoderError.verificationFailed(.unreadableStream("could not allocate decode buffer"))
            }
            try reader.read(into: buffer, frameCount: wanted)
            guard buffer.frameLength > 0 else { break }
            decoded += Int64(buffer.frameLength)
        }
        guard decoded == reader.length else { throw AACM4AEncoderError.verificationFailed(.unreadableStream("decoder stopped at \(decoded) of \(reader.length) frames")) }
        return decoded
    }

    private func publish() throws {
        let moved = temporaryURL.withUnsafeFileSystemRepresentation { source in outputURL.withUnsafeFileSystemRepresentation { destination in rename(source!, destination!) } }
        guard moved == 0 else { throw AACM4AEncoderError.publishFailed(errno: errno, temporaryURL: temporaryURL, finalURL: outputURL) }
    }

    public static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public struct AACM4AEncodeResult: Sendable, Hashable, Codable {
    public let url: URL
    public let sampleRate: Int
    public let channelCount: Int
    public let bitRate: Int
    /// Frames submitted on the source timeline; this is what the manifest uses.
    public let frameCount: Int64
    /// Frames presented by the system decoder after its priming/padding handling.
    public let decodedFrameCount: Int64
    public let byteCount: UInt64
    public let sha256: String
    public var duration: Double { Double(frameCount) / Double(sampleRate) }
    public var decodedDuration: Double { Double(decodedFrameCount) / Double(sampleRate) }
}

public enum AACM4AVerificationFailure: Sendable, Hashable, Codable {
    case notMPEG4Container
    case unreadableStream(String)
    case codecMismatch(expected: String, foundFormatID: AudioFormatID)
    case sampleRateMismatch(expected: Int, found: Double)
    case channelCountMismatch(expected: Int, found: Int)
    case durationMismatch(expected: Int64, decoded: Int64, tolerance: Int64)
}

public enum AACM4AEncoderError: Error, Sendable {
    case invalidConfiguration(String)
    case missingDestinationDirectory(URL)
    case formatMismatch(String)
    case encoderNotWritable
    case emptyStream
    case verificationFailed(AACM4AVerificationFailure)
    case publishFailed(errno: Int32, temporaryURL: URL, finalURL: URL)
}

extension AACM4AEncoderError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidConfiguration(let detail): "Invalid AAC M4A configuration: \(detail)."
        case .missingDestinationDirectory(let url): "AAC M4A destination directory does not exist: \(url.path)."
        case .formatMismatch(let detail): "AAC M4A input buffer format mismatch: \(detail)."
        case .encoderNotWritable: "The AAC M4A encoder is no longer accepting audio."
        case .emptyStream: "The AAC M4A encoder received no audio frames."
        case .verificationFailed(let failure): "AAC M4A verification failed, nothing was published: \(failure)."
        case .publishFailed(let code, let temporaryURL, let finalURL): "Could not rename \(temporaryURL.lastPathComponent) to \(finalURL.lastPathComponent): errno \(code)."
        }
    }
}
