import Foundation
import Testing
@testable import AudioMetricsCore

/// The checked-in fixture suite from `Tests/Fixtures`, four directory levels above this file.
private let generatedFixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Tests/Fixtures/Generated", isDirectory: true)

private func baseline(_ caseID: String, options: MetricsOptions = MetricsOptions()) throws -> MetricsReport {
    try AudioMetricsAnalyzer.analyze(
        fixtureDirectory: generatedFixtures.appendingPathComponent(caseID, isDirectory: true),
        options: options
    )
}

@Test func generatedFixtureSuiteIsPresent() {
    #expect(FileManager.default.fileExists(atPath: generatedFixtures.path))
}

/// Exit criterion: the raw far-end-only fixture returns zero reduction and the known alignment.
@Test func rawFarEndOnlyFixtureReturnsZeroReductionAndTheKnownDelay() throws {
    let report = try baseline("far-end-only")
    #expect(report.processedIsFixtureMicrophone)
    #expect(report.analysisSampleRate == 48_000)
    #expect(report.farEnd.reachesMicrophone)

    let farEndOnly = try #require(report.reductionByRegion[.farEndOnly])
    #expect(farEndOnly.blocks > 500)
    #expect(abs(try #require(farEndOnly.medianDb)) < 1e-9)
    #expect(report.nearEnd == nil)

    for window in report.alignment {
        let timeline = try #require(window.timeline)
        #expect(timeline.residualErrorSamples == 0)
        let path = try #require(window.echoPath)
        #expect(path.expectedDelaySamples == 1_440)
        #expect(path.reliable)
        // The reverberant tail pulls the correlation peak a couple of samples early; the plan
        // allows up to one 10 ms block.
        #expect(abs(path.errorMilliseconds) < 10)
        #expect(abs(path.errorSamples) <= 8)
    }

    #expect(report.duration.matchesExpected)
    #expect(try !#require(report.gates.first { $0.name == "echoEnergyReductionDb" }).passed)
    #expect(report.failedGates.map(\.name) == ["echoEnergyReductionDb"])
}

/// Exit criterion: the unprocessed double-talk fixture returns zero reduction.
@Test func unprocessedDoubleTalkFixtureReturnsZeroReduction() throws {
    let report = try baseline("double-talk")
    #expect(report.farEnd.reachesMicrophone)
    #expect(abs(try #require(report.reductionFarEndActive.medianDb)) < 1e-9)
    #expect(abs(try #require(report.reductionByRegion[.doubleTalk]?.medianDb)) < 1e-9)
    // No part of this fixture is far-end-only, so the plan's echo gate does not apply to it.
    #expect(report.reductionByRegion[.farEndOnly]?.blocks == 0)
    #expect(try !#require(report.gates.first { $0.name == "echoEnergyReductionDb" }).applicable)

    for window in report.alignment {
        #expect(try #require(window.timeline).residualErrorSamples == 0)
    }
    #expect(report.duration.matchesExpected)
    #expect(report.allApplicableGatesPassed)
}

@Test func rawNearEndOnlyFixtureShowsNoLevelChangeAndNoEcho() throws {
    let report = try baseline("near-end-only")
    #expect(!report.farEnd.reachesMicrophone)
    #expect(report.reductionByRegion[.farEndOnly]?.blocks == 0)
    #expect(report.reductionByRegion[.doubleTalk]?.blocks == 0)
    let nearEnd = try #require(report.nearEnd)
    #expect(nearEnd.blocks > 400)
    #expect(abs(try #require(nearEnd.levelChangeDb)) < 1e-9)
    #expect(report.allApplicableGatesPassed)
}

@Test func silenceFixtureProducesNoMeasurementsButStillMatchesDuration() throws {
    let report = try baseline("silence")
    #expect(!report.farEnd.reachesMicrophone)
    #expect(report.reductionFarEndActive.blocks == 0)
    #expect(report.nearEnd == nil)
    #expect(report.peaks.clippedSamples == 0)
    #expect(report.peaks.truePeakDbTP == nil)
    #expect(report.duration.matchesExpected)
    #expect(report.allApplicableGatesPassed)
}

@Test func clippingFixtureIsCaughtByThePeakGates() throws {
    let report = try baseline("clipping")
    #expect(report.peaks.clippedSamples > 1_000)
    #expect(try #require(report.peaks.truePeakDbTP) > -1)
    let failed = report.failedGates.map(\.name)
    #expect(failed.contains("clippedSamples"))
    #expect(failed.contains("truePeakDbTP"))
}

@Test func delayChangeFixtureReportsBothSegmentDelays() throws {
    let report = try baseline("delay-change-mid-file")
    let start = try #require(report.alignment.first { $0.label == "start" }?.echoPath)
    let end = try #require(report.alignment.first { $0.label == "end" }?.echoPath)
    #expect(start.expectedDelaySamples == 1_440)
    #expect(end.expectedDelaySamples == 2_880)
    #expect(abs(start.errorMilliseconds) < 10)
    #expect(abs(end.errorMilliseconds) < 10)
    #expect(start.reliable)
    #expect(end.reliable)
}

@Test func nonCanonicalMicrophoneRatesAreAnalyzedAtTheirOwnRate() throws {
    let sixteen = try baseline("microphone-16k")
    #expect(sixteen.analysisSampleRate == 16_000)
    #expect(sixteen.blockSamples == 160)
    #expect(abs(try #require(sixteen.reductionFarEndActive.medianDb)) < 1e-9)
    #expect(sixteen.duration.matchesExpected)

    let fortyFour = try baseline("microphone-44k1")
    #expect(fortyFour.analysisSampleRate == 44_100)
    #expect(fortyFour.blockSamples == 441)
    #expect(abs(try #require(fortyFour.reductionFarEndActive.medianDb)) < 1e-9)
    #expect(fortyFour.duration.matchesExpected)
}

@Test func asymmetricStereoFixtureIsMeasuredOnEveryChannel() throws {
    let report = try baseline("asymmetric-stereo")
    #expect(report.peaks.perChannel.count == 2)
    #expect(report.peaks.perChannel[0].samplePeak != report.peaks.perChannel[1].samplePeak)
    #expect(abs(try #require(report.reductionFarEndActive.medianDb)) < 1e-9)
}

@Test func documentedGapsAreExcludedFromTheGeneratedFixture() throws {
    let report = try baseline("documented-gaps")
    // The sidecar documents a 0.25 s and a 0.10 s gap.
    #expect(abs((report.regionSeconds[.gap] ?? 0) - 0.35) < 0.03)
}

/// A stand-in for a real canceller: 99% of the known echo removed (exactly 40 dB) and a 10 ms
/// processing delay added. Every gate should pass once that delay is stated.
@Test func simulatedCancellationOnTheFarEndFixtureMeetsEveryGate() throws {
    let directory = generatedFixtures.appendingPathComponent("far-end-only", isDirectory: true)
    let sidecar = try FixtureSidecar.read(contentsOf: directory.appendingPathComponent("ground-truth.json"))
    let microphone = try WAVFile.read(contentsOf: directory.appendingPathComponent("microphone.wav"))
    let playback = try WAVFile.read(contentsOf: directory.appendingPathComponent("playback.wav"))
    let echo = try WAVFile.read(contentsOf: directory.appendingPathComponent("echo.wav"))

    let delaySamples = microphone.sampleRate / 100
    let microphoneSamples = microphone.mono
    let echoSamples = echo.mono
    var processed = Array(repeating: 0.0, count: microphoneSamples.count)
    for index in delaySamples..<processed.count {
        processed[index] = microphoneSamples[index - delaySamples] - 0.99 * echoSamples[index - delaySamples]
    }

    var options = MetricsOptions()
    options.processingDelayMilliseconds = 10
    let report = try AudioMetricsAnalyzer.analyze(
        sidecar: sidecar,
        inputs: AudioMetricsAnalyzer.FixtureInputs(microphone: microphone, playback: playback, echo: echo),
        processed: WAVFile(sampleRate: microphone.sampleRate, channels: [processed]),
        options: options
    )

    let median = try #require(report.reductionByRegion[.farEndOnly]?.medianDb)
    #expect(abs(median - 40) < 0.05)
    for window in report.alignment {
        #expect(try #require(window.timeline).residualErrorSamples == 0)
    }
    #expect(report.allApplicableGatesPassed)
    #expect(report.failedGates.isEmpty)
}
