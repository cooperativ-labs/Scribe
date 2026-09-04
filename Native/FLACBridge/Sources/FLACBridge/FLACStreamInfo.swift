import Foundation

/// The fields of a FLAC `STREAMINFO` metadata block that describe the stream.
///
/// Read straight from the file rather than through a decoder so verification can
/// tell "the container claims the right thing" apart from "the decoder produced
/// the right thing".
public struct FLACStreamInfo: Sendable, Hashable, Codable {
    public var sampleRate: Int
    public var channelCount: Int
    public var bitsPerSample: Int
    /// Total interchannel samples, i.e. frames. Zero means the encoder left the
    /// count unknown, which for a published file is itself a failure.
    public var totalFrames: UInt64

    /// Parses the mandatory `STREAMINFO` block that begins every FLAC file.
    ///
    /// - Throws: `FLACVerificationFailure.unreadableStream` when the magic number,
    ///   block header, or block length is not what the format requires.
    public static func read(from url: URL) throws -> FLACStreamInfo {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 42), header.count == 42 else {
            throw FLACEncoderError.verificationFailed(.unreadableStream("file is shorter than a STREAMINFO block"))
        }
        let bytes = [UInt8](header)
        guard Array(bytes[0..<4]) == Array("fLaC".utf8) else {
            throw FLACEncoderError.verificationFailed(.unreadableStream("missing fLaC magic number"))
        }
        guard bytes[4] & 0x7F == 0 else {
            throw FLACEncoderError.verificationFailed(.unreadableStream("first metadata block is not STREAMINFO"))
        }
        let blockLength = (Int(bytes[5]) << 16) | (Int(bytes[6]) << 8) | Int(bytes[7])
        guard blockLength == 34 else {
            throw FLACEncoderError.verificationFailed(.unreadableStream("STREAMINFO length is \(blockLength), expected 34"))
        }
        // Bytes 18..25 pack sample rate (20 bits), channels - 1 (3 bits),
        // bits per sample - 1 (5 bits), and total samples (36 bits).
        var packed: UInt64 = 0
        for byte in bytes[18..<26] { packed = (packed << 8) | UInt64(byte) }
        return FLACStreamInfo(
            sampleRate: Int(packed >> 44),
            channelCount: Int((packed >> 41) & 0x7) + 1,
            bitsPerSample: Int((packed >> 36) & 0x1F) + 1,
            totalFrames: packed & 0x0000_000F_FFFF_FFFF
        )
    }
}
