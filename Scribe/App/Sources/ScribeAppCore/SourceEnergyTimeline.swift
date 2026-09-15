import Foundation

/// Transcript-free source evidence on the final recording's untrimmed timeline.
public struct SourceEnergyTimeline: Codable, Sendable, Equatable {
    public static let provenance = "source-energy-v1"
    public let version: String
    public let windowMs: Int
    public let windows: [Window]

    public struct Window: Codable, Sendable, Equatable {
        public let startMs: Int
        public let endMs: Int
        public let microphonePower: Double
        public let systemPower: Double
        public let microphoneRatio: Double
        /// Missing capture is not silence evidence.
        public let bothTracksPresent: Bool

        public init(startMs: Int, endMs: Int, microphonePower: Double, systemPower: Double, bothTracksPresent: Bool = true) {
            self.startMs = startMs
            self.endMs = endMs
            self.microphonePower = microphonePower
            self.systemPower = systemPower
            let total = microphonePower + systemPower
            self.microphoneRatio = total > 0 ? microphonePower / total : 0.5
            self.bothTracksPresent = bothTracksPresent
        }

        // -40 dBFS power activity floor; 10 dB dominance. Double-talk always abstains,
        // even when one source is much louder than the other.
        public var microphoneDominant: Bool {
            bothTracksPresent && microphonePower.isFinite && systemPower.isFinite
                && microphonePower >= 0.0001 && systemPower >= 0 && systemPower < 0.0001
                && microphoneRatio >= 10.0 / 11.0
        }
        public var systemDominant: Bool {
            bothTracksPresent && microphonePower.isFinite && systemPower.isFinite
                && systemPower >= 0.0001 && microphonePower >= 0 && microphonePower < 0.0001
                && microphoneRatio <= 1.0 / 11.0
        }
    }

    public init(windows: [Window]) {
        version = Self.provenance
        windowMs = 100
        self.windows = windows
    }

    public var isValid: Bool {
        version == Self.provenance && windowMs == 100 && windows.enumerated().allSatisfy { index, window in
            window.startMs == index * 100 && window.endMs > window.startMs && window.endMs <= window.startMs + 100
                && (index == windows.count - 1 || window.endMs == window.startMs + 100)
                && window.microphonePower.isFinite && window.microphonePower >= 0
                && window.systemPower.isFinite && window.systemPower >= 0
                && window.microphoneRatio.isFinite && (0...1).contains(window.microphoneRatio)
                && abs(window.microphoneRatio - (window.microphonePower + window.systemPower > 0
                    ? window.microphonePower / (window.microphonePower + window.systemPower) : 0.5)) < 0.000001
        }
    }
}
