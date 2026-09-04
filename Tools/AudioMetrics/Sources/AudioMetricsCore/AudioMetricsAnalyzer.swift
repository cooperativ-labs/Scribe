import Foundation

public enum MetricsError: Error, CustomStringConvertible {
    case missingFile(String)
    case emptyAudio(String)

    public var description: String {
        switch self {
        case .missingFile(let path): return "missing file: \(path)"
        case .emptyAudio(let name): return "\(name) contains no audio frames"
        }
    }
}

/// Compares a processed microphone track against a generated fixture and its ground-truth
/// sidecar, producing the measurements behind the implementation-plan section 8 gates.
public enum AudioMetricsAnalyzer {
    public static let reportSchemaVersion = 1

    /// Loads a fixture directory. When `processedURL` is nil the fixture's own microphone track
    /// is analyzed, which is the unprocessed baseline the exit criteria call for.
    public static func analyze(
        fixtureDirectory: URL,
        sidecarURL: URL? = nil,
        processedURL: URL? = nil,
        options: MetricsOptions = MetricsOptions()
    ) throws -> MetricsReport {
        let sidecarPath = sidecarURL ?? fixtureDirectory.appendingPathComponent("ground-truth.json")
        guard FileManager.default.fileExists(atPath: sidecarPath.path) else {
            throw MetricsError.missingFile(sidecarPath.path)
        }
        let sidecar = try FixtureSidecar.read(contentsOf: sidecarPath)
        let microphoneURL = fixtureDirectory.appendingPathComponent(sidecar.microphone.file)
        let processedPath = processedURL ?? microphoneURL
        guard FileManager.default.fileExists(atPath: processedPath.path) else {
            throw MetricsError.missingFile(processedPath.path)
        }

        let inputs = FixtureInputs(
            microphone: try WAVFile.read(contentsOf: microphoneURL),
            playback: try WAVFile.read(contentsOf: fixtureDirectory.appendingPathComponent(sidecar.playback.file)),
            echo: try WAVFile.read(contentsOf: fixtureDirectory.appendingPathComponent(sidecar.echo.file))
        )
        return try analyze(
            sidecar: sidecar,
            inputs: inputs,
            processed: try WAVFile.read(contentsOf: processedPath),
            fixtureDirectory: fixtureDirectory.path,
            processedFile: processedPath.path,
            processedIsFixtureMicrophone: processedPath.standardizedFileURL == microphoneURL.standardizedFileURL,
            options: options
        )
    }

    public struct FixtureInputs: Sendable {
        public let microphone: WAVFile
        public let playback: WAVFile
        public let echo: WAVFile

        public init(microphone: WAVFile, playback: WAVFile, echo: WAVFile) {
            self.microphone = microphone
            self.playback = playback
            self.echo = echo
        }
    }

    public static func analyze(
        sidecar: FixtureSidecar,
        inputs: FixtureInputs,
        processed: WAVFile,
        fixtureDirectory: String = "",
        processedFile: String = "",
        processedIsFixtureMicrophone: Bool = false,
        options: MetricsOptions = MetricsOptions()
    ) throws -> MetricsReport {
        guard processed.frameCount > 0 else { throw MetricsError.emptyAudio("processed output") }
        guard inputs.microphone.frameCount > 0 else { throw MetricsError.emptyAudio("microphone track") }

        let rate = processed.sampleRate
        let microphone = Signal.resample(inputs.microphone.mono, from: inputs.microphone.sampleRate, to: rate)
        let playback = Signal.resample(inputs.playback.mono, from: inputs.playback.sampleRate, to: rate)
        let echo = Signal.resample(inputs.echo.mono, from: inputs.echo.sampleRate, to: rate)
        let output = processed.mono

        let delaySamples = Int((options.processingDelayMilliseconds * Double(rate) / 1000).rounded())
        let analyzedFrames = min(microphone.count, output.count)
        var compensated = Array(repeating: 0.0, count: analyzedFrames)
        for index in 0..<analyzedFrames {
            let source = index + delaySamples
            compensated[index] = source >= 0 && source < output.count ? output[source] : 0
        }

        let blockSamples = max(1, Int((options.blockMilliseconds * Double(rate) / 1000).rounded()))
        let blockCount = analyzedFrames / blockSamples
        let blockSeconds = Double(blockSamples) / Double(rate)

        // The fixture always ships an echo track, but only some cases route it into the
        // microphone. Decide from the microphone itself so a near-end-only case is not
        // mistaken for double-talk.
        let presenceCorrelation = Signal.correlation(
            Array(echo.prefix(analyzedFrames)),
            Array(microphone.prefix(analyzedFrames))
        )
        let echoReachesMicrophone = abs(presenceCorrelation ?? 0) >= options.farEndPresenceCorrelation
        let trackActive = activityMask(echo, blockSamples: blockSamples, blocks: blockCount, options: options)
        let echoActive = echoReachesMicrophone ? trackActive : Array(repeating: false, count: blockCount)
        let reconvergence = sidecar.reconvergencePoints

        var regionSeconds = Dictionary(uniqueKeysWithValues: RegionClass.allCases.map { ($0, 0.0) })
        var reductions = Dictionary(uniqueKeysWithValues: RegionClass.allCases.map { ($0, [Double]()) })
        var farEndActiveReductions: [Double] = []
        var nearEndBlockChanges: [Double] = []
        var nearEndMicrophoneEnergy = 0.0
        var nearEndOutputEnergy = 0.0
        var nearEndBlocks = 0

        for block in 0..<blockCount {
            let start = block * blockSamples
            let range = start..<(start + blockSamples)
            let startSeconds = Double(start) / Double(rate)
            let centerSeconds = startSeconds + blockSeconds / 2

            let inGap = sidecar.gapIntervals.contains { $0.startSeconds < startSeconds + blockSeconds && $0.endSeconds > startSeconds }
            let nearEnd = sidecar.nearEndRegions.contains { $0.contains(centerSeconds) }
            let region: RegionClass
            if inGap {
                region = .gap
            } else if echoActive[block] {
                region = nearEnd ? .doubleTalk : .farEndOnly
            } else {
                region = nearEnd ? .nearEndOnly : .silent
            }
            regionSeconds[region, default: 0] += blockSeconds
            guard region != .gap else { continue }

            let converged = isConverged(startSeconds: startSeconds, points: reconvergence, window: options.convergenceWindowSeconds)
            guard converged else { continue }

            let microphoneEnergy = Signal.energy(microphone[range])
            let outputEnergy = Signal.energy(compensated[range])
            let microphoneRms = (microphoneEnergy / Double(blockSamples)).squareRoot()
            guard let level = Signal.decibels(microphoneRms), level >= options.activityFloorDb else { continue }

            switch region {
            case .farEndOnly, .doubleTalk:
                let reduction = Signal.energyRatioDb(numerator: microphoneEnergy, denominator: outputEnergy)
                reductions[region, default: []].append(reduction)
                farEndActiveReductions.append(reduction)
            case .nearEndOnly:
                nearEndBlocks += 1
                nearEndMicrophoneEnergy += microphoneEnergy
                nearEndOutputEnergy += outputEnergy
                nearEndBlockChanges.append(Signal.energyRatioDb(numerator: outputEnergy, denominator: microphoneEnergy))
            case .silent, .gap:
                break
            }
        }

        let nearEnd: NearEndStatistics? = nearEndBlocks == 0 ? nil : NearEndStatistics(
            blocks: nearEndBlocks,
            regionSeconds: Double(nearEndBlocks) * blockSeconds,
            microphoneLevelDbFS: Signal.decibels((nearEndMicrophoneEnergy / Double(nearEndBlocks * blockSamples)).squareRoot()),
            outputLevelDbFS: Signal.decibels((nearEndOutputEnergy / Double(nearEndBlocks * blockSamples)).squareRoot()),
            levelChangeDb: Signal.energyRatioDb(numerator: nearEndOutputEnergy, denominator: nearEndMicrophoneEnergy),
            medianBlockLevelChangeDb: Signal.median(nearEndBlockChanges),
            maximumBlockLevelChangeDb: nearEndBlockChanges.map(abs).max()
        )

        let alignment = alignmentWindows(
            sidecar: sidecar,
            rate: rate,
            analyzedFrames: analyzedFrames,
            microphone: microphone,
            playback: playback,
            output: output,
            delaySamples: delaySamples,
            echoReachesMicrophone: echoReachesMicrophone,
            options: options
        )

        let duration = DurationResult(
            expectedSeconds: sidecar.durationSeconds,
            microphoneSeconds: inputs.microphone.durationSeconds,
            processedSeconds: processed.durationSeconds,
            deltaMillisecondsVersusExpected: (processed.durationSeconds - sidecar.durationSeconds) * 1000,
            deltaMillisecondsVersusMicrophone: (processed.durationSeconds - inputs.microphone.durationSeconds) * 1000,
            matchesExpected: abs(processed.durationSeconds - sidecar.durationSeconds) * 1000
                <= options.gates.durationToleranceMilliseconds
        )

        let peaks = peakResult(processed: processed, options: options)
        let reductionStatistics = Dictionary(uniqueKeysWithValues: reductions.map { ($0.key, ReductionStatistics(reductions: $0.value)) })

        var report = MetricsReport(
            caseID: sidecar.caseID,
            fixtureDirectory: fixtureDirectory,
            processedFile: processedFile,
            processedIsFixtureMicrophone: processedIsFixtureMicrophone,
            analysisSampleRate: rate,
            blockSamples: blockSamples,
            analyzedBlocks: blockCount,
            options: options,
            farEnd: FarEndPresence(
                presenceCorrelation: presenceCorrelation,
                reachesMicrophone: echoReachesMicrophone
            ),
            regionSeconds: regionSeconds,
            reductionByRegion: reductionStatistics,
            reductionFarEndActive: ReductionStatistics(reductions: farEndActiveReductions),
            nearEnd: nearEnd,
            alignment: alignment,
            duration: duration,
            peaks: peaks,
            gates: []
        )
        report.gates = gates(for: report)
        return report
    }

    // MARK: - Stages

    /// Marks blocks where the ground-truth echo track is active, relative to its own loudest block.
    static func activityMask(_ signal: [Double], blockSamples: Int, blocks: Int, options: MetricsOptions) -> [Bool] {
        guard blocks > 0 else { return [] }
        var levels = Array(repeating: -Double.infinity, count: blocks)
        for block in 0..<blocks {
            let start = block * blockSamples
            guard start + blockSamples <= signal.count else { continue }
            if let level = Signal.decibels(Signal.rms(signal[start..<(start + blockSamples)])) { levels[block] = level }
        }
        guard let loudest = levels.max(), loudest.isFinite else { return Array(repeating: false, count: blocks) }
        let threshold = max(options.activityFloorDb, loudest - options.activityRelativeDb)
        return levels.map { $0 >= threshold }
    }

    static func isConverged(startSeconds: Double, points: [Double], window: Double) -> Bool {
        let latest = points.filter { $0 <= startSeconds + 1e-9 }.max() ?? 0
        return startSeconds - latest >= window - 1e-9
    }

    static func alignmentWindows(
        sidecar: FixtureSidecar,
        rate: Int,
        analyzedFrames: Int,
        microphone: [Double],
        playback: [Double],
        output: [Double],
        delaySamples: Int,
        echoReachesMicrophone: Bool,
        options: MetricsOptions
    ) -> [AlignmentWindowResult] {
        let maximumLag = max(1, Int((options.maximumLagMilliseconds * Double(rate) / 1000).rounded()))
        let windowFrames = max(1, min(analyzedFrames, Int((options.alignmentWindowSeconds * Double(rate)).rounded())))
        let windows = [
            ("start", 0..<windowFrames),
            ("end", max(0, analyzedFrames - windowFrames)..<analyzedFrames),
        ]
        return windows.map { label, range in
            let windowStartSeconds = Double(range.lowerBound) / Double(rate)
            let windowSeconds = Double(range.count) / Double(rate)

            var timeline: TimelineAlignment?
            if let estimate = Signal.bestLag(
                reference: microphone,
                target: output,
                targetRange: range,
                lagRange: (-maximumLag)...maximumLag
            ) {
                let residual = estimate.lagSamples - delaySamples
                timeline = TimelineAlignment(
                    measuredLagSamples: estimate.lagSamples,
                    measuredLagMilliseconds: Double(estimate.lagSamples) * 1000 / Double(rate),
                    statedProcessingDelayMilliseconds: options.processingDelayMilliseconds,
                    residualErrorSamples: residual,
                    residualErrorMilliseconds: Double(residual) * 1000 / Double(rate),
                    correlation: estimate.correlation
                )
            }

            var echoPath: EchoPathAlignment?
            let referenceDelay = sidecar.delaySamples(atSeconds: windowStartSeconds + windowSeconds / 2)
            let expected = Int((Double(referenceDelay) * Double(rate) / Double(sidecar.referenceSampleRate)).rounded())
            if let estimate = Signal.bestLag(
                reference: playback,
                target: microphone,
                targetRange: range,
                lagRange: (-maximumLag)...maximumLag
            ) {
                // A delay estimate only means something when the echo actually reaches the
                // microphone, the window carries no competing near-end speech, and the playback
                // reference is broadband. A tonal reference is periodic, so its correlation peak
                // is ambiguous by design; the measurement is still reported, just not gated.
                let nearEndOverlap = sidecar.nearEndRegions.contains {
                    $0.startSeconds < windowStartSeconds + windowSeconds && $0.endSeconds > windowStartSeconds
                }
                let broadbandReference = sidecar.playback.variant == "speech-like"
                let reliable = echoReachesMicrophone
                    && !nearEndOverlap
                    && broadbandReference
                    && estimate.correlation >= options.minimumEchoPathCorrelation
                let error = estimate.lagSamples - expected
                echoPath = EchoPathAlignment(
                    expectedDelaySamples: expected,
                    measuredDelaySamples: estimate.lagSamples,
                    errorSamples: error,
                    errorMilliseconds: Double(error) * 1000 / Double(rate),
                    correlation: estimate.correlation,
                    reliable: reliable
                )
            }
            return AlignmentWindowResult(
                label: label,
                windowStartSeconds: windowStartSeconds,
                windowSeconds: windowSeconds,
                timeline: timeline,
                echoPath: echoPath
            )
        }
    }

    static func peakResult(processed: WAVFile, options: MetricsOptions) -> PeakResult {
        let channels = processed.channels.enumerated().map { index, samples -> ChannelPeaks in
            let summary = Signal.clipping(samples, threshold: options.clipThreshold)
            let truePeak = Signal.truePeak(samples)
            return ChannelPeaks(
                channel: index,
                samplePeak: summary.samplePeak,
                samplePeakDbFS: Signal.decibels(summary.samplePeak),
                truePeak: truePeak,
                truePeakDbTP: Signal.decibels(truePeak),
                clippedSamples: summary.clippedSamples,
                clippedRuns: summary.clippedRuns,
                longestClippedRunSamples: summary.longestRunSamples
            )
        }
        let clipped = channels.reduce(0) { $0 + $1.clippedSamples }
        let total = max(1, processed.frameCount * max(1, processed.channelCount))
        return PeakResult(
            threshold: options.clipThreshold,
            perChannel: channels,
            clippedSamples: clipped,
            clippedFraction: Double(clipped) / Double(total),
            samplePeakDbFS: Signal.decibels(channels.map(\.samplePeak).max() ?? 0),
            truePeakDbTP: Signal.decibels(channels.map(\.truePeak).max() ?? 0)
        )
    }

    static func gates(for report: MetricsReport) -> [Gate] {
        let thresholds = report.options.gates
        var gates: [Gate] = []

        let farEndOnly = report.reductionByRegion[.farEndOnly]
        gates.append(Gate(
            name: "echoEnergyReductionDb",
            comparison: ">=",
            thresholdValue: thresholds.minimumEchoReductionDb,
            measured: farEndOnly?.medianDb,
            unit: "dB",
            applicable: (farEndOnly?.blocks ?? 0) > 0,
            passed: (farEndOnly?.medianDb ?? -.infinity) >= thresholds.minimumEchoReductionDb,
            note: (farEndOnly?.blocks ?? 0) > 0
                ? "Median of converged far-end-only blocks."
                : "No converged far-end-only blocks in this fixture."
        ))

        gates.append(Gate(
            name: "nearEndLevelChangeDb",
            comparison: "<=",
            thresholdValue: thresholds.maximumNearEndLevelChangeDb,
            measured: report.nearEnd?.levelChangeDb.map(abs),
            unit: "dB",
            applicable: report.nearEnd != nil,
            passed: abs(report.nearEnd?.levelChangeDb ?? .infinity) <= thresholds.maximumNearEndLevelChangeDb,
            note: report.nearEnd == nil
                ? "No converged near-end-only blocks in this fixture."
                : "Magnitude of the level change over converged near-end-only blocks."
        ))

        for window in report.alignment {
            let residual = window.timeline?.residualErrorMilliseconds
            gates.append(Gate(
                name: "alignmentErrorMs.\(window.label)",
                comparison: "<=",
                thresholdValue: thresholds.maximumAlignmentErrorMilliseconds,
                measured: residual.map(abs),
                unit: "ms",
                applicable: residual != nil,
                passed: abs(residual ?? .infinity) <= thresholds.maximumAlignmentErrorMilliseconds,
                note: "Processed-versus-microphone lag at the \(window.label) window, minus the stated processing delay."
            ))
        }

        for window in report.alignment {
            let path = window.echoPath
            let error = path.map { abs($0.errorMilliseconds) }
            gates.append(Gate(
                name: "echoPathDelayErrorMs.\(window.label)",
                comparison: "<=",
                thresholdValue: thresholds.maximumAlignmentErrorMilliseconds,
                measured: error,
                unit: "ms",
                applicable: path?.reliable ?? false,
                passed: (error ?? .infinity) <= thresholds.maximumAlignmentErrorMilliseconds,
                note: path?.reliable == true
                    ? "Measured playback-to-microphone delay against the sidecar's known delay."
                    : "Delay estimate is not calibrated for this window (no echo in the microphone, competing near-end speech, a tonal reference, or weak correlation)."
            ))
        }

        gates.append(Gate(
            name: "durationMatchMs",
            comparison: "<=",
            thresholdValue: thresholds.durationToleranceMilliseconds,
            measured: abs(report.duration.deltaMillisecondsVersusExpected),
            unit: "ms",
            applicable: true,
            passed: report.duration.matchesExpected,
            note: "Processed duration against the fixture's ground-truth duration."
        ))

        gates.append(Gate(
            name: "truePeakDbTP",
            comparison: "<=",
            thresholdValue: thresholds.truePeakCeilingDbTP,
            measured: report.peaks.truePeakDbTP,
            unit: "dBTP",
            applicable: report.peaks.truePeakDbTP != nil,
            passed: (report.peaks.truePeakDbTP ?? -.infinity) <= thresholds.truePeakCeilingDbTP,
            note: "4x oversampled peak across all processed channels."
        ))

        gates.append(Gate(
            name: "clippedSamples",
            comparison: "<=",
            thresholdValue: Double(thresholds.maximumClippedSamples),
            measured: Double(report.peaks.clippedSamples),
            unit: "samples",
            applicable: true,
            passed: report.peaks.clippedSamples <= thresholds.maximumClippedSamples,
            note: "Samples at or above \(report.peaks.threshold) full scale."
        ))

        return gates
    }
}
