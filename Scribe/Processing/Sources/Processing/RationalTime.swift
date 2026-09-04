import Foundation

/// An exact media timestamp held as `value / timescale`.
///
/// Capture journals record presentation timestamps either as a `CMTime`-shaped
/// `{value, timescale}` pair or as a `Double` number of seconds. Both are turned
/// into this type once, at the journal boundary, and every later timeline
/// decision is integer arithmetic on it. Nothing downstream accumulates a
/// floating-point sum of buffer durations, which is the failure mode that makes
/// a two-hour reconstruction drift.
public struct RationalTime: Sendable, Equatable, Hashable, Comparable, CustomStringConvertible {
    public let value: Int64
    public let timescale: Int64

    public static let zero = RationalTime(value: 0, timescale: 1)

    /// The timescale a `Double` seconds journal field is quantized onto. It is a
    /// multiple of every sample rate the recorder can encounter (48 kHz, 44.1 kHz,
    /// 16 kHz, 8 kHz, 96 kHz, 192 kHz), so a whole number of frames at any of them
    /// is representable exactly, and it is fine enough that the quantization error
    /// of a `Double` seconds value is far below one sample.
    public static let journalTimescale: Int64 = 28_224_000

    public init(value: Int64, timescale: Int64) {
        precondition(timescale != 0, "a rational time needs a non-zero timescale")
        if timescale < 0 {
            self.value = -value
            self.timescale = -timescale
        } else {
            self.value = value
            self.timescale = timescale
        }
    }

    /// Quantizes a journal's `Double` seconds onto ``journalTimescale``.
    ///
    /// This is the only lossy step in the timeline, it happens exactly once per
    /// record, and its error is bounded by half a tick — about 18 nanoseconds,
    /// or 0.0009 of a sample at 48 kHz. It never compounds, because the result is
    /// an absolute timestamp rather than an increment.
    public init(seconds: Double, timescale: Int64 = RationalTime.journalTimescale) {
        precondition(seconds.isFinite, "a journal timestamp must be finite")
        self.init(value: Int64((seconds * Double(timescale)).rounded()), timescale: timescale)
    }

    public var seconds: Double { Double(value) / Double(timescale) }

    public var description: String { "\(value)/\(timescale) (\(seconds)s)" }

    /// Converts to a frame index on `sampleRate`, rounding half away from zero.
    ///
    /// The multiply is done in double width so a host-uptime timestamp — around
    /// 207 500 s in the measured captures, and far larger on a long-lived machine —
    /// cannot overflow on its way to a 48 kHz frame index.
    public func frameIndex(atSampleRate sampleRate: Int) -> Int64 {
        precondition(sampleRate > 0, "a sample rate must be positive")
        return Self.divideRoundingHalfAwayFromZero(multiplying: value, by: Int64(sampleRate), dividingBy: timescale)
    }

    /// The exact duration of `frameCount` frames at `sampleRate`.
    public static func duration(frames frameCount: Int64, atSampleRate sampleRate: Int) -> RationalTime {
        RationalTime(value: frameCount, timescale: Int64(sampleRate))
    }

    public static func + (lhs: RationalTime, rhs: RationalTime) -> RationalTime {
        let (value, timescale) = commonTerms(lhs, rhs)
        return RationalTime(value: value.0 + value.1, timescale: timescale)
    }

    public static func - (lhs: RationalTime, rhs: RationalTime) -> RationalTime {
        let (value, timescale) = commonTerms(lhs, rhs)
        return RationalTime(value: value.0 - value.1, timescale: timescale)
    }

    public static func < (lhs: RationalTime, rhs: RationalTime) -> Bool {
        let (value, _) = commonTerms(lhs, rhs)
        return value.0 < value.1
    }

    public static func == (lhs: RationalTime, rhs: RationalTime) -> Bool {
        let (value, _) = commonTerms(lhs, rhs)
        return value.0 == value.1
    }

    public func hash(into hasher: inout Hasher) {
        let divisor = Self.greatestCommonDivisor(abs(value), timescale)
        hasher.combine(divisor == 0 ? 0 : value / divisor)
        hasher.combine(divisor == 0 ? timescale : timescale / divisor)
    }

    /// Re-expresses both operands on their least common timescale. Reducing each
    /// side first keeps the common timescale small enough that ordinary 64-bit
    /// arithmetic suffices for the timestamps a capture session produces.
    private static func commonTerms(_ lhs: RationalTime, _ rhs: RationalTime) -> ((Int64, Int64), Int64) {
        if lhs.timescale == rhs.timescale { return ((lhs.value, rhs.value), lhs.timescale) }
        let divisor = greatestCommonDivisor(lhs.timescale, rhs.timescale)
        let leftFactor = rhs.timescale / divisor
        let rightFactor = lhs.timescale / divisor
        return ((lhs.value * leftFactor, rhs.value * rightFactor), lhs.timescale * leftFactor)
    }

    static func greatestCommonDivisor(_ a: Int64, _ b: Int64) -> Int64 {
        var (a, b) = (abs(a), abs(b))
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }

    /// `value * multiplier / divisor` in double width, rounded half away from zero.
    ///
    /// The multiplier and divisor are reduced against each other first, which is
    /// what keeps a host-uptime presentation timestamp — a number in the millions
    /// of journal ticks per second — from overflowing on its way to a frame index.
    static func divideRoundingHalfAwayFromZero(multiplying value: Int64, by multiplier: Int64, dividingBy divisor: Int64) -> Int64 {
        precondition(divisor > 0, "the divisor must be positive")
        let common = greatestCommonDivisor(multiplier, divisor)
        let reducedMultiplier = UInt64((multiplier / common).magnitude)
        let reducedDivisor = UInt64(divisor / common)
        let negative = (value < 0) != (multiplier < 0)

        let product = value.magnitude.multipliedFullWidth(by: reducedMultiplier)
        var (high, low) = (product.high, product.low)
        let sum = low.addingReportingOverflow(reducedDivisor / 2)
        low = sum.partialValue
        if sum.overflow { high += 1 }
        precondition(high < reducedDivisor, "timestamp \(value)/\(divisor) overflows when scaled by \(multiplier)")

        let (quotient, _) = reducedDivisor.dividingFullWidth((high: high, low: low))
        precondition(quotient <= UInt64(Int64.max), "scaled timestamp does not fit a 64-bit frame index")
        return negative ? -Int64(quotient) : Int64(quotient)
    }
}
