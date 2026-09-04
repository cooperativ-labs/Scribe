import Foundation

/// A streaming, linear-phase windowed-sinc resampler for the processing copy.
///
/// Two properties matter for the timeline gate. First, when the conversion ratio
/// is exactly 1 the resampler is a pass-through, so a 48 kHz track that needs no
/// drift correction is reproduced sample for sample rather than being filtered.
/// Second, the interpolation kernel is symmetric and centred on the exact
/// fractional source position, so it has **zero net group delay**: output frame
/// `n` represents source position `n * step`, not that position plus a filter
/// delay. What the kernel needs instead of latency is context — ``contextFrames``
/// input frames either side of the position being interpolated — and this class
/// carries that context across streaming block boundaries so a block-by-block run
/// is identical to processing the run in one piece.
///
/// ``contextFrames`` is reported so the manifest can record what the processing
/// copy required, which is the "account for resampler latency" obligation in
/// implementation-plan section 3: the value is accounted for and compensated
/// here, at the point where it arises, rather than propagated as an offset the
/// mixdown would have to subtract later.
public final class SincResampler {
    public let inputSampleRate: Int
    public let outputSampleRate: Int
    public let driftRatio: Double
    public let channelCount: Int

    /// Source frames of look-behind and look-ahead the kernel reads. Not a delay.
    public let contextFrames: Int
    /// Source frames consumed per output frame.
    public let step: Double
    public var isPassThrough: Bool { step == 1 }

    private let kernelHalfWidth: Double
    private let cutoff: Double
    private let windowScale: Double
    /// The windowed sinc sampled at ``kernelTableResolution`` points per source
    /// sample, so interpolation costs a lookup and a lerp instead of a `sin` and a
    /// Bessel series per tap. Two subphase steps are about 0.004 of a sample apart,
    /// far below the amplitude resolution of the audio being interpolated.
    private static let kernelTableResolution = 512.0
    private let kernelTable: [Double]

    /// Input frames already consumed and discarded, per channel.
    private var consumedInputFrames: Int64 = 0
    private var pending: [[Float]]
    private var nextOutputIndex: Int64 = 0
    private var finished = false

    public init(inputSampleRate: Int, outputSampleRate: Int, driftRatio: Double = 1, channelCount: Int, contextFrames: Int = 32) {
        precondition(inputSampleRate > 0 && outputSampleRate > 0 && channelCount > 0)
        precondition(driftRatio.isFinite && driftRatio > 0)
        self.inputSampleRate = inputSampleRate
        self.outputSampleRate = outputSampleRate
        self.driftRatio = driftRatio
        self.channelCount = channelCount
        self.step = Double(inputSampleRate) / (Double(outputSampleRate) * driftRatio)
        // Downsampling must band-limit to the output Nyquist; upsampling keeps the
        // full input band. The window widens by the same factor so the transition
        // band stays proportional.
        self.cutoff = min(1, 1 / self.step)
        self.windowScale = max(1, self.step)
        self.contextFrames = max(1, Int((Double(contextFrames) * windowScale).rounded(.up)))
        self.kernelHalfWidth = Double(contextFrames) * windowScale
        self.pending = Array(repeating: [], count: channelCount)

        let entries = Int((kernelHalfWidth * Self.kernelTableResolution).rounded(.up)) + 2
        let beta = 8.6
        let normalization = Self.besselI0(beta)
        var table = [Double](repeating: 0, count: entries)
        for index in 0..<entries {
            let t = Double(index) / Self.kernelTableResolution
            guard t < kernelHalfWidth else { break }
            let x = Double.pi * cutoff * t
            let sinc = abs(x) < 1e-12 ? 1 : sin(x) / x
            let window = Self.besselI0(beta * (1 - (t / kernelHalfWidth) * (t / kernelHalfWidth)).squareRoot()) / normalization
            table[index] = cutoff * sinc * window
        }
        self.kernelTable = table
    }

    /// Output frames this resampler will produce for a run of `inputFrames` frames.
    public func outputFrameCount(forInputFrames inputFrames: Int64) -> Int64 {
        if isPassThrough { return inputFrames }
        return Int64((Double(inputFrames) / step).rounded())
    }

    /// Appends input and returns every output frame that is now fully determined.
    /// Pass `isFinal: true` on the last call of a run; the tail is then completed
    /// by treating source samples past the end as silence, which is correct because
    /// a run boundary is either a journaled gap or the end of the track.
    public func process(_ input: [[Float]], isFinal: Bool = false) -> [[Float]] {
        precondition(input.count == channelCount, "channel count changed mid-run")
        if isFinal { finished = true }
        for channel in 0..<channelCount { pending[channel].append(contentsOf: input[channel]) }

        if isPassThrough {
            let output = pending
            for channel in 0..<channelCount { pending[channel].removeAll(keepingCapacity: true) }
            consumedInputFrames += Int64(output.first?.count ?? 0)
            nextOutputIndex += Int64(output.first?.count ?? 0)
            return output
        }

        let availableEnd = consumedInputFrames + Int64(pending.first?.count ?? 0)
        var produced = Array(repeating: [Float](), count: channelCount)
        var outputIndex = nextOutputIndex

        while true {
            let position = Double(outputIndex) * step
            let base = Int64(position.rounded(.down))
            // Without more input the kernel would read past the end; stop unless the
            // run is over, in which case the missing samples are genuinely silence.
            if !finished, base + Int64(contextFrames) + 1 > availableEnd { break }
            if finished, base >= availableEnd { break }
            let fraction = position - Double(base)
            for channel in 0..<channelCount {
                produced[channel].append(interpolate(channel: channel, base: base, fraction: fraction, availableEnd: availableEnd))
            }
            outputIndex += 1
        }
        nextOutputIndex = outputIndex

        // Retire input the kernel can no longer reach.
        let stillNeededFrom = max(consumedInputFrames, Int64(Double(outputIndex) * step) - Int64(contextFrames) - 1)
        let discard = Int(min(stillNeededFrom - consumedInputFrames, Int64(pending.first?.count ?? 0)))
        if discard > 0 {
            for channel in 0..<channelCount { pending[channel].removeFirst(discard) }
            consumedInputFrames += Int64(discard)
        }
        return produced
    }

    private func interpolate(channel: Int, base: Int64, fraction: Double, availableEnd: Int64) -> Float {
        var sum = 0.0
        var weight = 0.0
        let lower = base - Int64(contextFrames) + 1
        let upper = base + Int64(contextFrames)
        for source in lower...upper {
            let tap = kernel(Double(source - base) - fraction)
            guard tap != 0 else { continue }
            weight += tap
            guard source >= consumedInputFrames, source < availableEnd else { continue }
            sum += tap * Double(pending[channel][Int(source - consumedInputFrames)])
        }
        // The weight is the whole window's sum, including taps that fall outside the
        // run, so passband gain is unity in the interior while a run edge tapers into
        // the silence beside it. That is the right answer: what lies outside a run is
        // either a journaled gap or the end of the track, and both are silence.
        return weight == 0 ? 0 : Float(sum / weight)
    }

    /// Looks the symmetric kernel up by magnitude and interpolates between entries.
    private func kernel(_ t: Double) -> Double {
        let scaled = abs(t) * Self.kernelTableResolution
        let index = Int(scaled)
        guard index + 1 < kernelTable.count else { return 0 }
        let fraction = scaled - Double(index)
        return kernelTable[index] * (1 - fraction) + kernelTable[index + 1] * fraction
    }


    private static func besselI0(_ x: Double) -> Double {
        var sum = 1.0
        var term = 1.0
        let half = x / 2
        for index in 1...24 {
            term *= (half / Double(index)) * (half / Double(index))
            sum += term
            if term < sum * 1e-17 { break }
        }
        return sum
    }
}
