import CWebRTCAPM
import Foundation

/// An error reported by the pinned WebRTC Audio Processing Module bridge.
public struct EchoCancellerError: Error, Equatable, CustomStringConvertible {
    public let status: ScribeAPMStatus

    public init(status: ScribeAPMStatus) {
        self.status = status
    }

    public var description: String {
        String(cString: scribe_apm_status_description(status))
    }
}

/// Echo metrics reported by AEC3.
///
/// Every value is optional because the module only publishes a figure once it
/// has one worth publishing. An absent `echoReturnLossEnhancement` means the
/// filter has not converged yet, not that cancellation is zero.
public struct EchoCancellerMetrics: Equatable, Sendable {
    /// ERL, in dB: how much the echo path itself attenuates the far-end signal.
    public var echoReturnLoss: Double?
    /// ERLE, in dB: how much of the remaining echo the canceller removed.
    public var echoReturnLossEnhancement: Double?
    /// The canceller's instantaneous render-to-capture delay estimate, in ms.
    public var delayMilliseconds: Int32?
    /// Median delay estimate over the aggregation window, in ms.
    public var medianDelayMilliseconds: Int32?
    /// Standard deviation of the delay estimate, in ms.
    public var delayStandardDeviationMilliseconds: Int32?
    /// Fraction of the window in which the linear filter diverged, 0...1.
    public var divergentFilterFraction: Double?
    /// Likelihood that residual echo remains in the output, 0...1.
    public var residualEchoLikelihood: Double?
    /// Highest residual echo likelihood over the recent window, 0...1.
    public var residualEchoLikelihoodRecentMax: Double?

    fileprivate init(_ raw: ScribeAPMMetrics) {
        echoReturnLoss = raw.has_echo_return_loss ? raw.echo_return_loss : nil
        echoReturnLossEnhancement =
            raw.has_echo_return_loss_enhancement ? raw.echo_return_loss_enhancement : nil
        delayMilliseconds = raw.has_delay_ms ? raw.delay_ms : nil
        medianDelayMilliseconds = raw.has_delay_median_ms ? raw.delay_median_ms : nil
        delayStandardDeviationMilliseconds =
            raw.has_delay_standard_deviation_ms ? raw.delay_standard_deviation_ms : nil
        divergentFilterFraction =
            raw.has_divergent_filter_fraction ? raw.divergent_filter_fraction : nil
        residualEchoLikelihood =
            raw.has_residual_echo_likelihood ? raw.residual_echo_likelihood : nil
        residualEchoLikelihoodRecentMax =
            raw.has_residual_echo_likelihood_recent_max
            ? raw.residual_echo_likelihood_recent_max : nil
    }
}

/// The offline echo canceller: a thin, owning Swift face over AEC3.
///
/// Not thread-safe, deliberately. `IMPLEMENTATION_PLAN.md` section 2 keeps DSP on
/// one serial queue, and the underlying module makes the same demand: render and
/// capture calls must not overlap.
public final class EchoCanceller {
    /// Everything fixed at construction time.
    public struct Configuration: Equatable, Sendable {
        /// Sample rate of the far-end (system playback) signal.
        public var renderSampleRate: Int32
        /// Channel count of the far-end signal. Stereo by default, per section 5.
        public var renderChannelCount: Int32
        /// Sample rate of the near-end (microphone) signal.
        public var captureSampleRate: Int32
        /// Channel count of the near-end signal. Mono by default, per section 5.
        public var captureChannelCount: Int32
        /// AEC3. On by default.
        public var echoCancellerEnabled: Bool
        /// Model each render channel separately instead of downmixing to mono.
        public var multiChannelRender: Bool
        /// High-pass filter on the capture path, which AEC3 expects.
        public var highPassFilterEnabled: Bool
        /// Noise suppression. Off by default, to isolate AEC behaviour.
        public var noiseSuppressionEnabled: Bool
        /// Automatic gain control. Off by default, to isolate AEC behaviour.
        public var gainControllerEnabled: Bool
        /// Ask AEC3 to also expose its linear filter output, for diagnostics.
        public var exportLinearAECOutput: Bool

        /// The defaults from section 5: 48 kHz, stereo render, mono capture,
        /// AEC3 on, AGC and noise suppression off.
        public static var scribeDefault: Configuration {
            Configuration(scribe_apm_default_config())
        }

        public init(
            renderSampleRate: Int32 = 48_000,
            renderChannelCount: Int32 = 2,
            captureSampleRate: Int32 = 48_000,
            captureChannelCount: Int32 = 1,
            echoCancellerEnabled: Bool = true,
            multiChannelRender: Bool = true,
            highPassFilterEnabled: Bool = true,
            noiseSuppressionEnabled: Bool = false,
            gainControllerEnabled: Bool = false,
            exportLinearAECOutput: Bool = false
        ) {
            self.renderSampleRate = renderSampleRate
            self.renderChannelCount = renderChannelCount
            self.captureSampleRate = captureSampleRate
            self.captureChannelCount = captureChannelCount
            self.echoCancellerEnabled = echoCancellerEnabled
            self.multiChannelRender = multiChannelRender
            self.highPassFilterEnabled = highPassFilterEnabled
            self.noiseSuppressionEnabled = noiseSuppressionEnabled
            self.gainControllerEnabled = gainControllerEnabled
            self.exportLinearAECOutput = exportLinearAECOutput
        }

        fileprivate init(_ raw: ScribeAPMConfig) {
            renderSampleRate = raw.render_sample_rate_hz
            renderChannelCount = raw.render_channels
            captureSampleRate = raw.capture_sample_rate_hz
            captureChannelCount = raw.capture_channels
            echoCancellerEnabled = raw.echo_canceller_enabled
            multiChannelRender = raw.multi_channel_render
            highPassFilterEnabled = raw.high_pass_filter_enabled
            noiseSuppressionEnabled = raw.noise_suppression_enabled
            gainControllerEnabled = raw.gain_controller_enabled
            exportLinearAECOutput = raw.export_linear_aec_output
        }

        fileprivate var raw: ScribeAPMConfig {
            var config = scribe_apm_default_config()
            config.render_sample_rate_hz = renderSampleRate
            config.render_channels = renderChannelCount
            config.capture_sample_rate_hz = captureSampleRate
            config.capture_channels = captureChannelCount
            config.echo_canceller_enabled = echoCancellerEnabled
            config.multi_channel_render = multiChannelRender
            config.high_pass_filter_enabled = highPassFilterEnabled
            config.noise_suppression_enabled = noiseSuppressionEnabled
            config.gain_controller_enabled = gainControllerEnabled
            config.export_linear_aec_output = exportLinearAECOutput
            return config
        }
    }

    private let handle: OpaquePointer
    public let configuration: Configuration

    /// The upstream release this bridge was compiled and linked against.
    public static var upstreamRevision: String {
        String(cString: scribe_apm_upstream_revision())
    }

    public init(configuration: Configuration = .scribeDefault) throws {
        var raw = configuration.raw
        var status = ScribeAPMStatus.success
        guard let handle = scribe_apm_create(&raw, &status) else {
            throw EchoCancellerError(
                status: status == .success ? .creationFailed : status)
        }
        self.handle = handle
        self.configuration = configuration
    }

    deinit {
        scribe_apm_destroy(handle)
    }

    /// Frames in one 10 ms render block: 480 at 48 kHz.
    public var renderBlockFrameCount: Int {
        scribe_apm_render_block_frames(handle)
    }

    /// Frames in one 10 ms capture block: 480 at 48 kHz.
    public var captureBlockFrameCount: Int {
        scribe_apm_capture_block_frames(handle)
    }

    /// Feed the far-end block whose echo the next capture block will contain.
    public func analyzeRenderBlock(_ block: PlanarAudioBlock) throws {
        let status = block.withUnsafeChannelPointers { pointers in
            scribe_apm_analyze_render(handle, pointers, block.channelCount, block.frameCount)
        }
        try Self.check(status)
    }

    /// Process one near-end block, writing the cleaned result into `output`.
    public func processCaptureBlock(
        _ input: PlanarAudioBlock,
        into output: inout PlanarAudioBlock
    ) throws {
        let inputChannelCount = input.channelCount
        let frameCount = input.frameCount
        let outputChannelCount = output.channelCount
        let status = input.withUnsafeChannelPointers { inputPointers in
            output.withUnsafeMutableChannelPointers { outputPointers in
                scribe_apm_process_capture(
                    handle, inputPointers, inputChannelCount,
                    outputPointers, outputChannelCount, frameCount)
            }
        }
        try Self.check(status)
    }

    /// Process one near-end block in place.
    public func processCaptureBlock(_ block: inout PlanarAudioBlock) throws {
        var output = block
        try processCaptureBlock(block, into: &output)
        block = output
    }

    /// The render-to-capture delay currently declared, in milliseconds.
    public var streamDelayMilliseconds: Int32 {
        scribe_apm_stream_delay_ms(handle)
    }

    /// Declare the render-to-capture delay for the blocks that follow.
    ///
    /// This is an acoustic property of the material being processed. Offline, it
    /// comes from the reconstructed timeline; it is never the wall-clock duration
    /// of a processing call.
    public func setStreamDelay(milliseconds: Int32) throws {
        try Self.check(scribe_apm_set_stream_delay_ms(handle, milliseconds))
    }

    /// Discard the adapted filter and start converging again.
    ///
    /// Call this at a documented discontinuity — an output route change, a device
    /// change, a gap in capture — where the old echo path no longer applies.
    ///
    /// The declared stream delay survives a reset, matching upstream. If the
    /// discontinuity also moved the delay, declare the new value afterwards.
    public func reset() throws {
        try Self.check(scribe_apm_reset(handle))
    }

    /// Read the current echo metrics.
    public func metrics() -> EchoCancellerMetrics {
        EchoCancellerMetrics(scribe_apm_metrics(handle))
    }

    private static func check(_ status: ScribeAPMStatus) throws {
        guard status == .success else {
            throw EchoCancellerError(status: status)
        }
    }
}
