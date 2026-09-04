import Foundation
import Testing

@testable import WebRTCBridge

/// A small deterministic noise source, so a failure is always reproducible.
private struct Noise {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> Float {
        // xorshift64*, adequate for a broadband test excitation.
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        let value = state &* 0x2545_F491_4F6C_DD1D
        return Float(Int32(truncatingIfNeeded: value >> 32)) / Float(Int32.max)
    }
}

private func energy(_ samples: ArraySlice<Float>) -> Double {
    samples.reduce(0.0) { $0 + Double($1) * Double($1) }
}

@Suite("WebRTC AEC3 bridge")
struct EchoCancellerTests {
    static let sampleRate: Int32 = 48_000
    static let framesPerBlock = 480  // 10 ms at 48 kHz

    @Test("Constructs with the configuration section 5 asks for")
    func constructsWithPlannedDefaults() throws {
        let configuration = EchoCanceller.Configuration.scribeDefault
        #expect(configuration.renderSampleRate == Self.sampleRate)
        #expect(configuration.captureSampleRate == Self.sampleRate)
        #expect(configuration.renderChannelCount == 2, "stereo render input")
        #expect(configuration.captureChannelCount == 1, "mono capture")
        #expect(configuration.echoCancellerEnabled)
        #expect(configuration.gainControllerEnabled == false, "AGC off by default")
        #expect(configuration.noiseSuppressionEnabled == false, "noise suppression off by default")

        let canceller = try EchoCanceller()
        #expect(canceller.renderBlockFrameCount == Self.framesPerBlock)
        #expect(canceller.captureBlockFrameCount == Self.framesPerBlock)
    }

    @Test("Reports the pinned upstream revision it was linked against")
    func reportsUpstreamRevision() {
        let revision = EchoCanceller.upstreamRevision
        #expect(revision.contains("webrtc-audio-processing 2.1"))
        #expect(revision.contains("846fe90a289f58b7c9303a635142aa2c7caa93e5"))
        #expect(revision.contains("M131"))
    }

    /// The exit criterion for this objective: 480-sample blocks through both
    /// paths, then metrics, with no leak under Address Sanitizer.
    @Test("Pushes 480-sample blocks through both paths and reads metrics")
    func pushesBlocksThroughBothPathsAndReadsMetrics() throws {
        let canceller = try EchoCanceller()
        let delayMilliseconds: Int32 = 30
        try canceller.setStreamDelay(milliseconds: delayMilliseconds)
        #expect(canceller.streamDelayMilliseconds == delayMilliseconds)

        var noise = Noise(seed: 0x5C21_BE00_1234_5678)
        // A pure far-end case: the microphone hears only a delayed, attenuated
        // copy of playback, which is what AEC3 should be able to remove.
        let delayFrames = Int(delayMilliseconds) * Int(Self.sampleRate) / 1000
        let echoGain: Float = 0.5
        var echoHistory = [Float](repeating: 0, count: delayFrames)
        var historyIndex = 0

        var render = PlanarAudioBlock(channelCount: 2, frameCount: Self.framesPerBlock)
        var capture = PlanarAudioBlock(channelCount: 1, frameCount: Self.framesPerBlock)
        var cleaned = PlanarAudioBlock(channelCount: 1, frameCount: Self.framesPerBlock)

        let blockCount = 400  // 4 seconds, comfortably past convergence
        let measureFromBlock = 300  // measure only the last second
        var inputEnergy = 0.0
        var outputEnergy = 0.0

        for block in 0 ..< blockCount {
            for frame in 0 ..< Self.framesPerBlock {
                let sample = noise.next() * 0.25
                // Slightly different content per channel: the two playback
                // channels of a real meeting are not identical.
                render[channel: 0, frame: frame] = sample
                render[channel: 1, frame: frame] = sample * 0.8

                let echoed = echoHistory[historyIndex] * echoGain
                echoHistory[historyIndex] = sample
                historyIndex = (historyIndex + 1) % delayFrames
                capture[channel: 0, frame: frame] = echoed
            }

            try canceller.analyzeRenderBlock(render)
            try canceller.setStreamDelay(milliseconds: delayMilliseconds)
            try canceller.processCaptureBlock(capture, into: &cleaned)

            if block >= measureFromBlock {
                inputEnergy += energy(capture[channel: 0])
                outputEnergy += energy(cleaned[channel: 0])
            }
        }

        #expect(inputEnergy > 0, "the fixture must actually contain echo")

        let metrics = canceller.metrics()
        #expect(metrics.echoReturnLossEnhancement != nil,
                "AEC3 should report ERLE once the filter has converged")
        #expect(metrics.delayMilliseconds != nil,
                "AEC3 should report a delay estimate")

        // Not the section 8 release gate — that is measured on fixtures in a
        // later objective. This only has to show the canceller is doing work.
        let reductionDB = 10 * log10(inputEnergy / max(outputEnergy, .leastNormalMagnitude))
        #expect(reductionDB > 10,
                "expected clear echo reduction on a far-end-only fixture, got \(reductionDB) dB")
        print("far-end-only echo reduction: \(reductionDB) dB; " +
              "ERLE: \(String(describing: metrics.echoReturnLossEnhancement)); " +
              "delay estimate: \(String(describing: metrics.delayMilliseconds)) ms")
    }

    @Test("Rejects a block that is not exactly 10 ms")
    func rejectsWrongBlockSize() throws {
        let canceller = try EchoCanceller()
        let shortRender = PlanarAudioBlock(channelCount: 2, frameCount: 441)
        #expect(throws: EchoCancellerError(status: .unexpectedBlockSize)) {
            try canceller.analyzeRenderBlock(shortRender)
        }

        let shortCapture = PlanarAudioBlock(channelCount: 1, frameCount: 256)
        var out = PlanarAudioBlock(channelCount: 1, frameCount: 256)
        #expect(throws: EchoCancellerError(status: .unexpectedBlockSize)) {
            try canceller.processCaptureBlock(shortCapture, into: &out)
        }
    }

    @Test("Rejects a block whose channel count does not match the configuration")
    func rejectsChannelCountMismatch() throws {
        let canceller = try EchoCanceller()
        let monoRender = PlanarAudioBlock(channelCount: 1, frameCount: Self.framesPerBlock)
        #expect(throws: EchoCancellerError(status: .channelCountMismatch)) {
            try canceller.analyzeRenderBlock(monoRender)
        }

        let stereoCapture = PlanarAudioBlock(channelCount: 2, frameCount: Self.framesPerBlock)
        var out = PlanarAudioBlock(channelCount: 2, frameCount: Self.framesPerBlock)
        #expect(throws: EchoCancellerError(status: .channelCountMismatch)) {
            try canceller.processCaptureBlock(stereoCapture, into: &out)
        }
    }

    @Test("Refuses to construct with a sample rate the module cannot process")
    func rejectsUnsupportedSampleRate() {
        var configuration = EchoCanceller.Configuration.scribeDefault
        configuration.captureSampleRate = 44_100
        #expect(throws: EchoCancellerError(status: .unsupportedSampleRate)) {
            _ = try EchoCanceller(configuration: configuration)
        }
    }

    @Test("Reset drops the adapted filter and leaves the module usable")
    func resetReturnsToInitialState() throws {
        let canceller = try EchoCanceller()
        try canceller.setStreamDelay(milliseconds: 45)
        #expect(canceller.streamDelayMilliseconds == 45)

        var render = PlanarAudioBlock(channelCount: 2, frameCount: Self.framesPerBlock)
        var capture = PlanarAudioBlock(channelCount: 1, frameCount: Self.framesPerBlock)
        var noise = Noise(seed: 99)
        for frame in 0 ..< Self.framesPerBlock {
            let sample = noise.next() * 0.1
            render[channel: 0, frame: frame] = sample
            render[channel: 1, frame: frame] = sample
            capture[channel: 0, frame: frame] = sample * 0.3
        }
        try canceller.analyzeRenderBlock(render)
        try canceller.processCaptureBlock(&capture)

        try canceller.reset()
        // The adapted filter is gone but the declared delay is a caller-supplied
        // property that upstream keeps across Initialize(). The bridge mirrors
        // that rather than inventing its own semantics.
        #expect(canceller.streamDelayMilliseconds == 45)

        // Still usable afterwards; a reconvergence must not need a new instance.
        try canceller.setStreamDelay(milliseconds: 60)
        #expect(canceller.streamDelayMilliseconds == 60)
        try canceller.analyzeRenderBlock(render)
        try canceller.processCaptureBlock(&capture)
        _ = canceller.metrics()
    }

    @Test("Processing in place matches processing into a separate block")
    func inPlaceMatchesOutOfPlace() throws {
        let a = try EchoCanceller()
        let b = try EchoCanceller()
        var noise = Noise(seed: 4242)
        var render = PlanarAudioBlock(channelCount: 2, frameCount: Self.framesPerBlock)
        var capture = PlanarAudioBlock(channelCount: 1, frameCount: Self.framesPerBlock)
        for frame in 0 ..< Self.framesPerBlock {
            let sample = noise.next() * 0.2
            render[channel: 0, frame: frame] = sample
            render[channel: 1, frame: frame] = sample
            capture[channel: 0, frame: frame] = sample * 0.4
        }

        var outOfPlace = PlanarAudioBlock(channelCount: 1, frameCount: Self.framesPerBlock)
        try a.analyzeRenderBlock(render)
        try a.processCaptureBlock(capture, into: &outOfPlace)

        var inPlace = capture
        try b.analyzeRenderBlock(render)
        try b.processCaptureBlock(&inPlace)

        #expect(inPlace == outOfPlace)
    }

    /// Construction and teardown is where a bridge leaks. Repeating it gives
    /// Address Sanitizer something to catch.
    @Test("Repeated construction and teardown leaves nothing behind")
    func repeatedConstructionAndTeardown() throws {
        for _ in 0 ..< 25 {
            let canceller = try EchoCanceller()
            var render = PlanarAudioBlock(channelCount: 2, frameCount: Self.framesPerBlock)
            var capture = PlanarAudioBlock(channelCount: 1, frameCount: Self.framesPerBlock)
            render[channel: 0, frame: 0] = 0.1
            try canceller.setStreamDelay(milliseconds: 20)
            try canceller.analyzeRenderBlock(render)
            try canceller.processCaptureBlock(&capture)
            _ = canceller.metrics()
        }
    }
}
