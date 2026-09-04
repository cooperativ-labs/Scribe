import Foundation

/// A reason a finished file failed its post-finalization verification pass.
///
/// The system encoder exposes no libFLAC-style verify mode, so the encoder
/// decodes what it just wrote and compares it against the integer PCM it was
/// given. Any of these cases means the temporary file is discarded and the
/// final name is never created.
public enum FLACVerificationFailure: Sendable, Hashable, Codable {
    /// The file could not be parsed as FLAC, or its `STREAMINFO` block is malformed.
    case unreadableStream(String)
    /// `STREAMINFO` or the decoder reported a different bit depth than requested.
    case bitDepthMismatch(expected: Int, found: Int)
    /// The decoded stream reports a different sample rate than requested.
    case sampleRateMismatch(expected: Int, found: Double)
    /// The decoded stream reports a different channel count than requested.
    case channelCountMismatch(expected: Int, found: Int)
    /// Frames written and frames recoverable from the file disagree, which is what
    /// an unflushed final block or encoder padding would look like.
    case frameCountMismatch(expected: Int64, decoded: Int64, streamInfo: UInt64)
    /// Decoded integer PCM differs from the integer PCM handed to the encoder.
    case sampleMismatch(detail: String)
}

public enum FLACEncoderError: Error, Sendable {
    /// The requested format is outside what FLAC can represent.
    case invalidConfiguration(String)
    /// The destination directory does not exist, so no temporary sibling can be written.
    case missingDestinationDirectory(URL)
    /// A submitted buffer's format does not match the encoder's configuration.
    case formatMismatch(String)
    /// `write(_:)` was called after `finish()` or `cancel()`.
    case encoderNotWritable
    /// Fewer frames were submitted than the system encoder can represent; see
    /// `FLACEncoderConfiguration.minimumFrameCount`. Nothing was published.
    case streamTooShort(frames: Int64, minimum: Int64)
    /// The finished file did not survive verification; nothing was published.
    case verificationFailed(FLACVerificationFailure)
    /// The verified temporary file could not be renamed onto the final path.
    case publishFailed(errno: Int32, temporaryURL: URL, finalURL: URL)
}

extension FLACEncoderError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidConfiguration(let detail):
            "Invalid FLAC configuration: \(detail)."
        case .missingDestinationDirectory(let url):
            "FLAC destination directory does not exist: \(url.path)."
        case .formatMismatch(let detail):
            "FLAC input buffer format mismatch: \(detail)."
        case .encoderNotWritable:
            "The FLAC encoder is no longer accepting audio."
        case .streamTooShort(let frames, let minimum):
            "The FLAC encoder received \(frames) frames; the system encoder cannot write fewer than \(minimum)."
        case .verificationFailed(let failure):
            "FLAC verification failed, nothing was published: \(failure)."
        case .publishFailed(let code, let temporaryURL, let finalURL):
            "Could not rename \(temporaryURL.lastPathComponent) to \(finalURL.lastPathComponent): errno \(code)."
        }
    }
}
