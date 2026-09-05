import FLACBridge
import Foundation
import ScribeAppCore
import WebRTCBridge

extension MixdownService {
    /// The pinned dependencies this stage's output actually came out of, read from
    /// the linked builds rather than restated as literals that could drift.
    static var dependencyVersions: [String: String] {
        [
            "webrtc-audio-processing": WebRTCBridge.EchoCanceller.upstreamRevision,
            "FLACBridge": "system-audiotoolbox-verified",
        ]
    }

    func successManifest(
        _ manifest: RecorderSessionManifest,
        timeline: SessionTimeline,
        summary: MixdownSummary,
        encoded: FLACEncodeResult,
        options: Options
    ) -> RecorderSessionManifest {
        var configuration = timeline.manifestConfiguration
        configuration.merge(manifest.processing.configuration) { new, _ in new }
        configuration["mixdown"] = .object(mixdownConfiguration(summary: summary, options: options))
        let finalTrack = RecorderTrackManifest(
            sourceFormat: AudioSourceFormat(
                sampleRate: Double(timelineSampleRate),
                channelCount: 1,
                formatDescription: "48000 Hz mono 16-bit FLAC; original system signal mixed with the echo-cancelled microphone for transcription"
            ),
            firstMediaTimestampSeconds: timeline.origin.seconds,
            frameCount: encoded.frameCount,
            fileName: Self.outputFileName,
            checksum: encoded.sha256,
            journalReference: Self.journalReference
        )
        return replacing(
            manifest,
            tracks: RecorderTrackCollection(system: manifest.tracks.system, microphone: manifest.tracks.microphone, finalTrack: finalTrack),
            processing: ProcessingMetadata(
                state: .complete,
                dependencyVersions: manifest.processing.dependencyVersions.merging(Self.dependencyVersions) { _, new in new },
                configuration: configuration,
                resamplingCorrections: timeline.resamplingCorrections,
                delayCorrections: delayCorrections(summary),
                mixGains: [
                    "system": Double(summary.systemGain),
                    "microphoneCentre": Double(summary.microphoneGain),
                    "peakControl": summary.appliedPeakGain,
                ],
                errors: manifest.processing.errors.filter {
                    !$0.code.hasPrefix("mixdown.") && $0.code != "processing.pipeline"
                }
            )
        )
    }

    func failureManifest(
        _ manifest: RecorderSessionManifest,
        timeline: SessionTimeline,
        options: Options,
        error: MixdownError
    ) -> RecorderSessionManifest {
        var configuration = manifest.processing.configuration
        configuration["mixdown"] = .object([
            "attempted": .boolean(true),
            "outcome": .string("failed"),
            "reason": .string(error.description),
            // Recorded so a rerun, or a person reading the session later, can see
            // that the originals were deliberately kept rather than lost.
            "originalsRetained": .boolean(true),
            "publishedFinalMix": .boolean(false),
            "truePeakCeilingDbTP": .number(options.truePeakCeilingDbTP),
        ])
        return replacing(
            manifest,
            // The previously published final track, if there was one, is untouched
            // on disk and stays described here; a failed job never unpublishes a
            // valid result.
            tracks: manifest.tracks,
            processing: ProcessingMetadata(
                state: .failed,
                dependencyVersions: manifest.processing.dependencyVersions.merging(Self.dependencyVersions) { _, new in new },
                configuration: configuration,
                resamplingCorrections: timeline.resamplingCorrections,
                delayCorrections: manifest.processing.delayCorrections,
                mixGains: manifest.processing.mixGains,
                errors: manifest.processing.errors.filter { $0.code != error.code }
                    + [ManifestError(code: error.code, message: error.description)]
            )
        )
    }

    /// Every delay this stage applied or declared, in the manifest's own shape.
    private func delayCorrections(_ summary: MixdownSummary) -> [DelayCorrection] {
        var corrections: [DelayCorrection] = [
            // The only shift applied to the microphone: the latency the module
            // itself introduced, measured from this build and removed so the
            // cleaned track lands back on its own capture timeline.
            DelayCorrection(track: .microphone, delaySeconds: -summary.processingLatencySeconds)
        ]
        if case .cancel(let segments) = summary.decision, let first = segments.first {
            // Declared to AEC3 as the render-to-capture delay. Nothing is moved by
            // it; it tells the module where in the reference to look.
            corrections.append(DelayCorrection(track: .system, delaySeconds: Double(first.delaySamples) / Double(timelineSampleRate)))
        }
        return corrections
    }

    private func mixdownConfiguration(summary: MixdownSummary, options: Options) -> [String: ManifestJSONValue] {
        let plan = summary.delayPlan
        var details: [String: ManifestJSONValue] = [
            "outcome": .string("complete"),
            "blockFrames": .number(Double(options.echoCanceller.blockFrames)),
            "renderChannelCount": .number(Double(options.echoCanceller.renderChannelCount)),
            "captureChannelCount": .number(Double(options.echoCanceller.captureChannelCount)),
            "noiseSuppressionEnabled": .boolean(options.echoCanceller.noiseSuppressionEnabled),
            "gainControllerEnabled": .boolean(options.echoCanceller.gainControllerEnabled),
            "highPassFilterEnabled": .boolean(options.echoCanceller.highPassFilterEnabled),
            "echoPathDecision": .string(summary.decision.summary),
            "measuredProcessingLatencyFrames": .number(Double(summary.processingLatencyFrames)),
            "measuredProcessingLatencySeconds": .number(summary.processingLatencySeconds),
            "referenceActiveSeconds": .number(plan.referenceActiveSeconds),
            "analysisWindows": .number(Double(plan.windows.count)),
            "bestWindowCorrelation": plan.bestCorrelation.map(ManifestJSONValue.number) ?? .null,
            "systemGain": .number(Double(summary.systemGain)),
            "microphoneCentreGain": .number(Double(summary.microphoneGain)),
            "truePeakCeilingDbTP": .number(summary.truePeakCeilingDbTP),
            "truePeakMeasurementEnabled": .boolean(false),
            "truePeakBeforeGainDbTP": .null,
            "samplePeakBeforeGainDbFS": summary.samplePeakBeforeGain > 0 ? .number(20 * log10(summary.samplePeakBeforeGain)) : .null,
            "appliedPeakGain": .number(summary.appliedPeakGain),
            "peakControl": .string("fixed 0.44 source gains reserve about 1.1 dB of sample headroom; no scratch-file normalization pass"),
            "delaySegments": .array(delaySegments(summary)),
            "reconvergencePoints": .array(summary.reconvergences.map { point in
                .object([
                    "seconds": .number(point.seconds),
                    "reason": .string(point.reason),
                    "declaredDelaySamples": point.delaySamples.map { .number(Double($0)) } ?? .null,
                ])
            }),
        ]
        if case .noEchoPath(let correlation) = summary.decision {
            details["microphonePassedThrough"] = .string(
                "the reference played but nothing correlated with it reached the microphone (best correlation \(correlation.map { String(format: "%.3f", $0) } ?? "none")), so there was no echo to cancel")
        }
        if case .noReferenceActivity = summary.decision {
            details["microphonePassedThrough"] = .string("the system track carried no audio, so no echo can exist")
        }
        var metrics: [String: ManifestJSONValue] = [:]
        if let value = summary.metrics.echoReturnLoss { metrics["echoReturnLossDb"] = .number(value) }
        if let value = summary.metrics.echoReturnLossEnhancement { metrics["echoReturnLossEnhancementDb"] = .number(value) }
        if let value = summary.metrics.medianDelayMilliseconds { metrics["moduleMedianDelayMs"] = .number(Double(value)) }
        if let value = summary.metrics.residualEchoLikelihood { metrics["residualEchoLikelihood"] = .number(value) }
        if !metrics.isEmpty { details["moduleMetrics"] = .object(metrics) }
        return details
    }

    private func delaySegments(_ summary: MixdownSummary) -> [ManifestJSONValue] {
        guard case .cancel(let segments) = summary.decision else { return [] }
        return segments.map { segment in
            .object([
                "startSeconds": .number(segment.startSeconds),
                "delaySamples": .number(Double(segment.delaySamples)),
                "delayMilliseconds": .number(segment.delayMilliseconds),
                "correlation": .number(segment.correlation),
                "peakMargin": .number(segment.margin),
                "confidence": .number(segment.confidence),
                "supportingWindows": .number(Double(segment.windowCount)),
                "basis": .string(segment.basis),
            ])
        }
    }

    private func replacing(
        _ manifest: RecorderSessionManifest,
        tracks: RecorderTrackCollection,
        processing: ProcessingMetadata
    ) -> RecorderSessionManifest {
        RecorderSessionManifest(
            schemaVersion: manifest.schemaVersion,
            sessionID: manifest.sessionID,
            appBuild: manifest.appBuild,
            macOSVersion: manifest.macOSVersion,
            startedAt: manifest.startedAt,
            endedAt: manifest.endedAt,
            durationSeconds: manifest.durationSeconds,
            completionStatus: manifest.completionStatus,
            capture: manifest.capture,
            tracks: tracks,
            gaps: manifest.gaps,
            interruptions: manifest.interruptions,
            processing: processing
        )
    }
}
