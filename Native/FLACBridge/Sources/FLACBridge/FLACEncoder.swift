import AVFAudio
import AudioToolbox
import CryptoKit
import Foundation

/// Streams integer PCM into a FLAC file and publishes it only once the finished
/// file has been decoded and compared against its input.
///
/// The encoder writes to a hidden temporary sibling of `outputURL`, finalizes it,
/// checks `STREAMINFO`, decodes it back to integer PCM, compares that against a
/// running hash of everything it was given, checksums the bytes, and only then
/// renames the temporary file onto the final path. A failure at any point removes
/// the temporary file, so a partially written export can never appear under the
/// name a consumer reads.
///
/// Streams shorter than `FLACEncoderConfiguration.minimumFrameCount` cannot be
/// encoded at all; `finish()` reports that as `FLACEncoderError.streamTooShort`.
///
/// The underlying encoder is the system AudioToolbox FLAC encoder reached through
/// `AVAudioFile`; see `docs/feasibility/flac.md` for the measurements behind that
/// choice. The system encoder has no libFLAC-style verify mode, which is why the
/// decode comparison here is mandatory rather than a debug option. The public
/// surface of this type is deliberately independent of that decision: swapping in
/// a bundled libFLAC changes only this file's private members.
///
/// Instances are not thread-safe. Serialize writes onto one queue or actor, which
/// is how the offline processing pipeline consumes them anyway.
public final class FLACEncoder {
    private enum State: Equatable {
        case writing
        case closed
    }

    /// Test seam for proving the failure path. Never set in production code.
    struct TestHooks {
        var afterFinalize: ((URL) throws -> Void)?
    }

    public let configuration: FLACEncoderConfiguration
    /// The path this encoder will publish to, once verification succeeds.
    public let outputURL: URL
    /// The temporary sibling currently being written.
    public let temporaryURL: URL

    /// Frames accepted so far.
    public private(set) var framesWritten: Int64 = 0

    var testHooks = TestHooks()

    private let processingFormat: AVAudioFormat
    private var file: AVAudioFile?
    private var state: State = .writing
    private var stagingBuffer: AVAudioPCMBuffer?
    private var scratch: [Int32] = []
    private var inputHash = SHA256()

    /// Prepares a temporary file next to `outputURL`.
    ///
    /// Nothing is created at `outputURL` here or during writing.
    ///
    /// - Parameters:
    ///   - outputURL: Final destination. Its parent directory must already exist so
    ///     the temporary file lands on the same volume and the publish is a rename.
    ///   - configuration: Output sample rate, channel layout, and bit depth.
    public init(outputURL: URL, configuration: FLACEncoderConfiguration) throws {
        try configuration.validate()
        let directory = outputURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FLACEncoderError.missingDestinationDirectory(directory)
        }

        self.configuration = configuration
        self.outputURL = outputURL
        // Hidden, uniquely named, and still `.flac` so the writer picks the same
        // file type it would for the final name.
        let token = UUID().uuidString.prefix(8)
        self.temporaryURL = directory.appendingPathComponent(
            ".\(outputURL.deletingPathExtension().lastPathComponent).\(token).partial.flac"
        )

        let commonFormat: AVAudioCommonFormat = configuration.bitDepth == .bits16 ? .pcmFormatInt16 : .pcmFormatInt32
        guard let processingFormat = AVAudioFormat(
            commonFormat: commonFormat,
            sampleRate: Double(configuration.sampleRate),
            channels: AVAudioChannelCount(configuration.channelCount),
            interleaved: false
        ) else {
            throw FLACEncoderError.invalidConfiguration(
                "no PCM format for \(configuration.sampleRate) Hz, \(configuration.channelCount) channels"
            )
        }
        self.processingFormat = processingFormat

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: Double(configuration.sampleRate),
            AVNumberOfChannelsKey: configuration.channelCount,
            AVLinearPCMBitDepthKey: configuration.bitDepth.rawValue,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        self.file = try AVAudioFile(
            forWriting: temporaryURL,
            settings: settings,
            commonFormat: commonFormat,
            interleaved: false
        )
    }

    deinit {
        // An encoder dropped without `finish()` publishes nothing and leaves nothing behind.
        file = nil
        if state == .writing {
            try? FileManager.default.removeItem(at: temporaryURL)
        }
    }

    /// Appends one buffer of audio.
    ///
    /// Accepted buffer formats, all of which must match the configured sample rate
    /// and channel count:
    ///
    /// - `.pcmFormatInt16`: taken as 16-bit samples. Under a 24-bit configuration
    ///   they are shifted up by 8 bits, which is exact.
    /// - `.pcmFormatInt32`: taken as AudioToolbox's left-aligned 32-bit container,
    ///   so the encoded sample is `value >> (32 - bitDepth)`.
    /// - `.pcmFormatFloat32`: quantized by clamping to `[-1, 1]`, multiplying by
    ///   `2^(bitDepth - 1)`, rounding with `.toNearestOrAwayFromZero`, then clamping
    ///   to `[-2^(bitDepth - 1), 2^(bitDepth - 1) - 1]`.
    ///
    /// Interleaved and non-interleaved buffers are both accepted.
    public func write(_ buffer: AVAudioPCMBuffer) throws {
        guard state == .writing, let file else { throw FLACEncoderError.encoderNotWritable }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        let format = buffer.format
        guard Int(format.channelCount) == configuration.channelCount else {
            throw FLACEncoderError.formatMismatch(
                "buffer has \(format.channelCount) channels, encoder expects \(configuration.channelCount)"
            )
        }
        guard abs(format.sampleRate - Double(configuration.sampleRate)) < 0.001 else {
            throw FLACEncoderError.formatMismatch(
                "buffer is \(format.sampleRate) Hz, encoder expects \(configuration.sampleRate) Hz"
            )
        }

        let channels = configuration.channelCount
        let sampleCount = frames * channels
        if scratch.count < sampleCount { scratch = [Int32](repeating: 0, count: sampleCount) }
        try scratch.withUnsafeMutableBufferPointer { canonical in
            try readCanonicalSamples(from: buffer, frames: frames, into: canonical)
        }

        // Hash exactly what was handed to the encoder, frame-major, so verification
        // never has to hold the session in memory.
        scratch.withUnsafeBufferPointer { canonical in
            var bytes = [UInt8]()
            bytes.reserveCapacity(sampleCount * 4)
            for index in 0..<sampleCount {
                let bits = UInt32(bitPattern: canonical[index])
                bytes.append(UInt8(truncatingIfNeeded: bits))
                bytes.append(UInt8(truncatingIfNeeded: bits >> 8))
                bytes.append(UInt8(truncatingIfNeeded: bits >> 16))
                bytes.append(UInt8(truncatingIfNeeded: bits >> 24))
            }
            inputHash.update(data: bytes)
        }

        let staging = try stagingBuffer(forFrames: AVAudioFrameCount(frames))
        staging.frameLength = AVAudioFrameCount(frames)
        scratch.withUnsafeBufferPointer { canonical in
            switch configuration.bitDepth {
            case .bits16:
                let destination = staging.int16ChannelData!
                for channel in 0..<channels {
                    let output = destination[channel]
                    for frame in 0..<frames {
                        output[frame] = Int16(truncatingIfNeeded: canonical[frame * channels + channel])
                    }
                }
            case .bits24:
                let destination = staging.int32ChannelData!
                for channel in 0..<channels {
                    let output = destination[channel]
                    for frame in 0..<frames {
                        // AudioToolbox carries 24 valid bits left-aligned in an Int32.
                        output[frame] = canonical[frame * channels + channel] << 8
                    }
                }
            }
        }

        try file.write(from: staging)
        framesWritten += Int64(frames)
    }

    /// Finalizes, verifies, checksums, and publishes the file.
    ///
    /// On success the temporary file no longer exists and `outputURL` does. On any
    /// failure the temporary file is removed and `outputURL` is left untouched —
    /// including an existing older file at that path, which is only replaced by the
    /// atomic rename at the very end.
    ///
    /// - Returns: The published file's format, verified frame count, size, and SHA-256.
    @discardableResult
    public func finish() throws -> FLACEncodeResult {
        guard state == .writing else { throw FLACEncoderError.encoderNotWritable }
        state = .closed

        do {
            guard framesWritten >= FLACEncoderConfiguration.minimumFrameCount else {
                // The system encoder writes nothing usable below one packet, so say
                // so plainly instead of letting verification report a corrupt file.
                throw FLACEncoderError.streamTooShort(
                    frames: framesWritten,
                    minimum: FLACEncoderConfiguration.minimumFrameCount
                )
            }
            // Releasing the writer finalizes the stream, which flushes the partial
            // final block and rewrites STREAMINFO with the real frame count.
            file = nil
            try testHooks.afterFinalize?(temporaryURL)

            let streamInfo = try verifyFinalizedFile()
            let byteCount = try FileManager.default.attributesOfItem(atPath: temporaryURL.path)[.size] as? UInt64 ?? 0
            let checksum = try Self.sha256(ofFileAt: temporaryURL)
            try publish()

            return FLACEncodeResult(
                url: outputURL,
                sampleRate: configuration.sampleRate,
                channelCount: configuration.channelCount,
                bitDepth: configuration.bitDepth,
                frameCount: framesWritten,
                byteCount: byteCount,
                sha256: checksum,
                streamInfo: streamInfo
            )
        } catch {
            // Close the writer before unlinking so nothing keeps writing into a
            // file no consumer can reach.
            file = nil
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    /// Abandons the encode and deletes the temporary file. `outputURL` is untouched.
    public func cancel() {
        guard state == .writing else { return }
        state = .closed
        file = nil
        try? FileManager.default.removeItem(at: temporaryURL)
    }

    // MARK: - Verification

    private func verifyFinalizedFile() throws -> FLACStreamInfo {
        let streamInfo = try FLACStreamInfo.read(from: temporaryURL)
        guard streamInfo.bitsPerSample == configuration.bitDepth.rawValue else {
            throw FLACEncoderError.verificationFailed(
                .bitDepthMismatch(expected: configuration.bitDepth.rawValue, found: streamInfo.bitsPerSample)
            )
        }
        guard streamInfo.channelCount == configuration.channelCount else {
            throw FLACEncoderError.verificationFailed(
                .channelCountMismatch(expected: configuration.channelCount, found: streamInfo.channelCount)
            )
        }
        guard streamInfo.sampleRate == configuration.sampleRate else {
            throw FLACEncoderError.verificationFailed(
                .sampleRateMismatch(expected: configuration.sampleRate, found: Double(streamInfo.sampleRate))
            )
        }

        let reader: AVAudioFile
        do {
            reader = try AVAudioFile(forReading: temporaryURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw FLACEncoderError.verificationFailed(.unreadableStream("\(error)"))
        }
        guard reader.fileFormat.channelCount == AVAudioChannelCount(configuration.channelCount) else {
            throw FLACEncoderError.verificationFailed(
                .channelCountMismatch(expected: configuration.channelCount, found: Int(reader.fileFormat.channelCount))
            )
        }
        guard abs(reader.fileFormat.sampleRate - Double(configuration.sampleRate)) < 0.001 else {
            throw FLACEncoderError.verificationFailed(
                .sampleRateMismatch(expected: configuration.sampleRate, found: reader.fileFormat.sampleRate)
            )
        }
        // No padding, and the partial final block was flushed.
        guard reader.length == framesWritten, streamInfo.totalFrames == UInt64(framesWritten) else {
            throw FLACEncoderError.verificationFailed(
                .frameCountMismatch(expected: framesWritten, decoded: reader.length, streamInfo: streamInfo.totalFrames)
            )
        }

        // Decoded Float32 is exact for 16- and 24-bit payloads, so re-applying the
        // documented quantizer recovers the integers the encoder was given.
        let channels = configuration.channelCount
        let chunk: AVAudioFrameCount = 4_096
        var decodedHash = SHA256()
        var decodedFrames: Int64 = 0
        do {
            while decodedFrames < reader.length {
                let requested = AVAudioFrameCount(min(Int64(chunk), reader.length - decodedFrames))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: requested) else {
                    throw FLACEncoderError.verificationFailed(.unreadableStream("could not allocate a decode buffer"))
                }
                try reader.read(into: buffer, frameCount: requested)
                let frames = Int(buffer.frameLength)
                guard frames > 0 else { break }
                let source = buffer.floatChannelData!
                var bytes = [UInt8]()
                bytes.reserveCapacity(frames * channels * 4)
                for frame in 0..<frames {
                    for channel in 0..<channels {
                        let bits = UInt32(bitPattern: quantize(source[channel][frame]))
                        bytes.append(UInt8(truncatingIfNeeded: bits))
                        bytes.append(UInt8(truncatingIfNeeded: bits >> 8))
                        bytes.append(UInt8(truncatingIfNeeded: bits >> 16))
                        bytes.append(UInt8(truncatingIfNeeded: bits >> 24))
                    }
                }
                decodedHash.update(data: bytes)
                decodedFrames += Int64(frames)
            }
        } catch let error as FLACEncoderError {
            throw error
        } catch {
            throw FLACEncoderError.verificationFailed(.unreadableStream("\(error)"))
        }

        guard decodedFrames == framesWritten else {
            throw FLACEncoderError.verificationFailed(
                .frameCountMismatch(expected: framesWritten, decoded: decodedFrames, streamInfo: streamInfo.totalFrames)
            )
        }
        let expected = inputHash.finalize()
        guard decodedHash.finalize() == expected else {
            throw FLACEncoderError.verificationFailed(
                .sampleMismatch(detail: "decoded PCM does not match the \(framesWritten) frames submitted")
            )
        }
        return streamInfo
    }

    private func publish() throws {
        let moved = temporaryURL.withUnsafeFileSystemRepresentation { source in
            outputURL.withUnsafeFileSystemRepresentation { destination in
                rename(source!, destination!)
            }
        }
        guard moved == 0 else {
            throw FLACEncoderError.publishFailed(errno: errno, temporaryURL: temporaryURL, finalURL: outputURL)
        }
    }

    // MARK: - Sample conversion

    private func quantize(_ sample: Float) -> Int32 {
        let scale = Float(configuration.bitDepth.scale)
        let clipped = min(1, max(-1, sample))
        let rounded = (clipped * scale).rounded(.toNearestOrAwayFromZero)
        return min(configuration.bitDepth.maximumSample, max(configuration.bitDepth.minimumSample, Int32(rounded)))
    }

    private func readCanonicalSamples(
        from buffer: AVAudioPCMBuffer,
        frames: Int,
        into canonical: UnsafeMutableBufferPointer<Int32>
    ) throws {
        let channels = configuration.channelCount
        let stride = buffer.stride
        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let source = buffer.floatChannelData else {
                throw FLACEncoderError.formatMismatch("float buffer has no channel data")
            }
            for channel in 0..<channels {
                let input = buffer.format.isInterleaved ? source[0] + channel : source[channel]
                for frame in 0..<frames {
                    canonical[frame * channels + channel] = quantize(input[frame * stride])
                }
            }
        case .pcmFormatInt16:
            guard let source = buffer.int16ChannelData else {
                throw FLACEncoderError.formatMismatch("int16 buffer has no channel data")
            }
            let shift = Int32(configuration.bitDepth.rawValue - 16)
            for channel in 0..<channels {
                let input = buffer.format.isInterleaved ? source[0] + channel : source[channel]
                for frame in 0..<frames {
                    canonical[frame * channels + channel] = Int32(input[frame * stride]) << shift
                }
            }
        case .pcmFormatInt32:
            guard let source = buffer.int32ChannelData else {
                throw FLACEncoderError.formatMismatch("int32 buffer has no channel data")
            }
            let shift = Int32(32 - configuration.bitDepth.rawValue)
            for channel in 0..<channels {
                let input = buffer.format.isInterleaved ? source[0] + channel : source[channel]
                for frame in 0..<frames {
                    canonical[frame * channels + channel] = input[frame * stride] >> shift
                }
            }
        default:
            throw FLACEncoderError.formatMismatch(
                "unsupported buffer format \(buffer.format); use Float32, Int16, or Int32 PCM"
            )
        }
    }

    private func stagingBuffer(forFrames frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        if let existing = stagingBuffer, existing.frameCapacity >= frames { return existing }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: frames) else {
            throw FLACEncoderError.invalidConfiguration("could not allocate a \(frames)-frame encode buffer")
        }
        stagingBuffer = buffer
        return buffer
    }

    // MARK: - Checksums

    /// Streams a file through SHA-256 without holding it in memory.
    public static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
