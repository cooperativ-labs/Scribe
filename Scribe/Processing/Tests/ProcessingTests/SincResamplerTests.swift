import Foundation
import Testing
@testable import Processing

@Test func aUnityRatioIsAnExactPassThrough() {
    let resampler = SincResampler(inputSampleRate: 48_000, outputSampleRate: 48_000, channelCount: 1)
    #expect(resampler.isPassThrough)
    let input = testSignal(frames: 4_800)
    #expect(resampler.process([input], isFinal: true)[0] == input, "no filtering may touch a track that needs no conversion")
}

@Test func upsamplingHasNoNetGroupDelay() {
    // A 16 kHz signal upsampled to 48 kHz. A linear-phase interpolator centred on the
    // exact source position puts input frame n at output frame 3n, with no filter
    // delay to subtract later. That is what keeps the user's speech where it was.
    let rate = 16_000
    var input = [Float](repeating: 0, count: 1_600)
    input[800] = 1
    let output = SincResampler(inputSampleRate: rate, outputSampleRate: 48_000, channelCount: 1)
        .process([input], isFinal: true)[0]
    let peak = output.indices.max { abs(output[$0]) < abs(output[$1]) } ?? -1
    #expect(peak == 2_400, "the impulse moved to \(peak) instead of 3x its source position")
}

@Test func downsamplingHasNoNetGroupDelayEither() {
    let rate = 96_000
    var input = [Float](repeating: 0, count: 9_600)
    input[4_800] = 1
    let output = SincResampler(inputSampleRate: rate, outputSampleRate: 48_000, channelCount: 1)
        .process([input], isFinal: true)[0]
    let peak = output.indices.max { abs(output[$0]) < abs(output[$1]) } ?? -1
    #expect(peak == 2_400)
}

@Test func aToneSurvivesRateConversionAtItsOriginalFrequencyAndLevel() {
    // 1 kHz at 44.1 kHz, converted to 48 kHz: the period must still be 48 samples and
    // the amplitude must not have moved, or every level measurement downstream is off.
    let input = (0..<44_100).map { Float(sin(2 * Double.pi * 1_000 * Double($0) / 44_100)) * 0.5 }
    let output = SincResampler(inputSampleRate: 44_100, outputSampleRate: 48_000, channelCount: 1)
        .process([input], isFinal: true)[0]
    #expect(abs(output.count - 48_000) <= 1)
    // Measure away from the run edges, where the kernel deliberately tapers.
    let interior = Array(output[4_800..<43_200])
    let peak = interior.map { abs($0) }.max() ?? 0
    #expect(abs(peak - 0.5) < 0.005)
    let expected = (4_800..<43_200).map { Float(sin(2 * Double.pi * 1_000 * Double($0) / 48_000)) * 0.5 }
    let error = zip(interior, expected).map { abs($0 - $1) }.max() ?? 1
    #expect(error < 0.005, "worst-case reconstruction error was \(error)")
}

@Test func streamedInputMatchesOneShotInput() {
    let input = testSignal(frames: 16_000)
    let oneShot = SincResampler(inputSampleRate: 16_000, outputSampleRate: 48_000, channelCount: 1)
        .process([input], isFinal: true)[0]

    let streaming = SincResampler(inputSampleRate: 16_000, outputSampleRate: 48_000, channelCount: 1)
    var streamed: [Float] = []
    var offset = 0
    while offset < input.count {
        let count = min(160, input.count - offset)
        let chunk = Array(input[offset..<(offset + count)])
        offset += count
        streamed.append(contentsOf: streaming.process([chunk], isFinal: offset >= input.count)[0])
    }
    #expect(streamed.count == oneShot.count)
    #expect(zip(streamed, oneShot).allSatisfy { $0 == $1 }, "block boundaries changed the result")
}

@Test func driftCorrectionStretchesByExactlyTheMeasuredRatio() {
    let resampler = SincResampler(inputSampleRate: 48_000, outputSampleRate: 48_000, driftRatio: 1.0005, channelCount: 1)
    #expect(!resampler.isPassThrough)
    #expect(resampler.outputFrameCount(forInputFrames: 480_000) == 480_240)
}
