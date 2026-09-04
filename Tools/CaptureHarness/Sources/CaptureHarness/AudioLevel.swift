import AVFoundation
import Foundation

/// Peak and RMS of one delivered buffer, and a running total per track.
///
/// Level is a *diagnostic*, never a pass/fail signal. IMPLEMENTATION_PLAN.md section 3
/// is explicit that silence is valid input and a silent meeting must not be mistaken for
/// a capture failure. The probes use level only to distinguish "ScreenCaptureKit delivered
/// silence-filled buffers for this filter" from "ScreenCaptureKit delivered the
/// application's audio", which is exactly the question the application-filter matrix asks.
struct AudioLevel: Sendable, Equatable {
    var peak: Double = 0
    var sumOfSquares: Double = 0
    var sampleCount: Int = 0

    var rms: Double { sampleCount > 0 ? (sumOfSquares / Double(sampleCount)).squareRoot() : 0 }
    var peakDBFS: Double { AudioLevel.dbfs(peak) }
    var rmsDBFS: Double { AudioLevel.dbfs(rms) }
    /// True only when every inspected sample was exactly zero.
    var isDigitalSilence: Bool { sampleCount > 0 && peak == 0 }

    static func dbfs(_ amplitude: Double) -> Double {
        amplitude > 0 ? 20 * log10(amplitude) : -.infinity
    }

    mutating func accumulate(_ other: AudioLevel) {
        peak = max(peak, other.peak)
        sumOfSquares += other.sumOfSquares
        sampleCount += other.sampleCount
    }

    var journalObject: [String: Any] {
        [
            "peak": peak,
            "rms": rms,
            "peakDBFS": peakDBFS.isFinite ? peakDBFS : -200,
            "rmsDBFS": rmsDBFS.isFinite ? rmsDBFS : -200,
            "samples": sampleCount,
            "digitalSilence": isDigitalSilence,
        ]
    }

    var described: String {
        guard sampleCount > 0 else { return "no samples" }
        if isDigitalSilence { return "digital silence (every sample exactly zero, \(sampleCount) samples)" }
        return String(format: "peak %.1f dBFS, rms %.1f dBFS", peakDBFS, rmsDBFS)
    }

    /// Measures a buffer without allocating. Handles the float, int16 and int32
    /// layouts an `AVAudioPCMBuffer` can carry; anything else reports no samples so
    /// a level of zero is never invented for a format that was not read.
    static func measure(_ buffer: AVAudioPCMBuffer) -> AudioLevel {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return AudioLevel() }
        let channels = Int(buffer.format.channelCount)
        let interleaved = buffer.format.isInterleaved
        let streams = interleaved ? 1 : channels
        let valuesPerStream = interleaved ? frames * channels : frames

        var level = AudioLevel()
        func consume(_ value: Double) {
            let magnitude = abs(value)
            if magnitude > level.peak { level.peak = magnitude }
            level.sumOfSquares += value * value
            level.sampleCount += 1
        }

        if let data = buffer.floatChannelData {
            for stream in 0..<streams {
                let pointer = data[stream]
                for index in 0..<valuesPerStream { consume(Double(pointer[index])) }
            }
        } else if let data = buffer.int16ChannelData {
            let scale = Double(Int16.max)
            for stream in 0..<streams {
                let pointer = data[stream]
                for index in 0..<valuesPerStream { consume(Double(pointer[index]) / scale) }
            }
        } else if let data = buffer.int32ChannelData {
            let scale = Double(Int32.max)
            for stream in 0..<streams {
                let pointer = data[stream]
                for index in 0..<valuesPerStream { consume(Double(pointer[index]) / scale) }
            }
        } else {
            return AudioLevel()
        }
        return level
    }
}
