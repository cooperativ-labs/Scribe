import Foundation

/// Streaming true-peak meter for the mix bus.
///
/// Section 5 sets the ceiling in dBTP, which is an inter-sample figure: a signal
/// whose every sample sits below 0 dBFS can still overshoot between samples, and
/// a downstream converter will hear that. The peak is therefore taken from a 4×
/// oversampled reconstruction rather than from the samples themselves.
///
/// The filter is intentionally the same one `Tools/AudioMetrics` uses to *score*
/// the ceiling — 4× oversampling, 12 taps per phase, a Blackman-windowed sinc
/// normalized to unity DC gain. A limiter and a gate that disagreed about what a
/// true peak is would produce a file that measures over a ceiling it was built to
/// satisfy, and the disagreement, not the audio, would be the bug.
public struct TruePeakMeter: Sendable {
    public static let oversampling = 4
    public static let tapsPerPhase = 12

    private let branches: [[Double]]
    private let offset: Int
    /// The most recent `tapsPerPhase` samples of every channel, so a block boundary
    /// is not a discontinuity in the reconstruction.
    private var history: [[Double]]
    private var peak: Double = 0

    public init(channelCount: Int) {
        self.branches = Self.fractionalDelayBranches(oversampling: Self.oversampling, tapsPerPhase: Self.tapsPerPhase)
        self.offset = Self.tapsPerPhase / 2 - 1
        self.history = Array(repeating: [Double](repeating: 0, count: Self.tapsPerPhase), count: max(1, channelCount))
    }

    /// The largest reconstructed magnitude seen so far, in linear full-scale units.
    public var truePeak: Double { peak }

    public var truePeakDbTP: Double? { peak > 0 ? 20 * log10(peak) : nil }

    public mutating func append(_ channels: [[Float]]) {
        for (index, samples) in channels.enumerated() where index < history.count {
            append(samples, channel: index)
        }
    }

    public mutating func append(_ samples: [Float], channel: Int) {
        guard channel < history.count, !samples.isEmpty else { return }
        var window = history[channel]
        for sample in samples {
            window.removeFirst()
            window.append(Double(sample))
            peak = max(peak, abs(window[offset]))
            // Every branch is a fractional-delay reconstruction of the sample that
            // sits `offset` back in the window, so a whole block's inter-sample
            // peaks are covered once each sample has passed through.
            for branch in branches {
                var accumulator = 0.0
                for (tap, coefficient) in branch.enumerated() {
                    accumulator += window[tap] * coefficient
                }
                peak = max(peak, abs(accumulator))
            }
        }
        history[channel] = window
    }

    /// Flushes the filter's own lookahead so the last samples of the stream are
    /// reconstructed too. Call once, before reading ``truePeak``.
    public mutating func finish() {
        let tail = [Float](repeating: 0, count: Self.tapsPerPhase)
        for channel in 0..<history.count { append(tail, channel: channel) }
    }

    /// Windowed-sinc fractional-delay branches at offsets `phase / oversampling`,
    /// each normalized to unity DC gain. Tap `k` applies to `x[n + k - offset]`.
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
}
