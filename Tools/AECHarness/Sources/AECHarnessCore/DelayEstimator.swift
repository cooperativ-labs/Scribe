import Foundation

/// Estimates the acoustic render-to-capture delay from a bounded, recent window.
///
/// A peak alone is not enough to program AEC3: silence, local speech, and periodic
/// playback can all produce a plausible-looking lag.  The estimator therefore returns
/// an estimate only when both tracks are active, the normalized correlation is strong,
/// and the winning lag is materially better than non-neighbouring alternatives.
public struct DelayEstimate: Codable, Equatable, Sendable {
    public let delaySamples: Int
    public let correlation: Double
    public let runnerUpCorrelation: Double
    public let confidence: Double
}

public struct DelayEstimationRejection: Error, Codable, Equatable, Sendable {
    public let reason: String
    public let referenceLevelDbFS: Double?
    public let microphoneLevelDbFS: Double?
    public let bestCorrelation: Double?
    public let runnerUpCorrelation: Double?
}

/// Kept deliberately small: at 48 kHz this is 1.2 seconds per channel, irrespective
/// of recording duration.  A caller may use a fresh instance for the initial pass and
/// a rolling instance to detect later discontinuities.
public struct DelayEstimator: Sendable {
    public static let sampleRate = 48_000
    public static let analysisFrames = 48_000
    public static let maximumDelaySamples = 5_760 // 120 ms
    public static let minimumCorrelation = 0.65
    public static let minimumPeakMargin = 0.10

    private var render: [Float] = []
    private var capture: [Float] = []

    public init() {
        render.reserveCapacity(Self.analysisFrames + Self.maximumDelaySamples)
        capture.reserveCapacity(Self.analysisFrames + Self.maximumDelaySamples)
    }

    public var hasAnalysisWindow: Bool { capture.count >= Self.analysisFrames }

    public mutating func append(render renderBlock: [Float], capture captureBlock: [Float]) {
        let count = min(renderBlock.count, captureBlock.count)
        guard count > 0 else { return }
        render.append(contentsOf: renderBlock.prefix(count))
        capture.append(contentsOf: captureBlock.prefix(count))
        let maximum = Self.analysisFrames + Self.maximumDelaySamples
        if render.count > maximum {
            let discard = render.count - maximum
            render.removeFirst(discard)
            capture.removeFirst(discard)
        }
    }

    public func estimate() -> Result<DelayEstimate, DelayEstimationRejection> {
        guard hasAnalysisWindow else {
            return .failure(.init(reason: "insufficient correlated audio for a one-second analysis window", referenceLevelDbFS: nil, microphoneLevelDbFS: nil, bestCorrelation: nil, runnerUpCorrelation: nil))
        }
        let start = max(0, capture.count - Self.analysisFrames)
        let referenceLevel = level(render[start..<render.count])
        let microphoneLevel = level(capture[start..<capture.count])
        guard (referenceLevel ?? -.infinity) > -55, (microphoneLevel ?? -.infinity) > -55 else {
            return .failure(.init(reason: "silence or near-silence is not a valid delay-calibration region", referenceLevelDbFS: referenceLevel, microphoneLevelDbFS: microphoneLevel, bestCorrelation: nil, runnerUpCorrelation: nil))
        }

        // Decimate before the broad search, then evaluate only a ±16-sample band at full
        // rate. This avoids retaining a recording or doing a full-rate 120 ms search per lag.
        let factor = 8
        let coarseStart = start / factor
        let coarseRender = decimate(render, factor: factor)
        let coarseCapture = decimate(capture, factor: factor)
        let coarse = bestAndRunnerUp(
            render: coarseRender,
            capture: coarseCapture,
            start: coarseStart,
            end: coarseCapture.count,
            lags: 0...(Self.maximumDelaySamples / factor),
            separation: 60 // 10 ms at the decimated rate
        )
        guard let coarse else {
            return .failure(.init(reason: "no overlapping active samples in delay-calibration window", referenceLevelDbFS: referenceLevel, microphoneLevelDbFS: microphoneLevel, bestCorrelation: nil, runnerUpCorrelation: nil))
        }
        let center = coarse.best.lag * factor
        let low = max(0, center - 16)
        let high = min(Self.maximumDelaySamples, center + 16)
        guard let refined = bestAndRunnerUp(
            render: render,
            capture: capture,
            start: start,
            end: capture.count,
            lags: low...high,
            separation: 480 // do not let one reverb tap masquerade as a unique peak
        ) else {
            return .failure(.init(reason: "no full-rate overlap in delay-calibration window", referenceLevelDbFS: referenceLevel, microphoneLevelDbFS: microphoneLevel, bestCorrelation: nil, runnerUpCorrelation: nil))
        }

        let best = refined.best.correlation
        let runnerUp = max(coarse.runnerUp.correlation, refined.runnerUp.correlation)
        let margin = best - runnerUp
        guard best >= Self.minimumCorrelation else {
            return .failure(.init(reason: "correlation is too weak; local speech or an unrelated microphone signal may dominate", referenceLevelDbFS: referenceLevel, microphoneLevelDbFS: microphoneLevel, bestCorrelation: best, runnerUpCorrelation: runnerUp))
        }
        guard margin >= Self.minimumPeakMargin else {
            return .failure(.init(reason: "correlation peak is ambiguous; periodic playback or competing local speech is unsafe to use for delay calibration", referenceLevelDbFS: referenceLevel, microphoneLevelDbFS: microphoneLevel, bestCorrelation: best, runnerUpCorrelation: runnerUp))
        }
        return .success(.init(delaySamples: refined.best.lag, correlation: best, runnerUpCorrelation: runnerUp, confidence: min(1, max(0, (best - Self.minimumCorrelation) / (1 - Self.minimumCorrelation)) * min(1, margin / 0.20))))
    }

    private struct Candidate { let lag: Int; let correlation: Double }
    private struct Pair { let best: Candidate; let runnerUp: Candidate }

    private func bestAndRunnerUp(render: [Float], capture: [Float], start: Int, end: Int, lags: ClosedRange<Int>, separation: Int) -> Pair? {
        var candidates: [Candidate] = []
        for lag in lags {
            let lower = max(start, lag)
            let upper = min(end, render.count + lag)
            guard upper - lower >= 480 else { continue }
            var cross = 0.0, renderEnergy = 0.0, captureEnergy = 0.0
            for index in lower..<upper {
                let r = Double(render[index - lag]); let c = Double(capture[index])
                cross += r * c; renderEnergy += r * r; captureEnergy += c * c
            }
            guard renderEnergy > 1e-12, captureEnergy > 1e-12 else { continue }
            candidates.append(.init(lag: lag, correlation: cross / (renderEnergy * captureEnergy).squareRoot()))
        }
        guard let best = candidates.max(by: { $0.correlation < $1.correlation }) else { return nil }
        let runnerUp = candidates.filter { abs($0.lag - best.lag) >= separation }.max(by: { $0.correlation < $1.correlation }) ?? .init(lag: best.lag, correlation: -.infinity)
        return .init(best: best, runnerUp: runnerUp)
    }

    private func decimate(_ signal: [Float], factor: Int) -> [Float] {
        guard factor > 1 else { return signal }
        return stride(from: 0, to: signal.count - factor + 1, by: factor).map { offset in
            signal[offset..<(offset + factor)].reduce(0, +) / Float(factor)
        }
    }

    private func level(_ samples: ArraySlice<Float>) -> Double? {
        guard !samples.isEmpty else { return nil }
        let mean = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)
        guard mean > 1e-14 else { return nil }
        return 10 * log10(mean)
    }
}
