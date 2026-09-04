import Foundation
import ScribeAppCore

public extension SessionTimeline {
    /// The rate conversions the processing copy needed, in the manifest's own shape.
    ///
    /// A track whose clock was found to be drifting reports the rate it was actually
    /// running at rather than its nominal one, because that is the honest description
    /// of what had to be converted: 48 000 nominal frames arriving over slightly more
    /// or less than a second is a device running at a slightly different rate.
    var resamplingCorrections: [ResamplingCorrection] {
        tracks.compactMap { track in
            let effectiveRate = Double(track.nativeFormat.sampleRate) / track.drift.appliedRatio
            guard effectiveRate != Double(timelineSampleRate) else { return nil }
            return ResamplingCorrection(
                track: track.track,
                originalSampleRate: effectiveRate,
                outputSampleRate: Double(timelineSampleRate)
            )
        }
    }

    /// Everything about the reconstruction a later stage or a reviewer would need,
    /// ready to sit under `processing.configuration` in `metadata.json`.
    var manifestConfiguration: [String: ManifestJSONValue] {
        var configuration: [String: ManifestJSONValue] = [
            "timelineSampleRate": .number(Double(timelineSampleRate)),
            "sessionOriginSeconds": .number(origin.seconds),
            "sessionOriginTimescale": .number(Double(origin.timescale)),
            "durationSeconds": .number(durationSeconds),
        ]
        for track in tracks {
            configuration["track.\(track.track.rawValue)"] = .object([
                "nativeFormat": .string(track.nativeFormat.description),
                "firstMediaTimestampSeconds": .number(track.firstTimestamp.seconds),
                // The measured microphone lead ranged over 2.4 s across ten runs, so
                // this is a per-session fact worth persisting, never a constant.
                "leadingSilenceFrames": .number(Double(track.leadingSilenceFrames)),
                "outputFrameCount": .number(Double(track.outputFrameCount)),
                "runs": .number(Double(track.runs.count)),
                "journaledGapSeconds": .number(track.gaps.reduce(0) { $0 + $1.duration.seconds }),
                "driftPartsPerMillion": .number(track.drift.partsPerMillion),
                "driftCorrected": .boolean(track.drift.corrected),
                "driftRationale": .string(track.drift.rationale),
                "resamplerContextFrames": .number(Double(track.resamplerContextFrames)),
            ])
        }
        let diagnostics = self.diagnostics + tracks.flatMap(\.diagnostics)
        if !diagnostics.isEmpty {
            configuration["timelineDiagnostics"] = .array(diagnostics.map { .string("\($0.code): \($0.message)") })
        }
        return configuration
    }

    /// Reconvergence points for the AEC stage, in seconds from the session origin.
    ///
    /// These are the places the plan says an adaptive filter must be reset: the start,
    /// each journaled discontinuity, and each journaled device change. A route change
    /// is included even though it leaves the timeline continuous, because it can
    /// change the echo path without changing a single timestamp.
    var reconvergenceSeconds: [Double] {
        var points: [Double] = [0]
        for track in tracks {
            for gap in track.gaps {
                points.append(Double(gap.outputStartFrame + gap.outputFrameCount) / Double(timelineSampleRate))
            }
            for run in track.runs.dropFirst() {
                points.append(Double(run.outputStartFrame) / Double(timelineSampleRate))
            }
        }
        return Array(Set(points.map { ($0 * 1_000).rounded() / 1_000 })).sorted()
    }
}
