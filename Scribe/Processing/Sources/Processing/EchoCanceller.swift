import Foundation
import WebRTCBridge

/// The application's echo canceller: the policy layer over the pinned AEC3 bridge.
///
/// `WebRTCBridge.EchoCanceller` is deliberately a thin, opinion-free face over the
/// module. Everything section 5 asks for beyond "call the API correctly" lives
/// here: feeding render before the capture block it belongs to, declaring an
/// acoustic delay that came from the reconstructed timeline rather than from a
/// wall clock, resetting where the journal says the echo path changed, and —
/// crucially — putting the cleaned microphone back on its own capture timeline by
/// removing only the latency the DSP itself introduced.
///
/// That last figure is *measured*, not assumed. A probe of the real configured
/// module answers "how far did this build move the signal?" for the build that is
/// actually linked, so a future upstream bump cannot silently introduce an offset
/// that survives into the mix.
public final class EchoCanceller {
    public struct Configuration: Sendable, Equatable {
        /// 10 ms at 48 kHz, which is the block size AEC3 requires.
        public var blockFrames: Int
        public var renderChannelCount: Int
        /// Section 5 processes the microphone mono; the archived track keeps its
        /// own layout untouched.
        public var captureChannelCount: Int
        public var noiseSuppressionEnabled: Bool
        public var gainControllerEnabled: Bool
        public var highPassFilterEnabled: Bool

        public init(
            blockFrames: Int = timelineSampleRate / 100,
            renderChannelCount: Int = 2,
            captureChannelCount: Int = 1,
            noiseSuppressionEnabled: Bool = false,
            gainControllerEnabled: Bool = false,
            highPassFilterEnabled: Bool = true
        ) {
            self.blockFrames = blockFrames
            self.renderChannelCount = renderChannelCount
            self.captureChannelCount = captureChannelCount
            self.noiseSuppressionEnabled = noiseSuppressionEnabled
            self.gainControllerEnabled = gainControllerEnabled
            self.highPassFilterEnabled = highPassFilterEnabled
        }

        var bridgeConfiguration: WebRTCBridge.EchoCanceller.Configuration {
            WebRTCBridge.EchoCanceller.Configuration(
                renderSampleRate: Int32(timelineSampleRate),
                renderChannelCount: Int32(renderChannelCount),
                captureSampleRate: Int32(timelineSampleRate),
                captureChannelCount: Int32(captureChannelCount),
                echoCancellerEnabled: true,
                multiChannelRender: renderChannelCount > 1,
                highPassFilterEnabled: highPassFilterEnabled,
                noiseSuppressionEnabled: noiseSuppressionEnabled,
                gainControllerEnabled: gainControllerEnabled,
                exportLinearAECOutput: false
            )
        }
    }

    /// A place the adapted filter is discarded because the path it describes no
    /// longer exists.
    public struct Reconvergence: Sendable, Equatable {
        public let frame: Int64
        public let reason: String
        public let delaySamples: Int?

        public var seconds: Double { Double(frame) / Double(timelineSampleRate) }
    }

    public let configuration: Configuration
    /// Frames of latency the configured module introduces on the capture path,
    /// measured from this build at construction.
    public let processingLatencyFrames: Int
    public private(set) var reconvergences: [Reconvergence] = []
    /// The delay declared to the module right now, in samples.
    public private(set) var declaredDelaySamples: Int = 0

    public static var upstreamRevision: String { WebRTCBridge.EchoCanceller.upstreamRevision }

    private let module: WebRTCBridge.EchoCanceller
    private let plan: RenderDelayPlan
    /// Total frames the cleaned track must carry. The module only accepts whole
    /// 10 ms blocks, so a session that is not a whole number of blocks long is
    /// padded into the module and bounded back out here.
    private let outputFrameCount: Int64
    private var resetFrames: [Int64]
    private var resetReasons: [Int64: String]
    private var inputFrame: Int64 = 0
    private var outputFrame: Int64 = 0
    private var pending: [Float] = []
    private var framesToDiscard: Int
    private var silenceRender: [[Float]]

    /// - Parameters:
    ///   - plan: the delay plan from ``RenderDelayEstimator``. A plan that does not
    ///     cancel still produces a canceller; it simply never runs the module.
    ///   - reconvergenceFrames: journaled discontinuities and device changes, in
    ///     48 kHz frames from the session origin.
    ///   - outputFrameCount: the microphone timeline's length. Nothing beyond it
    ///     is ever emitted, which is what lets a partial final block be padded
    ///     into the module without that padding reaching the mix.
    public init(
        configuration: Configuration = Configuration(),
        plan: RenderDelayPlan,
        reconvergenceFrames: [(frame: Int64, reason: String)] = [],
        outputFrameCount: Int64 = .max
    ) throws {
        self.configuration = configuration
        self.plan = plan
        self.outputFrameCount = outputFrameCount
        self.module = try WebRTCBridge.EchoCanceller(configuration: configuration.bridgeConfiguration)
        self.processingLatencyFrames = try Self.measureProcessingLatencyFrames(configuration: configuration)
        self.framesToDiscard = processingLatencyFrames
        self.silenceRender = Array(
            repeating: [Float](repeating: 0, count: configuration.blockFrames),
            count: configuration.renderChannelCount
        )

        // A declared delay moving is a reconvergence point in its own right: the
        // adapted filter describes an echo path that has just been contradicted.
        var reasons: [Int64: String] = [:]
        for entry in reconvergenceFrames where entry.frame > 0 {
            reasons[entry.frame] = entry.reason
        }
        for frame in plan.delayChangeFrames where frame > 0 {
            reasons[frame, default: "declared render-to-capture delay changed"] = "declared render-to-capture delay changed"
        }
        self.resetReasons = reasons
        self.resetFrames = reasons.keys.sorted()

        if let delay = plan.delaySamples(atFrame: 0) {
            try declare(delaySamples: delay)
        }
    }

    /// Feeds one aligned pair of blocks and returns whatever cleaned microphone
    /// audio that completes, in order, on the microphone's own timeline.
    ///
    /// Both tracks already sit on one session grid, so block *i* of the reference
    /// and block *i* of the microphone are simultaneous by construction; the
    /// acoustic delay between them is declared to the module rather than being
    /// folded into an offset that would move the user's speech.
    ///
    /// Returns zero or more complete blocks. It returns nothing on the first call
    /// when the module carries latency, because the audio for the first output
    /// block is not finished arriving yet.
    @discardableResult
    public func process(reference: [[Float]], microphone: [Float]) throws -> [[Float]] {
        guard plan.decision.cancels else {
            // Nothing to cancel. The microphone is emitted unchanged and its
            // timeline is untouched, which is exactly what "retain the original"
            // means for a session with no echo path.
            inputFrame += Int64(microphone.count)
            outputFrame += Int64(microphone.count)
            return [microphone]
        }

        try applyResets(upTo: inputFrame)
        // The module takes whole 10 ms blocks only. A short final block is padded
        // with silence, which is also exactly the material needed to flush the
        // module's latency; `outputFrameCount` keeps that padding out of the mix.
        try module.analyzeRenderBlock(PlanarAudioBlock(channels: padded(normalizedRender(reference))))
        var output = PlanarAudioBlock(channelCount: configuration.captureChannelCount, frameCount: configuration.blockFrames)
        try module.processCaptureBlock(
            PlanarAudioBlock(channels: padded([microphone])),
            into: &output
        )
        pending.append(contentsOf: output[channel: 0])
        inputFrame += Int64(configuration.blockFrames)
        return drain()
    }

    /// Flushes the module's latency with silence so the last real microphone
    /// samples reach the output, then returns whatever remains.
    ///
    /// `frameCount` is the total the caller expects on the microphone timeline;
    /// the result is trimmed or zero-filled to end exactly there, which keeps the
    /// cleaned track the same length as the track it came from.
    public func finish(expectedFrameCount: Int64) throws -> [[Float]] {
        guard plan.decision.cancels else { return [] }
        var blocks: [[Float]] = []
        while outputFrame + Int64(pending.count) < expectedFrameCount {
            try applyResets(upTo: inputFrame)
            try module.analyzeRenderBlock(PlanarAudioBlock(channels: silenceRender))
            var output = PlanarAudioBlock(channelCount: configuration.captureChannelCount, frameCount: configuration.blockFrames)
            try module.processCaptureBlock(
                PlanarAudioBlock(channelCount: configuration.captureChannelCount, frameCount: configuration.blockFrames),
                into: &output
            )
            pending.append(contentsOf: output[channel: 0])
            inputFrame += Int64(configuration.blockFrames)
            blocks.append(contentsOf: drain())
        }
        let remaining = Int(max(0, expectedFrameCount - outputFrame))
        if remaining > 0 {
            var tail = Array(pending.prefix(remaining))
            if tail.count < remaining { tail.append(contentsOf: [Float](repeating: 0, count: remaining - tail.count)) }
            pending.removeFirst(min(remaining, pending.count))
            outputFrame += Int64(remaining)
            blocks.append(tail)
        }
        return blocks
    }

    public func metrics() -> EchoCancellerMetrics { module.metrics() }

    // MARK: - Internals

    private func drain() -> [[Float]] {
        // Compensating the module's own latency means dropping exactly the frames
        // it prepended, once. It is the only shift applied to the microphone: the
        // reference is never allowed to drag local speech earlier in the meeting.
        if framesToDiscard > 0 {
            let discard = min(framesToDiscard, pending.count)
            pending.removeFirst(discard)
            framesToDiscard -= discard
        }
        var blocks: [[Float]] = []
        while pending.count >= configuration.blockFrames,
              outputFrame + Int64(configuration.blockFrames) <= outputFrameCount {
            blocks.append(Array(pending.prefix(configuration.blockFrames)))
            pending.removeFirst(configuration.blockFrames)
            outputFrame += Int64(configuration.blockFrames)
        }
        return blocks
    }

    private func applyResets(upTo frame: Int64) throws {
        while let next = resetFrames.first, next <= frame {
            resetFrames.removeFirst()
            try module.reset()
            let delay = plan.delaySamples(atFrame: next)
            if let delay { try declare(delaySamples: delay) }
            reconvergences.append(Reconvergence(
                frame: next,
                reason: resetReasons[next] ?? "journaled discontinuity",
                delaySamples: delay
            ))
        }
    }

    private func declare(delaySamples: Int) throws {
        declaredDelaySamples = delaySamples
        let milliseconds = (Double(delaySamples) * 1_000 / Double(timelineSampleRate)).rounded()
        try module.setStreamDelay(milliseconds: Int32(milliseconds))
    }

    /// Extends every channel to a whole block with silence.
    private func padded(_ channels: [[Float]]) -> [[Float]] {
        channels.map { channel in
            channel.count >= configuration.blockFrames
                ? Array(channel.prefix(configuration.blockFrames))
                : channel + [Float](repeating: 0, count: configuration.blockFrames - channel.count)
        }
    }

    /// Widens or narrows the reference to the configured render layout. A mono
    /// system track is duplicated rather than left silent on one side, because
    /// AEC3 models what it is told is playing.
    private func normalizedRender(_ channels: [[Float]]) -> [[Float]] {
        if channels.count == configuration.renderChannelCount { return channels }
        if channels.count > configuration.renderChannelCount { return Array(channels.prefix(configuration.renderChannelCount)) }
        guard let last = channels.last else { return silenceRender }
        return channels + Array(repeating: last, count: configuration.renderChannelCount - channels.count)
    }

    /// Measures how many frames the configured module delays the capture path.
    ///
    /// A fresh instance is fed silence on the render path and a deterministic
    /// broadband probe on the capture path; the lag of the strongest normalized
    /// correlation between what went in and what came out is the latency. AEC3 is
    /// designed to be time-aligned and this is expected to be zero, but "expected"
    /// is not the same as "true of the build that is linked", and the compensation
    /// applied to the user's speech should not rest on a documentation claim.
    public static func measureProcessingLatencyFrames(configuration: Configuration = Configuration()) throws -> Int {
        let module = try WebRTCBridge.EchoCanceller(configuration: configuration.bridgeConfiguration)
        let blockFrames = configuration.blockFrames
        let blocks = 40
        let total = blockFrames * blocks

        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        func noise() -> Float {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Float(Int32(truncatingIfNeeded: Int64(bitPattern: state))) / Float(Int32.max) * 0.25
        }
        // Band-limited away from DC so the enabled high-pass filter cannot bias
        // the correlation towards a lag it did not actually introduce.
        var probe = [Float](repeating: 0, count: total)
        var previous: Float = 0
        for index in 0..<total {
            let sample = noise()
            probe[index] = sample - previous * 0.7
            previous = sample
        }

        let silence = Array(
            repeating: [Float](repeating: 0, count: blockFrames),
            count: configuration.renderChannelCount
        )
        var processed = [Float]()
        processed.reserveCapacity(total)
        for block in 0..<blocks {
            try module.analyzeRenderBlock(PlanarAudioBlock(channels: silence))
            let slice = Array(probe[(block * blockFrames)..<((block + 1) * blockFrames)])
            var output = PlanarAudioBlock(channelCount: configuration.captureChannelCount, frameCount: blockFrames)
            try module.processCaptureBlock(PlanarAudioBlock(channels: [slice]), into: &output)
            processed.append(contentsOf: output[channel: 0])
        }

        // Ignore the first block: the module's own start-up is not steady-state
        // latency, and a filter warming up correlates poorly at every lag.
        let analysisStart = blockFrames
        var bestLag = 0
        var bestCorrelation = -Double.infinity
        for lag in 0...blockFrames {
            var cross = 0.0, inputEnergy = 0.0, outputEnergy = 0.0
            var index = analysisStart
            while index + lag < total {
                let a = Double(probe[index]), b = Double(processed[index + lag])
                cross += a * b
                inputEnergy += a * a
                outputEnergy += b * b
                index += 1
            }
            guard inputEnergy > 1e-12, outputEnergy > 1e-12 else { continue }
            let correlation = cross / (inputEnergy * outputEnergy).squareRoot()
            if correlation > bestCorrelation {
                bestCorrelation = correlation
                bestLag = lag
            }
        }
        // A probe that does not survive the module at all says nothing about
        // latency; compensating on a guess would be worse than compensating none.
        return bestCorrelation >= 0.5 ? bestLag : 0
    }
}
