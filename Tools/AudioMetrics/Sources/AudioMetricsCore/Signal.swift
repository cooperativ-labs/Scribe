import Foundation

/// Small, dependency-free signal helpers shared by the metrics analyzer and its tests.
public enum Signal {
    /// Largest reduction reported when a block is silent in the processed output.
    public static let maximumReductionDb = 120.0

    public static func energy<C: Collection>(_ samples: C) -> Double where C.Element == Double {
        samples.reduce(0) { $0 + $1 * $1 }
    }

    public static func rms<C: Collection>(_ samples: C) -> Double where C.Element == Double {
        guard !samples.isEmpty else { return 0 }
        return (energy(samples) / Double(samples.count)).squareRoot()
    }

    /// Decibels relative to full scale, or `nil` for digital silence.
    public static func decibels(_ amplitude: Double) -> Double? {
        guard amplitude > 0, amplitude.isFinite else { return nil }
        return 20 * log10(amplitude)
    }

    /// Energy ratio in dB, clamped to ``maximumReductionDb`` when the denominator is silent.
    public static func energyRatioDb(numerator: Double, denominator: Double) -> Double {
        guard numerator > 0 else { return -maximumReductionDb }
        guard denominator > 0 else { return maximumReductionDb }
        return min(maximumReductionDb, max(-maximumReductionDb, 10 * log10(numerator / denominator)))
    }

    public static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// Linear-interpolated percentile, `fraction` in 0...1.
    public static func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let position = max(0, min(Double(sorted.count - 1), fraction * Double(sorted.count - 1)))
        let lower = Int(position)
        let upper = min(sorted.count - 1, lower + 1)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }

    public static func interpolate(_ samples: [Double], at index: Double) -> Double {
        guard samples.count > 1, index >= 0, index <= Double(samples.count - 1) else { return 0 }
        let left = min(samples.count - 2, Int(index))
        let fraction = index - Double(left)
        return samples[left] + (samples[left + 1] - samples[left]) * fraction
    }

    /// Linear resampling. Adequate here: reference tracks are only used for energy ratios,
    /// activity classification, and lag estimation, never re-exported as audio.
    public static func resample(_ samples: [Double], from inputRate: Int, to outputRate: Int) -> [Double] {
        guard inputRate != outputRate, inputRate > 0, outputRate > 0, samples.count > 1 else { return samples }
        let frames = Int((Double(samples.count) * Double(outputRate) / Double(inputRate)).rounded())
        let step = Double(inputRate) / Double(outputRate)
        return (0..<frames).map { interpolate(samples, at: Double($0) * step) }
    }

    /// Box-average decimation used for the coarse pass of ``bestLag``.
    public static func decimate(_ samples: [Double], factor: Int) -> [Double] {
        guard factor > 1 else { return samples }
        let frames = samples.count / factor
        guard frames > 0 else { return [] }
        var result = Array(repeating: 0.0, count: frames)
        let scale = 1.0 / Double(factor)
        for frame in 0..<frames {
            var sum = 0.0
            for offset in 0..<factor { sum += samples[frame * factor + offset] }
            result[frame] = sum * scale
        }
        return result
    }

    /// Normalized zero-lag correlation of two signals over their common length.
    public static func correlation(_ first: [Double], _ second: [Double]) -> Double? {
        let count = min(first.count, second.count)
        guard count > 0 else { return nil }
        var cross = 0.0
        var firstEnergy = 0.0
        var secondEnergy = 0.0
        for index in 0..<count {
            cross += first[index] * second[index]
            firstEnergy += first[index] * first[index]
            secondEnergy += second[index] * second[index]
        }
        guard firstEnergy > 0, secondEnergy > 0 else { return nil }
        return cross / (firstEnergy * secondEnergy).squareRoot()
    }

    public struct LagEstimate: Equatable, Sendable {
        /// Samples by which `target` lags `reference`: `target[n] ≈ reference[n - lagSamples]`.
        public let lagSamples: Int
        /// Normalized correlation at ``lagSamples``, in -1...1.
        public let correlation: Double
    }

    /// Estimates the lag of `target` (over `targetRange`) relative to `reference` by normalized
    /// cross-correlation, using a decimated coarse search followed by a full-rate refinement.
    public static func bestLag(
        reference: [Double],
        target: [Double],
        targetRange: Range<Int>,
        lagRange: ClosedRange<Int>,
        coarseFactor: Int = 8
    ) -> LagEstimate? {
        let clamped = max(0, targetRange.lowerBound)..<min(target.count, targetRange.upperBound)
        guard !clamped.isEmpty, !reference.isEmpty else { return nil }
        guard energy(target[clamped]) > 0 else { return nil }

        var searchRange = lagRange
        let span = lagRange.upperBound - lagRange.lowerBound
        if coarseFactor > 1, clamped.count >= coarseFactor * 16, span >= coarseFactor * 4 {
            let coarseReference = decimate(reference, factor: coarseFactor)
            let coarseTarget = decimate(target, factor: coarseFactor)
            let coarseRange = (clamped.lowerBound / coarseFactor)..<max(
                clamped.lowerBound / coarseFactor + 1,
                clamped.upperBound / coarseFactor
            )
            let coarse = exhaustiveBestLag(
                reference: coarseReference,
                target: coarseTarget,
                targetRange: coarseRange,
                lagRange: (lagRange.lowerBound / coarseFactor)...(lagRange.upperBound / coarseFactor)
            )
            if let coarse {
                let center = coarse.lagSamples * coarseFactor
                let margin = coarseFactor * 2
                searchRange = max(lagRange.lowerBound, center - margin)...min(lagRange.upperBound, center + margin)
            }
        }
        return exhaustiveBestLag(reference: reference, target: target, targetRange: clamped, lagRange: searchRange)
    }

    static func exhaustiveBestLag(
        reference: [Double],
        target: [Double],
        targetRange: Range<Int>,
        lagRange: ClosedRange<Int>
    ) -> LagEstimate? {
        guard lagRange.lowerBound <= lagRange.upperBound else { return nil }
        var best: LagEstimate?
        for lag in lagRange {
            let lower = max(targetRange.lowerBound, lag)
            let upper = min(targetRange.upperBound, reference.count + lag)
            guard upper - lower >= 8 else { continue }
            var cross = 0.0
            var targetEnergy = 0.0
            var referenceEnergy = 0.0
            for index in lower..<upper {
                let targetSample = target[index]
                let referenceSample = reference[index - lag]
                cross += targetSample * referenceSample
                targetEnergy += targetSample * targetSample
                referenceEnergy += referenceSample * referenceSample
            }
            guard targetEnergy > 0, referenceEnergy > 0 else { continue }
            let correlation = cross / (targetEnergy * referenceEnergy).squareRoot()
            if best == nil || correlation > best!.correlation {
                best = LagEstimate(lagSamples: lag, correlation: correlation)
            }
        }
        return best
    }

    /// Peak of the 4x band-limited reconstruction, i.e. the ITU-R BS.1770-style true peak.
    ///
    /// Phase 0 of the interpolator is exactly the identity, so the result is never below the
    /// sample peak.
    public static func truePeak(_ samples: [Double], oversampling: Int = 4, tapsPerPhase: Int = 12) -> Double {
        guard !samples.isEmpty else { return 0 }
        guard oversampling > 1, tapsPerPhase >= 4, tapsPerPhase % 2 == 0 else {
            return samples.reduce(0) { max($0, abs($1)) }
        }
        let branches = fractionalDelayBranches(oversampling: oversampling, tapsPerPhase: tapsPerPhase)
        let offset = tapsPerPhase / 2 - 1
        // Phase 0 is the identity, so the sample peak is a lower bound. Each branch can amplify
        // its tap window by at most its L1 norm, so any window whose samples all sit below
        // samplePeak / gain cannot beat that bound and is skipped.
        var peak = samples.reduce(0) { max($0, abs($1)) }
        guard peak > 0 else { return 0 }
        let gain = max(1, branches.map { $0.reduce(0) { $0 + abs($1) } }.max() ?? 1)
        let candidateFloor = peak / gain

        func evaluate(_ index: Int) {
            for branch in branches {
                var accumulator = 0.0
                for (tap, coefficient) in branch.enumerated() {
                    let sourceIndex = index + tap - offset
                    guard sourceIndex >= 0, sourceIndex < samples.count else { continue }
                    accumulator += samples[sourceIndex] * coefficient
                }
                peak = max(peak, abs(accumulator))
            }
        }

        var evaluatedUpTo = 0
        for index in 0..<samples.count where abs(samples[index]) >= candidateFloor {
            let lower = max(evaluatedUpTo, index - tapsPerPhase)
            let upper = min(samples.count, index + tapsPerPhase)
            guard upper > lower else { continue }
            for candidate in lower..<upper { evaluate(candidate) }
            evaluatedUpTo = upper
        }
        return peak
    }

    /// Windowed-sinc fractional-delay branches at offsets `phase / oversampling`, each
    /// normalized to unity DC gain. Tap `k` applies to `x[n + k - (tapsPerPhase / 2 - 1)]`.
    static func fractionalDelayBranches(oversampling: Int, tapsPerPhase: Int) -> [[Double]] {
        let offset = tapsPerPhase / 2 - 1
        return (0..<oversampling).map { phase in
            let delay = Double(phase) / Double(oversampling)
            var coefficients = (0..<tapsPerPhase).map { tap -> Double in
                let position = Double(tap - offset) - delay
                let sinc = abs(position) < 1e-12 ? 1 : sin(Double.pi * position) / (Double.pi * position)
                let ratio = Double(tap) / Double(tapsPerPhase - 1)
                let window = 0.42 - 0.5 * cos(2 * Double.pi * ratio) + 0.08 * cos(4 * Double.pi * ratio)
                return sinc * window
            }
            let sum = coefficients.reduce(0, +)
            if abs(sum) > 1e-12 { coefficients = coefficients.map { $0 / sum } }
            return coefficients
        }
    }

    public struct ClippingSummary: Equatable, Sendable {
        public let clippedSamples: Int
        public let clippedRuns: Int
        public let longestRunSamples: Int
        public let samplePeak: Double
    }

    /// Counts samples at or beyond `threshold` and groups them into consecutive runs.
    public static func clipping(_ samples: [Double], threshold: Double) -> ClippingSummary {
        var clipped = 0
        var runs = 0
        var longest = 0
        var current = 0
        var peak = 0.0
        for sample in samples {
            let magnitude = abs(sample)
            peak = max(peak, magnitude)
            if magnitude >= threshold {
                clipped += 1
                current += 1
                if current == 1 { runs += 1 }
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return ClippingSummary(clippedSamples: clipped, clippedRuns: runs, longestRunSamples: longest, samplePeak: peak)
    }
}
