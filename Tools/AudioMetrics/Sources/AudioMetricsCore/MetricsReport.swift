import Foundation

public enum RegionClass: String, Sendable, CaseIterable {
    case farEndOnly = "far-end-only"
    case nearEndOnly = "near-end-only"
    case doubleTalk = "double-talk"
    case silent = "silent"
    case gap = "gap"
}

public struct ReductionStatistics: Sendable {
    public let blocks: Int
    public let medianDb: Double?
    public let meanDb: Double?
    public let minimumDb: Double?
    public let percentile10Db: Double?

    public init(reductions: [Double]) {
        blocks = reductions.count
        medianDb = Signal.median(reductions)
        meanDb = reductions.isEmpty ? nil : reductions.reduce(0, +) / Double(reductions.count)
        minimumDb = reductions.min()
        percentile10Db = Signal.percentile(reductions, 0.10)
    }
}

public struct NearEndStatistics: Sendable {
    public let blocks: Int
    public let regionSeconds: Double
    public let microphoneLevelDbFS: Double?
    public let outputLevelDbFS: Double?
    /// Positive means the processed output is louder than the microphone input.
    public let levelChangeDb: Double?
    public let medianBlockLevelChangeDb: Double?
    public let maximumBlockLevelChangeDb: Double?
}

public struct TimelineAlignment: Sendable {
    public let measuredLagSamples: Int
    public let measuredLagMilliseconds: Double
    public let statedProcessingDelayMilliseconds: Double
    public let residualErrorSamples: Int
    public let residualErrorMilliseconds: Double
    public let correlation: Double
}

public struct EchoPathAlignment: Sendable {
    public let expectedDelaySamples: Int
    public let measuredDelaySamples: Int
    public let errorSamples: Int
    public let errorMilliseconds: Double
    public let correlation: Double
    /// False when the estimate is uncalibrated: no echo in the microphone, competing near-end
    /// speech in the window, a periodic (tonal) reference, or weak correlation.
    public let reliable: Bool
}

/// Whether the fixture's echo path reaches the microphone at all. The generator writes an echo
/// track for every case, including the ones that never mix it into the microphone.
public struct FarEndPresence: Sendable {
    public let presenceCorrelation: Double?
    public let reachesMicrophone: Bool
}

public struct AlignmentWindowResult: Sendable {
    public let label: String
    public let windowStartSeconds: Double
    public let windowSeconds: Double
    public let timeline: TimelineAlignment?
    public let echoPath: EchoPathAlignment?
}

public struct DurationResult: Sendable {
    public let expectedSeconds: Double
    public let microphoneSeconds: Double
    public let processedSeconds: Double
    public let deltaMillisecondsVersusExpected: Double
    public let deltaMillisecondsVersusMicrophone: Double
    public let matchesExpected: Bool
}

public struct ChannelPeaks: Sendable {
    public let channel: Int
    public let samplePeak: Double
    public let samplePeakDbFS: Double?
    public let truePeak: Double
    public let truePeakDbTP: Double?
    public let clippedSamples: Int
    public let clippedRuns: Int
    public let longestClippedRunSamples: Int
}

public struct PeakResult: Sendable {
    public let threshold: Double
    public let perChannel: [ChannelPeaks]
    public let clippedSamples: Int
    public let clippedFraction: Double
    public let samplePeakDbFS: Double?
    public let truePeakDbTP: Double?
}

public struct Gate: Sendable {
    public let name: String
    public let comparison: String
    public let thresholdValue: Double
    public let measured: Double?
    public let unit: String
    public let applicable: Bool
    public let passed: Bool
    public let note: String?
}

public struct MetricsReport: Sendable {
    public let caseID: String
    public let fixtureDirectory: String
    public let processedFile: String
    public let processedIsFixtureMicrophone: Bool
    public let analysisSampleRate: Int
    public let blockSamples: Int
    public let analyzedBlocks: Int
    public let options: MetricsOptions
    public let farEnd: FarEndPresence
    public let regionSeconds: [RegionClass: Double]
    public let reductionByRegion: [RegionClass: ReductionStatistics]
    public let reductionFarEndActive: ReductionStatistics
    public let nearEnd: NearEndStatistics?
    public let alignment: [AlignmentWindowResult]
    public let duration: DurationResult
    public let peaks: PeakResult
    public var gates: [Gate]

    public var allApplicableGatesPassed: Bool { gates.allSatisfy { !$0.applicable || $0.passed } }
    public var failedGates: [Gate] { gates.filter { $0.applicable && !$0.passed } }
}
