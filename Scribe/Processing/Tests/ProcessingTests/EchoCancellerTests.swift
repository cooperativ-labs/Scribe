import Foundation
import Testing
import WebRTCBridge
@testable import Processing

// MARK: - Measured DSP latency

@Test func theCapturePathLatencyIsMeasuredRatherThanAssumed() throws {
    let frames = try EchoCanceller.measureProcessingLatencyFrames()
    // The pinned build delays the capture path by 430 frames — 8.96 ms — at a
    // probe correlation of 0.946, against -0.0005 at zero lag. AEC3 is widely
    // described as time-aligned, and for this build that is simply not true; had
    // the wrapper taken the description on trust, every cleaned microphone would
    // have sat 9 ms late against the system track it is mixed with and against
    // the original it came from.
    //
    // The number is pinned so an upstream bump has to be looked at rather than
    // silently changing where the user's speech lands.
    #expect(frames == 430, "measured \(frames) frames of capture-path latency")
}

@Test func aDeliberatelyDelayedProbeIsMeasuredAtItsDelay() throws {
    // The measurement above is only worth pinning if the probe can be trusted, so
    // this feeds it a signal whose delay is known by construction.
    let blockFrames = 480
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    let probe = (0..<(blockFrames * 20)).map { _ -> Float in
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return Float(Int32(truncatingIfNeeded: Int64(bitPattern: state))) / Float(Int32.max) * 0.25
    }
    let delay = 137
    let delayed = [Float](repeating: 0, count: delay) + probe.dropLast(delay)
    #expect(bestLag(input: probe, output: delayed, maximumLag: blockFrames) == delay)
}

private func bestLag(input: [Float], output: [Float], maximumLag: Int) -> Int {
    var bestLag = 0
    var best = -Double.infinity
    for lag in 0...maximumLag {
        var cross = 0.0, a = 0.0, b = 0.0
        var index = 0
        while index + lag < min(input.count, output.count) {
            let x = Double(input[index]), y = Double(output[index + lag])
            cross += x * y; a += x * x; b += y * y
            index += 1
        }
        guard a > 0, b > 0 else { continue }
        let correlation = cross / (a * b).squareRoot()
        if correlation > best { best = correlation; bestLag = lag }
    }
    return bestLag
}

// MARK: - Delay estimation

/// A deterministic reference, and a microphone that is that reference through a
/// short reverberant path at a known delay plus an independent near-end signal.
private struct EchoScene {
    let reference: [Float]
    let microphone: [Float]

    init(seconds: Double = 8, delay: Int, nearEndGain: Float = 0, echoGain: Float = 0.6, referenceSeed: UInt64 = 0x51ED_270B, nearEndSeed: UInt64 = 0x2545_F491) {
        let frames = Int(seconds * Double(timelineSampleRate))
        let reference = EchoScene.speech(frames: frames, seed: referenceSeed)
        let nearEnd = EchoScene.speech(frames: frames, seed: nearEndSeed)
        var microphone = [Float](repeating: 0, count: frames)
        let taps: [(Int, Float)] = [(0, 0.65), (223, 0.31), (617, 0.17), (1_133, 0.09)]
        for index in 0..<frames {
            var value: Float = 0
            for (offset, gain) in taps {
                let source = index - delay - offset
                if source >= 0 { value += gain * reference[source] }
            }
            microphone[index] = value * echoGain + nearEnd[index] * nearEndGain
        }
        self.reference = reference
        self.microphone = microphone
    }

    /// Noise-excited, envelope-shaped, and above all *independent* between seeds:
    /// two of these share no deterministic component, which is what a near-end
    /// signal has to be if it is to prove anything about preserving local speech.
    static func speech(frames: Int, seed: UInt64) -> [Float] {
        var state = seed | 1
        func next() -> Float {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Float(Int32(truncatingIfNeeded: Int64(bitPattern: state))) / Float(Int32.max)
        }
        var samples = [Float](repeating: 0, count: frames)
        var lowPass: Float = 0
        for index in 0..<frames {
            lowPass = lowPass * 0.7 + next() * 0.3
            let phrase = Double(index) / Double(timelineSampleRate) * 1.7
            let envelope = Float(max(0, sin(phrase * .pi)))
            samples[index] = lowPass * envelope * 0.5
        }
        return samples
    }
}

private func plan(_ scene: EchoScene, options: RenderDelayEstimator.Options = RenderDelayEstimator.Options()) -> RenderDelayPlan {
    let blockFrames = 480
    var offset = 0
    return RenderDelayEstimator(options: options, expectedFrameCount: Int64(scene.reference.count)).plan {
        guard offset < scene.reference.count else { return nil }
        let end = min(offset + blockFrames, scene.reference.count)
        defer { offset = end }
        return (reference: Array(scene.reference[offset..<end]), microphone: Array(scene.microphone[offset..<end]))
    }
}

@Test func aCleanEchoPathIsFoundAtItsTrueDelay() {
    let result = plan(EchoScene(delay: 1_440))
    guard case .cancel(let segments) = result.decision else {
        Issue.record("expected cancellation, got \(result.decision)")
        return
    }
    #expect(segments.count == 1)
    #expect(abs(segments[0].delaySamples - 1_440) <= 480, "found \(segments[0].delaySamples)")
    #expect(segments[0].startFrame == 0, "the first segment must cover the session from its origin")
}

@Test func doubleTalkStillFindsTheDelayFromAgreementAcrossWindows() {
    // No single window is convincing when independent near-end speech runs at the
    // same level as the echo; several disjoint windows landing on the same lag is.
    let result = plan(EchoScene(delay: 1_440, nearEndGain: 1.0, echoGain: 0.5))
    guard case .cancel(let segments) = result.decision else {
        Issue.record("expected cancellation, got \(result.decision)")
        return
    }
    #expect(abs(segments[0].delaySamples - 1_440) <= 480, "found \(segments[0].delaySamples)")
}

@Test func aReferenceThatNeverPlaysIsNotAnEchoProblem() {
    let frames = 8 * timelineSampleRate
    var offset = 0
    let microphone = EchoScene.speech(frames: frames, seed: 0x1234)
    let result = RenderDelayEstimator(expectedFrameCount: Int64(frames)).plan {
        guard offset < frames else { return nil }
        let end = min(offset + 480, frames)
        defer { offset = end }
        return (reference: [Float](repeating: 0, count: end - offset), microphone: Array(microphone[offset..<end]))
    }
    #expect(result.decision == .noReferenceActivity)
}

@Test func aReferenceThatReachesNothingLeavesTheMicrophoneAlone() {
    // Playback and an unrelated near-end signal: a real headphone session. There
    // is nothing to cancel, and refusing to publish would be wrong.
    let scene = EchoScene(delay: 1_440, nearEndGain: 1.0, echoGain: 0)
    guard case .noEchoPath = plan(scene).decision else {
        Issue.record("expected no echo path, got \(plan(scene).decision)")
        return
    }
}

@Test func aCorrelationPeakAtAPhysicallyImpossibleLagIsNotAnEchoPath() {
    // The microphone carries an exact, undelayed copy of the reference. No room
    // produces that, so it is not an echo path however well it correlates; acting
    // on it would point the canceller at the near end.
    let frames = 8 * timelineSampleRate
    let reference = EchoScene.speech(frames: frames, seed: 0x51ED_270B)
    var offset = 0
    let result = RenderDelayEstimator(expectedFrameCount: Int64(frames)).plan {
        guard offset < frames else { return nil }
        let end = min(offset + 480, frames)
        defer { offset = end }
        return (reference: Array(reference[offset..<end]), microphone: Array(reference[offset..<end]))
    }
    guard case .noEchoPath = result.decision else {
        Issue.record("expected no echo path, got \(result.decision)")
        return
    }
}

@Test func aDelayThatMovesMidSessionBecomesTwoSegments() {
    let frames = 16 * timelineSampleRate
    let reference = EchoScene.speech(frames: frames, seed: 0x51ED_270B)
    var microphone = [Float](repeating: 0, count: frames)
    for index in 0..<frames {
        let delay = index < frames / 2 ? 1_440 : 3_360
        let source = index - delay
        if source >= 0 { microphone[index] = reference[source] * 0.6 }
    }
    var offset = 0
    let result = RenderDelayEstimator(options: RenderDelayEstimator.Options(maximumDelaySamples: 5_760), expectedFrameCount: Int64(frames)).plan {
        guard offset < frames else { return nil }
        let end = min(offset + 480, frames)
        defer { offset = end }
        return (reference: Array(reference[offset..<end]), microphone: Array(microphone[offset..<end]))
    }
    guard case .cancel(let segments) = result.decision else {
        Issue.record("expected cancellation, got \(result.decision)")
        return
    }
    #expect(segments.count == 2, "delays found: \(segments.map(\.delaySamples))")
    #expect(segments.first?.startFrame == 0)
    if segments.count == 2 {
        #expect(abs(segments[0].delaySamples - 1_440) <= 480)
        #expect(abs(segments[1].delaySamples - 3_360) <= 480)
        // The move is itself a reconvergence point: the adapted filter describes a
        // path that has just been contradicted.
        #expect(result.delayChangeFrames == [segments[1].startFrame])
    }
}

// MARK: - The canceller wrapper

@Test func cancellationKeepsTheMicrophoneOnItsOwnTimelineAndItsOwnLength() throws {
    let scene = EchoScene(seconds: 4, delay: 1_440, nearEndGain: 0.8)
    let result = plan(scene)
    let canceller = try EchoCanceller(plan: result)
    var output: [Float] = []
    var offset = 0
    while offset < scene.reference.count {
        let end = min(offset + 480, scene.reference.count)
        let reference = Array(scene.reference[offset..<end])
        for block in try canceller.process(reference: [reference, reference], microphone: Array(scene.microphone[offset..<end])) {
            output.append(contentsOf: block)
        }
        offset = end
    }
    for block in try canceller.finish(expectedFrameCount: Int64(scene.microphone.count)) {
        output.append(contentsOf: block)
    }
    #expect(output.count == scene.microphone.count)
    // The cleaned track must not have moved: a lag search against the input has to
    // find the near end where it always was, not shifted towards the reference.
    #expect(bestLag(input: scene.microphone, output: output, maximumLag: 960) == 0)
}

@Test func aPassThroughDecisionReturnsTheMicrophoneUnchanged() throws {
    let scene = EchoScene(seconds: 3, delay: 1_440, nearEndGain: 1, echoGain: 0)
    let canceller = try EchoCanceller(plan: plan(scene))
    var output: [Float] = []
    var offset = 0
    while offset < scene.microphone.count {
        let end = min(offset + 480, scene.microphone.count)
        let reference = Array(scene.reference[offset..<end])
        for block in try canceller.process(reference: [reference, reference], microphone: Array(scene.microphone[offset..<end])) {
            output.append(contentsOf: block)
        }
        offset = end
    }
    output.append(contentsOf: try canceller.finish(expectedFrameCount: Int64(scene.microphone.count)).flatMap { $0 })
    #expect(output == scene.microphone, "a session with nothing to cancel must return the microphone bit for bit")
}

@Test func resettingHappensAtEveryJournaledDiscontinuity() throws {
    let scene = EchoScene(seconds: 4, delay: 1_440)
    let canceller = try EchoCanceller(
        plan: plan(scene),
        reconvergenceFrames: [(frame: 48_000, reason: "microphone gap ended"), (frame: 96_000, reason: "output route changed")]
    )
    var offset = 0
    while offset < scene.reference.count {
        let end = min(offset + 480, scene.reference.count)
        let reference = Array(scene.reference[offset..<end])
        _ = try canceller.process(reference: [reference, reference], microphone: Array(scene.microphone[offset..<end]))
        offset = end
    }
    #expect(canceller.reconvergences.map(\.frame) == [48_000, 96_000])
    #expect(canceller.reconvergences.map(\.reason) == ["microphone gap ended", "output route changed"])
    // The delay survives a reset, so every interval is processed against a
    // declared path rather than against zero.
    #expect(canceller.reconvergences.allSatisfy { $0.delaySamples != nil })
}

@Test func farEndOnlyEchoIsSubstantiallyRemoved() throws {
    let scene = EchoScene(seconds: 8, delay: 1_440, nearEndGain: 0)
    let result = plan(scene)
    let canceller = try EchoCanceller(plan: result)
    var output: [Float] = []
    var offset = 0
    while offset < scene.reference.count {
        let end = min(offset + 480, scene.reference.count)
        let reference = Array(scene.reference[offset..<end])
        for block in try canceller.process(reference: [reference, reference], microphone: Array(scene.microphone[offset..<end])) {
            output.append(contentsOf: block)
        }
        offset = end
    }
    output.append(contentsOf: try canceller.finish(expectedFrameCount: Int64(scene.microphone.count)).flatMap { $0 })

    // Measured after the filter has had time to converge, which is what the
    // section 8 gate says: "after convergence".
    let start = 4 * timelineSampleRate
    func energy(_ samples: ArraySlice<Float>) -> Double { samples.reduce(0) { $0 + Double($1) * Double($1) } }
    let before = energy(scene.microphone[start...])
    let after = energy(output[start...])
    let reductionDb = 10 * log10(before / max(after, 1e-20))
    #expect(reductionDb >= 20, "measured \(String(format: "%.1f", reductionDb)) dB of echo reduction")
}
