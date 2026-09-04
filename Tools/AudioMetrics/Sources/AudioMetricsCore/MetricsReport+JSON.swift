import Foundation

extension ReductionStatistics {
    var json: JSONValue {
        .object([
            "blocks": .int(blocks),
            "medianReductionDb": .number(medianDb),
            "meanReductionDb": .number(meanDb),
            "minimumReductionDb": .number(minimumDb),
            "percentile10ReductionDb": .number(percentile10Db),
        ])
    }
}

extension NearEndStatistics {
    var json: JSONValue {
        .object([
            "blocks": .int(blocks),
            "regionSeconds": .double(regionSeconds),
            "microphoneLevelDbFS": .number(microphoneLevelDbFS),
            "outputLevelDbFS": .number(outputLevelDbFS),
            "levelChangeDb": .number(levelChangeDb),
            "medianBlockLevelChangeDb": .number(medianBlockLevelChangeDb),
            "maximumAbsoluteBlockLevelChangeDb": .number(maximumBlockLevelChangeDb),
        ])
    }
}

extension AlignmentWindowResult {
    var json: JSONValue {
        .object([
            "window": .string(label),
            "windowStartSeconds": .double(windowStartSeconds),
            "windowSeconds": .double(windowSeconds),
            "timeline": timeline.map { alignment in
                .object([
                    "measuredLagSamples": .int(alignment.measuredLagSamples),
                    "measuredLagMilliseconds": .double(alignment.measuredLagMilliseconds),
                    "statedProcessingDelayMilliseconds": .double(alignment.statedProcessingDelayMilliseconds),
                    "residualErrorSamples": .int(alignment.residualErrorSamples),
                    "residualErrorMilliseconds": .double(alignment.residualErrorMilliseconds),
                    "correlation": .double(alignment.correlation),
                ])
            } ?? .null,
            "echoPath": echoPath.map { path in
                .object([
                    "expectedDelaySamples": .int(path.expectedDelaySamples),
                    "measuredDelaySamples": .int(path.measuredDelaySamples),
                    "errorSamples": .int(path.errorSamples),
                    "errorMilliseconds": .double(path.errorMilliseconds),
                    "correlation": .double(path.correlation),
                    "reliable": .bool(path.reliable),
                ])
            } ?? .null,
        ])
    }
}

extension DurationResult {
    var json: JSONValue {
        .object([
            "expectedSeconds": .double(expectedSeconds),
            "microphoneSeconds": .double(microphoneSeconds),
            "processedSeconds": .double(processedSeconds),
            "deltaMillisecondsVersusExpected": .double(deltaMillisecondsVersusExpected),
            "deltaMillisecondsVersusMicrophone": .double(deltaMillisecondsVersusMicrophone),
            "matchesExpected": .bool(matchesExpected),
        ])
    }
}

extension PeakResult {
    var json: JSONValue {
        .object([
            "clipThreshold": .double(threshold),
            "clippedSamples": .int(clippedSamples),
            "clippedFraction": .double(clippedFraction),
            "samplePeakDbFS": .number(samplePeakDbFS),
            "truePeakDbTP": .number(truePeakDbTP),
            "perChannel": .array(perChannel.map { channel in
                .object([
                    "channel": .int(channel.channel),
                    "samplePeak": .double(channel.samplePeak),
                    "samplePeakDbFS": .number(channel.samplePeakDbFS),
                    "truePeak": .double(channel.truePeak),
                    "truePeakDbTP": .number(channel.truePeakDbTP),
                    "clippedSamples": .int(channel.clippedSamples),
                    "clippedRuns": .int(channel.clippedRuns),
                    "longestClippedRunSamples": .int(channel.longestClippedRunSamples),
                ])
            }),
        ])
    }
}

extension Gate {
    var json: JSONValue {
        .object([
            "comparison": .string(comparison),
            "threshold": .double(thresholdValue),
            "measured": .number(measured),
            "unit": .string(unit),
            "applicable": .bool(applicable),
            "passed": .bool(applicable && passed),
            "note": .string(note),
        ])
    }
}

extension MetricsReport {
    public var json: JSONValue {
        .object([
            "schemaVersion": .int(AudioMetricsAnalyzer.reportSchemaVersion),
            "tool": .string("audio-metrics"),
            "fixture": .object([
                "caseID": .string(caseID),
                "directory": .string(fixtureDirectory),
            ]),
            "processed": .object([
                "file": .string(processedFile),
                "isFixtureMicrophone": .bool(processedIsFixtureMicrophone),
                "sampleRate": .int(analysisSampleRate),
            ]),
            "analysis": .object([
                "sampleRate": .int(analysisSampleRate),
                "blockSamples": .int(blockSamples),
                "blockMilliseconds": .double(options.blockMilliseconds),
                "analyzedBlocks": .int(analyzedBlocks),
                "convergenceWindowSeconds": .double(options.convergenceWindowSeconds),
                "processingDelayMilliseconds": .double(options.processingDelayMilliseconds),
                "alignmentWindowSeconds": .double(options.alignmentWindowSeconds),
                "maximumLagMilliseconds": .double(options.maximumLagMilliseconds),
                "activityFloorDb": .double(options.activityFloorDb),
                "activityRelativeDb": .double(options.activityRelativeDb),
            ]),
            "farEnd": .object([
                "presenceCorrelation": .number(farEnd.presenceCorrelation),
                "reachesMicrophone": .bool(farEnd.reachesMicrophone),
            ]),
            "regionSeconds": .object(Dictionary(uniqueKeysWithValues: regionSeconds.map { ($0.key.rawValue, JSONValue.double($0.value)) })),
            "echoReduction": .object([
                "byRegion": .object(Dictionary(uniqueKeysWithValues: reductionByRegion
                    .filter { $0.key == .farEndOnly || $0.key == .doubleTalk }
                    .map { ($0.key.rawValue, $0.value.json) })),
                "farEndActive": reductionFarEndActive.json,
            ]),
            "nearEnd": nearEnd?.json ?? .null,
            "alignment": .object(Dictionary(uniqueKeysWithValues: alignment.map { ($0.label, $0.json) })),
            "duration": duration.json,
            "peaks": peaks.json,
            "gates": .object(Dictionary(uniqueKeysWithValues: gates.map { ($0.name, $0.json) })),
            "allApplicableGatesPassed": .bool(allApplicableGatesPassed),
            "failedGates": .array(failedGates.map { .string($0.name) }),
        ])
    }

    public func encodedJSON() throws -> Data { try json.encodedData() }

    /// One-line-per-metric summary for terminal use.
    public var textSummary: String {
        var lines = ["case: \(caseID)  processed: \((processedFile as NSString).lastPathComponent)  rate: \(analysisSampleRate) Hz"]
        let farEndOnly = reductionByRegion[.farEndOnly]
        lines.append("far-end-only blocks: \(farEndOnly?.blocks ?? 0)  median reduction: \(format(farEndOnly?.medianDb)) dB")
        let doubleTalk = reductionByRegion[.doubleTalk]
        lines.append("double-talk blocks: \(doubleTalk?.blocks ?? 0)  median reduction: \(format(doubleTalk?.medianDb)) dB")
        lines.append("far-end-active median reduction: \(format(reductionFarEndActive.medianDb)) dB over \(reductionFarEndActive.blocks) blocks")
        lines.append("near-end level change: \(format(nearEnd?.levelChangeDb)) dB over \(nearEnd?.blocks ?? 0) blocks")
        for window in alignment {
            lines.append("alignment \(window.label): residual \(format(window.timeline?.residualErrorMilliseconds)) ms, echo path measured \(window.echoPath.map { String($0.measuredDelaySamples) } ?? "n/a") vs expected \(window.echoPath.map { String($0.expectedDelaySamples) } ?? "n/a") samples")
        }
        lines.append("duration: \(format(duration.processedSeconds)) s (expected \(format(duration.expectedSeconds)) s, delta \(format(duration.deltaMillisecondsVersusExpected)) ms)")
        lines.append("peaks: sample \(format(peaks.samplePeakDbFS)) dBFS, true \(format(peaks.truePeakDbTP)) dBTP, clipped \(peaks.clippedSamples) samples")
        for gate in gates.sorted(by: { $0.name < $1.name }) {
            let status = !gate.applicable ? "n/a " : (gate.passed ? "PASS" : "FAIL")
            lines.append("  [\(status)] \(gate.name) \(gate.comparison) \(format(gate.thresholdValue)) \(gate.unit) — measured \(format(gate.measured))")
        }
        return lines.joined(separator: "\n")
    }

    private func format(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "n/a" }
        return String(format: "%.3f", value)
    }
}
