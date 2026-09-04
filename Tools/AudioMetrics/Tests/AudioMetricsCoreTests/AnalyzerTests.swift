import Foundation
import Testing
@testable import AudioMetricsCore

/// A fixture assembled in memory from signals whose relationships are known exactly, so every
/// metric has an answer that can be written down in advance.
struct SyntheticFixture {
    let sidecar: FixtureSidecar
    let inputs: AudioMetricsAnalyzer.FixtureInputs
    let microphone: [Double]
    let rate: Int

    static func make(
        caseID: String,
        rate: Int = 48_000,
        seconds: Double = 4,
        delaySamples: Int = 480,
        echoGain: Double = 0.5,
        includeEcho: Bool,
        includeNearEnd: Bool,
        gaps: [FixtureSidecar.Interval] = []
    ) -> SyntheticFixture {
        let frames = Int(seconds * Double(rate))
        let playback = noise(count: frames, seed: 4_242).map { $0 * 0.4 }
        var echo = Array(repeating: 0.0, count: frames)
        for index in delaySamples..<frames { echo[index] = echoGain * playback[index - delaySamples] }
        let local = noise(count: frames, seed: 8_888).map { $0 * 0.3 }

        var microphone = Array(repeating: 0.0, count: frames)
        for index in 0..<frames {
            var value = 0.0
            if includeEcho { value += echo[index] }
            if includeNearEnd { value += local[index] }
            let seconds = Double(index) / Double(rate)
            if gaps.contains(where: { $0.contains(seconds) }) { value = 0 }
            microphone[index] = value
        }

        let track = { (name: String) in FixtureSidecar.Track(file: name, sampleRate: rate, channels: 1, variant: nil) }
        let sidecar = FixtureSidecar(
            caseID: caseID,
            durationSeconds: seconds,
            playback: FixtureSidecar.Track(file: "playback.wav", sampleRate: rate, channels: 1, variant: "speech-like"),
            echo: track("echo.wav"),
            localSpeech: track("local-speech.wav"),
            microphone: track("microphone.wav"),
            trueDelaySamples: delaySamples,
            gapIntervals: gaps,
            nearEndRegions: includeNearEnd ? [FixtureSidecar.Interval(startSeconds: 0, endSeconds: seconds)] : []
        )
        return SyntheticFixture(
            sidecar: sidecar,
            inputs: AudioMetricsAnalyzer.FixtureInputs(
                microphone: WAVFile(sampleRate: rate, channels: [microphone]),
                playback: WAVFile(sampleRate: rate, channels: [playback]),
                echo: WAVFile(sampleRate: rate, channels: [echo])
            ),
            microphone: microphone,
            rate: rate
        )
    }

    func analyze(processed: [Double], options: MetricsOptions = MetricsOptions()) throws -> MetricsReport {
        try AudioMetricsAnalyzer.analyze(
            sidecar: sidecar,
            inputs: inputs,
            processed: WAVFile(sampleRate: rate, channels: [processed]),
            options: options
        )
    }

    func analyze(processedChannels: [[Double]], options: MetricsOptions = MetricsOptions()) throws -> MetricsReport {
        try AudioMetricsAnalyzer.analyze(
            sidecar: sidecar,
            inputs: inputs,
            processed: WAVFile(sampleRate: rate, channels: processedChannels),
            options: options
        )
    }
}

func gate(_ report: MetricsReport, _ name: String) throws -> Gate {
    try #require(report.gates.first { $0.name == name })
}

@Test func unprocessedFarEndOnlyOutputReportsZeroReductionAndKnownAlignment() throws {
    let fixture = SyntheticFixture.make(caseID: "far-end-only", includeEcho: true, includeNearEnd: false)
    let report = try fixture.analyze(processed: fixture.microphone)

    let farEndOnly = try #require(report.reductionByRegion[.farEndOnly])
    #expect(farEndOnly.blocks > 200)
    #expect(abs(try #require(farEndOnly.medianDb)) < 1e-9)
    #expect(report.reductionByRegion[.doubleTalk]?.blocks == 0)
    #expect(report.nearEnd == nil)
    #expect(report.farEnd.reachesMicrophone)

    for window in report.alignment {
        let timeline = try #require(window.timeline)
        #expect(timeline.residualErrorSamples == 0)
        #expect(timeline.correlation > 0.999)
        let path = try #require(window.echoPath)
        #expect(path.reliable)
        #expect(path.measuredDelaySamples == 480)
        #expect(path.errorSamples == 0)
    }

    #expect(try gate(report, "echoEnergyReductionDb").applicable)
    #expect(try !gate(report, "echoEnergyReductionDb").passed)
    #expect(try gate(report, "alignmentErrorMs.start").passed)
    #expect(try gate(report, "alignmentErrorMs.end").passed)
    #expect(try gate(report, "echoPathDelayErrorMs.start").passed)
    #expect(try gate(report, "durationMatchMs").passed)
    #expect(try !gate(report, "nearEndLevelChangeDb").applicable)
}

@Test func exactTwentyDecibelSuppressionMeetsTheEchoGate() throws {
    let fixture = SyntheticFixture.make(caseID: "far-end-only", includeEcho: true, includeNearEnd: false)
    let report = try fixture.analyze(processed: fixture.microphone.map { $0 * 0.1 })

    let median = try #require(report.reductionByRegion[.farEndOnly]?.medianDb)
    #expect(abs(median - 20) < 1e-9)
    #expect(try gate(report, "echoEnergyReductionDb").passed)
    // 19.9 dB is short of the gate; the same measurement then fails.
    var strict = MetricsOptions()
    strict.gates.minimumEchoReductionDb = 20.1
    #expect(try !gate(fixture.analyze(processed: fixture.microphone.map { $0 * 0.1 }, options: strict), "echoEnergyReductionDb").passed)
}

@Test func nearEndLevelChangeIsMeasuredAgainstTheMicrophone() throws {
    let fixture = SyntheticFixture.make(caseID: "near-end-only", includeEcho: false, includeNearEnd: true)

    let unchanged = try fixture.analyze(processed: fixture.microphone)
    let baseline = try #require(unchanged.nearEnd)
    #expect(baseline.blocks > 200)
    #expect(abs(try #require(baseline.levelChangeDb)) < 1e-9)
    #expect(try gate(unchanged, "nearEndLevelChangeDb").passed)
    // The echo track exists but never reaches the microphone, so nothing is double-talk.
    #expect(!unchanged.farEnd.reachesMicrophone)
    #expect(unchanged.reductionByRegion[.farEndOnly]?.blocks == 0)
    #expect(unchanged.reductionByRegion[.doubleTalk]?.blocks == 0)

    let halfDecibel = try fixture.analyze(processed: fixture.microphone.map { $0 * pow(10, -0.5 / 20) })
    #expect(abs(try #require(halfDecibel.nearEnd?.levelChangeDb) - (-0.5)) < 1e-6)
    #expect(try gate(halfDecibel, "nearEndLevelChangeDb").passed)

    let twoDecibels = try fixture.analyze(processed: fixture.microphone.map { $0 * pow(10, -2.0 / 20) })
    #expect(abs(try #require(twoDecibels.nearEnd?.levelChangeDb) - (-2)) < 1e-6)
    #expect(try !gate(twoDecibels, "nearEndLevelChangeDb").passed)
}

@Test func statedProcessingDelayIsCompensatedBeforeComparing() throws {
    let fixture = SyntheticFixture.make(caseID: "far-end-only", includeEcho: true, includeNearEnd: false)
    let delaySamples = 960 // 20 ms at 48 kHz
    var delayed = Array(repeating: 0.0, count: fixture.microphone.count)
    for index in delaySamples..<delayed.count { delayed[index] = fixture.microphone[index - delaySamples] }

    var compensating = MetricsOptions()
    compensating.processingDelayMilliseconds = 20
    let compensated = try fixture.analyze(processed: delayed, options: compensating)
    let median = try #require(compensated.reductionByRegion[.farEndOnly]?.medianDb)
    #expect(abs(median) < 1e-9)
    for window in compensated.alignment {
        let timeline = try #require(window.timeline)
        #expect(timeline.measuredLagSamples == delaySamples)
        #expect(timeline.residualErrorSamples == 0)
    }
    #expect(try gate(compensated, "alignmentErrorMs.start").passed)

    // Without stating the delay the same file is 20 ms out of alignment and fails the gate.
    let uncompensated = try fixture.analyze(processed: delayed)
    let residual = try #require(uncompensated.alignment.first?.timeline)
    #expect(residual.residualErrorSamples == delaySamples)
    #expect(abs(residual.residualErrorMilliseconds - 20) < 1e-9)
    #expect(try !gate(uncompensated, "alignmentErrorMs.start").passed)
}

@Test func documentedGapsAreExcludedFromAnalysis() throws {
    let gaps = [FixtureSidecar.Interval(startSeconds: 1.5, endSeconds: 1.75)]
    let fixture = SyntheticFixture.make(caseID: "documented-gaps", includeEcho: true, includeNearEnd: false, gaps: gaps)
    let report = try fixture.analyze(processed: fixture.microphone)

    #expect(abs((report.regionSeconds[.gap] ?? 0) - 0.25) < 0.02)
    // Blocks in the gap, and the second of reconvergence after it, are not scored.
    let scored = try #require(report.reductionByRegion[.farEndOnly]).blocks
    #expect(scored < 300)
    #expect(scored > 150)
    #expect(abs(try #require(report.reductionByRegion[.farEndOnly]?.medianDb)) < 1e-9)
}

@Test func durationMismatchIsReportedAndGated() throws {
    let fixture = SyntheticFixture.make(caseID: "far-end-only", includeEcho: true, includeNearEnd: false)
    let truncated = Array(fixture.microphone.prefix(fixture.microphone.count - 24_000))
    let report = try fixture.analyze(processed: truncated)

    #expect(abs(report.duration.deltaMillisecondsVersusExpected - (-500)) < 1e-6)
    #expect(abs(report.duration.processedSeconds - 3.5) < 1e-9)
    #expect(!report.duration.matchesExpected)
    #expect(try !gate(report, "durationMatchMs").passed)
}

@Test func clippingAndTruePeakAreMeasuredPerChannel() throws {
    let fixture = SyntheticFixture.make(caseID: "clipping", includeEcho: true, includeNearEnd: true)
    var clipped = fixture.microphone
    for index in 1_000..<1_040 { clipped[index] = index.isMultiple(of: 2) ? 1 : -1 }
    let quiet = fixture.microphone.map { $0 * 0.1 }
    let report = try fixture.analyze(processedChannels: [clipped, quiet])

    #expect(report.peaks.perChannel.count == 2)
    #expect(report.peaks.perChannel[0].clippedSamples == 40)
    #expect(report.peaks.perChannel[0].clippedRuns == 1)
    #expect(report.peaks.perChannel[0].longestClippedRunSamples == 40)
    #expect(report.peaks.perChannel[1].clippedSamples == 0)
    #expect(report.peaks.clippedSamples == 40)
    #expect(try #require(report.peaks.truePeakDbTP) > -1)
    #expect(try !gate(report, "truePeakDbTP").passed)
    #expect(try !gate(report, "clippedSamples").passed)
}

@Test func doubleTalkRegionsAreScoredSeparatelyFromFarEndOnly() throws {
    let fixture = SyntheticFixture.make(caseID: "double-talk", includeEcho: true, includeNearEnd: true)
    let report = try fixture.analyze(processed: fixture.microphone)

    #expect(report.reductionByRegion[.farEndOnly]?.blocks == 0)
    #expect(try #require(report.reductionByRegion[.doubleTalk]).blocks > 200)
    #expect(abs(try #require(report.reductionByRegion[.doubleTalk]?.medianDb)) < 1e-9)
    #expect(abs(try #require(report.reductionFarEndActive.medianDb)) < 1e-9)
    // The plan's echo gate only applies to far-end-only regions, so it is not scored here.
    #expect(try !gate(report, "echoEnergyReductionDb").applicable)
}

@Test func reportJSONCarriesGatesAndExplicitNulls() throws {
    let fixture = SyntheticFixture.make(caseID: "far-end-only", includeEcho: true, includeNearEnd: false)
    let report = try fixture.analyze(processed: fixture.microphone)
    let object = try JSONSerialization.jsonObject(with: report.encodedJSON()) as? [String: Any]
    let root = try #require(object)

    #expect(root["schemaVersion"] as? Int == AudioMetricsAnalyzer.reportSchemaVersion)
    #expect(root["nearEnd"] is NSNull)
    #expect(root["allApplicableGatesPassed"] as? Bool == false)
    #expect((root["failedGates"] as? [String]) == ["echoEnergyReductionDb"])

    let gates = try #require(root["gates"] as? [String: Any])
    let echoGate = try #require(gates["echoEnergyReductionDb"] as? [String: Any])
    #expect(echoGate["applicable"] as? Bool == true)
    #expect(echoGate["passed"] as? Bool == false)
    #expect(abs(try #require(echoGate["measured"] as? Double)) < 1e-9)
    #expect(echoGate["threshold"] as? Double == 20)

    let nearEndGate = try #require(gates["nearEndLevelChangeDb"] as? [String: Any])
    #expect(nearEndGate["applicable"] as? Bool == false)
    #expect(nearEndGate["measured"] is NSNull)

    let reduction = try #require(root["echoReduction"] as? [String: Any])
    let byRegion = try #require(reduction["byRegion"] as? [String: Any])
    #expect(byRegion["far-end-only"] != nil)
    #expect(byRegion["double-talk"] != nil)
}
