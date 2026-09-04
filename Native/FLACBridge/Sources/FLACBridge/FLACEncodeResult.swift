import Foundation

/// What a successful encode published.
///
/// The fields here are the ones the session manifest records for a track:
/// the file, its frame count and duration, its size, and its checksum.
public struct FLACEncodeResult: Sendable, Hashable, Codable {
    /// The final path. It exists only because finalization and verification both succeeded.
    public var url: URL
    public var sampleRate: Int
    public var channelCount: Int
    public var bitDepth: FLACBitDepth
    /// Interchannel sample count handed to the encoder, confirmed against the decoded file.
    public var frameCount: Int64
    public var byteCount: UInt64
    /// Lowercase hex SHA-256 of the published file's bytes.
    public var sha256: String
    /// `STREAMINFO` as stored in the published file.
    public var streamInfo: FLACStreamInfo

    /// Duration in seconds, derived from the verified frame count.
    public var duration: Double { Double(frameCount) / Double(sampleRate) }
}
