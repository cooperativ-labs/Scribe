import Foundation

/// Output sample depth for a FLAC export.
///
/// FLAC stores integer PCM. The recorder archives native float CAF segments
/// separately, so quantization to one of these depths is the documented,
/// intentional conversion point rather than a hidden loss.
public enum FLACBitDepth: Int, Sendable, Hashable, CaseIterable, Codable {
    case bits16 = 16
    case bits24 = 24

    /// Largest magnitude an encoded sample may take, as `2^(bits - 1)`.
    var scale: Int32 { Int32(1) << Int32(rawValue - 1) }

    var minimumSample: Int32 { -scale }
    var maximumSample: Int32 { scale - 1 }
}

/// Format of a FLAC export.
///
/// The plan's export matrix is 44.1 / 48 / 96 kHz in mono and stereo at 24 bits;
/// `validatedSampleRates` and `validatedChannelCounts` record that matrix. Other
/// values inside FLAC's own limits are accepted because every encode is verified
/// by decoding the finished file, so an unsupported combination fails loudly at
/// encode time instead of publishing a bad export.
public struct FLACEncoderConfiguration: Sendable, Hashable, Codable {
    /// Sample rates covered by the feasibility measurements in
    /// `docs/feasibility/flac.md` and by this package's test matrix.
    public static let validatedSampleRates: Set<Int> = [44_100, 48_000, 96_000]

    /// Channel layouts the recorder exports: mono and stereo.
    public static let validatedChannelCounts: Set<Int> = [1, 2]

    /// Shortest stream the system FLAC encoder can produce, in frames.
    ///
    /// AudioToolbox encodes FLAC in 4,608-frame packets and discards a lone
    /// partial packet: a stream shorter than this leaves a 42-byte stub with no
    /// `fLaC` magic number rather than a short file. The behaviour is identical
    /// through `AVAudioFile` and `ExtAudioFile` and at every supported rate, so it
    /// is a property of the codec rather than of this bridge. Longer streams do
    /// flush their partial final packet correctly. `FLACEncoder.finish()` reports
    /// `FLACEncoderError.streamTooShort` instead of publishing such a stub. At
    /// 48 kHz the floor is 96 ms.
    public static let minimumFrameCount: Int64 = 4_608

    public var sampleRate: Int
    public var channelCount: Int
    public var bitDepth: FLACBitDepth

    public init(sampleRate: Int, channelCount: Int, bitDepth: FLACBitDepth = .bits24) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitDepth = bitDepth
    }

    /// True when this configuration is part of the measured export matrix.
    public var isValidated: Bool {
        Self.validatedSampleRates.contains(sampleRate) && Self.validatedChannelCounts.contains(channelCount)
    }

    func validate() throws {
        // FLAC's own stream limits: 20-bit sample rate field, 3-bit channel field.
        guard sampleRate > 0, sampleRate <= 655_350 else {
            throw FLACEncoderError.invalidConfiguration("sample rate \(sampleRate) is outside the FLAC range 1...655350")
        }
        guard (1...8).contains(channelCount) else {
            throw FLACEncoderError.invalidConfiguration("channel count \(channelCount) is outside the FLAC range 1...8")
        }
    }
}
