import Foundation
import Testing
@testable import AudioMetricsCore

/// Deterministic broadband test signal; the exact values do not matter, only that the sequence
/// is reproducible and has no strong periodicity.
func noise(count: Int, seed: UInt64 = 12_345) -> [Double] {
    var state = seed
    return (0..<count).map { _ in
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) * (2.0 / Double(1 << 53)) - 1
    }
}

func sine(count: Int, cyclesPerSample: Double, amplitude: Double = 1, phase: Double = 0) -> [Double] {
    (0..<count).map { amplitude * sin(2 * Double.pi * cyclesPerSample * Double($0) + phase) }
}

@Test func rmsAndDecibelsMatchKnownLevels() {
    #expect(abs(Signal.rms([1, -1, 1, -1]) - 1) < 1e-12)
    #expect(abs(Signal.decibels(Signal.rms([1, -1, 1, -1]))! - 0) < 1e-9)
    // A full-scale sine sits 3.0103 dB below a full-scale square.
    let level = Signal.decibels(Signal.rms(sine(count: 48_000, cyclesPerSample: 1_000.0 / 48_000)))!
    #expect(abs(level - (-3.0103)) < 0.01)
    #expect(Signal.decibels(0) == nil)
}

@Test func energyRatioReportsKnownAttenuation() {
    let signal = noise(count: 4_800)
    let attenuated = signal.map { $0 * 0.1 }
    let ratio = Signal.energyRatioDb(numerator: Signal.energy(signal), denominator: Signal.energy(attenuated))
    #expect(abs(ratio - 20) < 1e-9)

    let halved = signal.map { $0 * 0.5 }
    let sixDb = Signal.energyRatioDb(numerator: Signal.energy(signal), denominator: Signal.energy(halved))
    #expect(abs(sixDb - 6.0206) < 1e-3)

    // Silence in the denominator saturates instead of returning infinity.
    #expect(Signal.energyRatioDb(numerator: 1, denominator: 0) == Signal.maximumReductionDb)
    #expect(Signal.energyRatioDb(numerator: 0, denominator: 1) == -Signal.maximumReductionDb)
}

@Test func medianAndPercentileUseKnownOrderStatistics() {
    #expect(Signal.median([3, 1, 2]) == 2)
    #expect(Signal.median([4, 1, 3, 2]) == 2.5)
    #expect(Signal.median([]) == nil)
    #expect(Signal.percentile([0, 10, 20, 30, 40], 0.5) == 20)
    #expect(Signal.percentile([0, 10], 0.25) == 2.5)
}

@Test func bestLagRecoversAKnownDelay() throws {
    let reference = noise(count: 48_000)
    let delay = 137
    var target = Array(repeating: 0.0, count: reference.count)
    for index in delay..<reference.count { target[index] = 0.6 * reference[index - delay] }

    let estimate = try #require(Signal.bestLag(
        reference: reference,
        target: target,
        targetRange: 4_800..<24_000,
        lagRange: (-2_400)...2_400
    ))
    #expect(estimate.lagSamples == delay)
    #expect(estimate.correlation > 0.99)
}

@Test func bestLagRecoversANegativeLeadAndRejectsSilence() throws {
    let reference = noise(count: 24_000, seed: 99)
    let lead = -240
    var target = Array(repeating: 0.0, count: reference.count)
    for index in 0..<(reference.count + lead) { target[index] = reference[index - lead] }

    let estimate = try #require(Signal.bestLag(
        reference: reference,
        target: target,
        targetRange: 1_200..<12_000,
        lagRange: (-2_400)...2_400
    ))
    #expect(estimate.lagSamples == lead)

    let silence = Array(repeating: 0.0, count: 24_000)
    #expect(Signal.bestLag(reference: reference, target: silence, targetRange: 0..<24_000, lagRange: (-100)...100) == nil)
}

@Test func zeroLagCorrelationSeparatesPresentFromAbsentSignals() throws {
    let signal = noise(count: 9_600)
    let independent = noise(count: 9_600, seed: 777)
    #expect(abs(try #require(Signal.correlation(signal, signal)) - 1) < 1e-12)
    #expect(abs(try #require(Signal.correlation(signal, independent))) < 0.1)
    #expect(Signal.correlation(signal, Array(repeating: 0.0, count: 9_600)) == nil)
}

@Test func truePeakSeesIntersamplePeaksThatTheSamplePeakMisses() {
    // A full-scale sine at exactly a quarter of the sample rate, sampled halfway between its
    // peaks: every sample is 1/sqrt(2) but the waveform still reaches full scale.
    let samples = sine(count: 4_800, cyclesPerSample: 0.25, amplitude: 1, phase: .pi / 4)
    let samplePeak = samples.map(abs).max()!
    #expect(abs(samplePeak - 0.5.squareRoot() * 1) < 1e-9)
    let truePeak = Signal.truePeak(samples)
    #expect(abs(Signal.decibels(truePeak)!) < 0.1)
    #expect(truePeak > samplePeak)
}

@Test func truePeakIsNeverBelowTheSamplePeak() {
    // A plateau that fades in and out has no band-limiting overshoot, so its true peak is its
    // plateau level. (A hard step to 0.5 would legitimately overshoot it.)
    var plateau = Array(repeating: 0.5, count: 1_000)
    for index in 0..<200 {
        let envelope = 0.5 - 0.5 * cos(Double.pi * Double(index) / 200)
        plateau[index] *= envelope
        plateau[plateau.count - 1 - index] *= envelope
    }
    #expect(abs(Signal.truePeak(plateau) - 0.5) < 1e-3)

    let signal = noise(count: 9_600)
    #expect(Signal.truePeak(signal) >= signal.map(abs).max()! - 1e-9)
}

@Test func clippingCountsSamplesAndRuns() {
    let samples: [Double] = [0, 0.5, 1, 1, 1, 0.2, -1, 0.3, -0.9999, 1]
    let summary = Signal.clipping(samples, threshold: 0.99998)
    #expect(summary.clippedSamples == 5)
    #expect(summary.clippedRuns == 3)
    #expect(summary.longestRunSamples == 3)
    #expect(summary.samplePeak == 1)
    #expect(Signal.clipping(samples, threshold: 2).clippedSamples == 0)
}

@Test func resamplingPreservesDurationAndLevel() {
    let source = sine(count: 48_000, cyclesPerSample: 200.0 / 48_000, amplitude: 0.5)
    let downsampled = Signal.resample(source, from: 48_000, to: 16_000)
    #expect(downsampled.count == 16_000)
    #expect(abs(Signal.rms(downsampled) - Signal.rms(source)) < 0.01)
    #expect(Signal.resample(source, from: 48_000, to: 48_000).count == source.count)
}
