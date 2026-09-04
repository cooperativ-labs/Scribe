import Foundation

/// Gate thresholds from implementation-plan section 8. All are configurable so a test can assert
/// a stricter or looser bound without changing the tool.
public struct GateThresholds: Sendable {
    public var minimumEchoReductionDb: Double = 20
    public var maximumNearEndLevelChangeDb: Double = 1
    public var maximumAlignmentErrorMilliseconds: Double = 10
    public var durationToleranceMilliseconds: Double = 10
    public var truePeakCeilingDbTP: Double = -1
    public var maximumClippedSamples: Int = 0

    public init() {}
}

public struct MetricsOptions: Sendable {
    /// Analysis block length; the plan's alignment gate is expressed in 10 ms processing blocks.
    public var blockMilliseconds: Double = 10
    /// Echo-reduction blocks are ignored until this long after every reconvergence point.
    public var convergenceWindowSeconds: Double = 1
    /// Processing delay the caller states the processed file carries, compensated before
    /// every energy comparison.
    public var processingDelayMilliseconds: Double = 0
    /// Length of the leading and trailing windows used for alignment estimation. One second is
    /// wide enough to span a silent phrase in the fixture speech signals.
    public var alignmentWindowSeconds: Double = 1
    /// Half-width of the lag search.
    public var maximumLagMilliseconds: Double = 120
    /// Magnitude at or above which a sample counts as clipped (1.0 minus half a 16-bit step).
    public var clipThreshold: Double = 0.99998
    /// Blocks quieter than this are treated as inactive.
    public var activityFloorDb: Double = -70
    /// Blocks more than this far below the loudest reference block are treated as inactive.
    public var activityRelativeDb: Double = 40
    /// Whole-file correlation between the ground-truth echo track and the microphone above which
    /// the fixture's echo path is considered to reach the microphone at all.
    public var farEndPresenceCorrelation: Double = 0.15
    /// Correlation below which an echo-path delay estimate is reported but not gated.
    public var minimumEchoPathCorrelation: Double = 0.5
    public var gates = GateThresholds()

    public init() {}
}
