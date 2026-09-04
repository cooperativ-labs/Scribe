import Foundation

/// The `ground-truth.json` sidecar written by `Tests/Fixtures` next to every fixture case.
public struct FixtureSidecar: Codable, Sendable {
    public struct Interval: Codable, Sendable {
        public let startSeconds: Double
        public let endSeconds: Double

        public init(startSeconds: Double, endSeconds: Double) {
            self.startSeconds = startSeconds
            self.endSeconds = endSeconds
        }

        public func contains(_ seconds: Double) -> Bool { seconds >= startSeconds && seconds < endSeconds }
        public var durationSeconds: Double { max(0, endSeconds - startSeconds) }
    }

    public struct DelaySegment: Codable, Sendable {
        public let startSeconds: Double
        public let endSeconds: Double
        public let delaySamples: Int

        public init(startSeconds: Double, endSeconds: Double, delaySamples: Int) {
            self.startSeconds = startSeconds
            self.endSeconds = endSeconds
            self.delaySamples = delaySamples
        }
    }

    public struct Track: Codable, Sendable {
        public let file: String
        public let sampleRate: Int
        public let channels: Int
        public let variant: String?

        public init(file: String, sampleRate: Int, channels: Int, variant: String? = nil) {
            self.file = file
            self.sampleRate = sampleRate
            self.channels = channels
            self.variant = variant
        }
    }

    public let schemaVersion: Int
    public let caseID: String
    public let description: String
    public let seed: String
    public let durationSeconds: Double
    public let playback: Track
    public let echo: Track
    public let localSpeech: Track
    public let microphone: Track
    public let trueDelaySamples: Int
    public let delaySegments: [DelaySegment]
    public let reverbTaps: [Double]
    public let driftRatio: Double
    public let gapIntervals: [Interval]
    public let nearEndRegions: [Interval]

    public init(
        schemaVersion: Int = 1,
        caseID: String,
        description: String = "",
        seed: String = "0x0",
        durationSeconds: Double,
        playback: Track,
        echo: Track,
        localSpeech: Track,
        microphone: Track,
        trueDelaySamples: Int,
        delaySegments: [DelaySegment] = [],
        reverbTaps: [Double] = [],
        driftRatio: Double = 1,
        gapIntervals: [Interval] = [],
        nearEndRegions: [Interval] = []
    ) {
        self.schemaVersion = schemaVersion
        self.caseID = caseID
        self.description = description
        self.seed = seed
        self.durationSeconds = durationSeconds
        self.playback = playback
        self.echo = echo
        self.localSpeech = localSpeech
        self.microphone = microphone
        self.trueDelaySamples = trueDelaySamples
        self.delaySegments = delaySegments.isEmpty
            ? [DelaySegment(startSeconds: 0, endSeconds: durationSeconds, delaySamples: trueDelaySamples)]
            : delaySegments
        self.reverbTaps = reverbTaps
        self.driftRatio = driftRatio
        self.gapIntervals = gapIntervals
        self.nearEndRegions = nearEndRegions
    }

    /// The reference sample rate the sidecar's delays are expressed in.
    public var referenceSampleRate: Int { playback.sampleRate }

    /// Delay in reference samples that applies at `seconds`, falling back to ``trueDelaySamples``.
    public func delaySamples(atSeconds seconds: Double) -> Int {
        delaySegments.first { seconds >= $0.startSeconds && seconds < $0.endSeconds }?.delaySamples
            ?? delaySegments.last?.delaySamples
            ?? trueDelaySamples
    }

    /// Times at which an echo canceller must reconverge: the file start, every delay-segment
    /// boundary, and the end of every documented capture gap.
    public var reconvergencePoints: [Double] {
        var points = [0.0]
        points.append(contentsOf: delaySegments.map(\.startSeconds).filter { $0 > 0 })
        points.append(contentsOf: gapIntervals.map(\.endSeconds))
        return points.sorted()
    }

    public static func read(contentsOf url: URL) throws -> FixtureSidecar {
        try JSONDecoder().decode(FixtureSidecar.self, from: Data(contentsOf: url))
    }
}
