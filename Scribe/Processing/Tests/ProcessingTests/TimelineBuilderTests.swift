import Foundation
import Testing
import ScribeAppCore
@testable import Processing

private let origin = 207_492.667875

/// Writes a track as fixed-size buffers, optionally skipping an interval so the
/// timestamp jumps across it and the journal records a gap.
private func writeTrack(
    _ archive: CaptureArchiveFixture,
    track: String,
    startingAt start: Double,
    frames total: Int,
    format: CaptureArchiveFixture.Format,
    bufferFrames: Int = 512,
    skipping gaps: [(Double, Double)] = [],
    driftRatio: Double = 1
) throws {
    var frame = 0
    while frame < total {
        let seconds = Double(frame) / Double(format.sampleRate)
        if let gap = gaps.first(where: { $0.0 <= seconds && seconds < $0.1 }) {
            frame = min(total, Int((gap.1 * Double(format.sampleRate)).rounded()))
            continue
        }
        let count = min(bufferFrames, total - frame)
        let samples = testSignal(frames: count * format.channelCount, startingAt: frame * format.channelCount)
        try archive.write(track: track, at: start + seconds * driftRatio, samples: samples, format: format)
        frame += count
    }
}

@Test func establishesOneOriginAndPreservesEachTracksOwnInitialOffset() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try CaptureArchiveFixture(root: root)
    // The measured spread of microphone start offsets is 0.123 s to 2.594 s. Nothing
    // may align the two tracks by their first sample or subtract a constant.
    let offset = 2.593544
    try writeTrack(archive, track: "system", startingAt: origin, frames: 48_000,
                   format: .init(sampleRate: 48_000, channelCount: 2), bufferFrames: 960)
    try writeTrack(archive, track: "microphone", startingAt: origin + offset, frames: 48_000,
                   format: .init(sampleRate: 48_000))
    try archive.finish()

    let builder = try TimelineBuilder.plan(sessionDirectory: archive.sessionDirectory)
    #expect(builder.timeline.origin == RationalTime(seconds: origin))
    let system = try #require(builder.timeline.track(.system))
    let microphone = try #require(builder.timeline.track(.microphone))
    #expect(system.leadingSilenceFrames == 0)
    #expect(microphone.leadingSilenceFrames == Int64((offset * 48_000).rounded()))
    #expect(microphone.outputFrameCount == microphone.leadingSilenceFrames + 48_000)

    // The lead really is silence in the samples, and the first captured sample sits
    // exactly at the boundary rather than one frame either side of it.
    let reader = try #require(try builder.makeReader(for: .microphone))
    let audio = try reader.readAll()[0]
    #expect(audio.prefix(Int(microphone.leadingSilenceFrames)).allSatisfy { $0 == 0 })
    #expect(audio[Int(microphone.leadingSilenceFrames)] == testSignal(frames: 1)[0])
}

@Test func insertsSilenceOnlyForJournaledGapsAndNeverConcatenatesAcrossOne() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try CaptureArchiveFixture(root: root)
    // A 10 ms buffer divides the gap boundaries exactly, so the journaled interval
    // is the one the test asks for rather than one rounded to a buffer edge.
    try writeTrack(archive, track: "microphone", startingAt: origin, frames: 48_000,
                   format: .init(sampleRate: 48_000), bufferFrames: 480, skipping: [(0.25, 0.5)])
    try archive.finish()

    let builder = try TimelineBuilder.plan(sessionDirectory: archive.sessionDirectory)
    let track = try #require(builder.timeline.track(.microphone))
    #expect(track.runs.count == 2)
    #expect(track.gaps.count == 1)
    #expect(track.gaps[0].outputFrameCount == 12_000)
    // The track still spans its full second: shortening it by concatenating the two
    // sides is precisely what the plan forbids.
    #expect(track.outputFrameCount == 48_000)

    let audio = try #require(try builder.makeReader(for: .microphone)).readAll()[0]
    #expect(audio.count == 48_000)
    #expect(audio[12_000..<24_000].allSatisfy { $0 == 0 })
    // Audio after the gap is at its true position, not 12 000 frames early.
    #expect(audio[24_000] == testSignal(frames: 1, startingAt: 24_000)[0])
}

@Test func resolvesAnOverlapWithoutMovingAudioEarlier() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try CaptureArchiveFixture(root: root)
    let format = CaptureArchiveFixture.Format(sampleRate: 48_000)
    try archive.write(track: "microphone", at: origin, samples: testSignal(frames: 480), format: format)
    // The next buffer claims to start 5 ms before the previous one ended.
    try archive.write(track: "microphone", at: origin + 0.005, samples: testSignal(frames: 480, startingAt: 480), format: format)
    try archive.finish()

    let builder = try TimelineBuilder.plan(sessionDirectory: archive.sessionDirectory)
    let track = try #require(builder.timeline.track(.microphone))
    #expect(track.runs.count == 2)
    #expect(track.runs[1].trimmedLeadingFrames == 240)
    // The second run begins exactly where the first ended: nothing moved earlier and
    // nothing already placed was overwritten.
    #expect(track.runs[1].outputStartFrame == 480)
    #expect(track.outputFrameCount == 720)
    #expect(track.diagnostics.contains { $0.code == "overlap-trimmed" })

    let audio = try #require(try builder.makeReader(for: .microphone)).readAll()[0]
    #expect(Array(audio.prefix(480)) == testSignal(frames: 480))
    #expect(audio[480] == testSignal(frames: 480, startingAt: 480)[240])
}

@Test func aRotatedSegmentIsStillOneContiguousRun() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // Rotate every 0.25 s so a one-second track spans four segments.
    let archive = try CaptureArchiveFixture(root: root, segmentSeconds: 0.25)
    try writeTrack(archive, track: "microphone", startingAt: origin, frames: 48_000, format: .init(sampleRate: 48_000))
    try archive.finish()

    let builder = try TimelineBuilder.plan(sessionDirectory: archive.sessionDirectory)
    let track = try #require(builder.timeline.track(.microphone))
    #expect(track.runs.count == 1, "a bounded-interval rotation is contiguous audio, not a discontinuity")
    #expect(track.runs[0].extents.count == 4)
    #expect(track.outputFrameCount == 48_000)

    let audio = try #require(try builder.makeReader(for: .microphone)).readAll()[0]
    #expect(audio == testSignal(frames: 48_000))
}

@Test func aFormatChangeBreaksTheRunAndEachSideConvertsFromItsOwnRate() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try CaptureArchiveFixture(root: root)
    try writeTrack(archive, track: "microphone", startingAt: origin, frames: 24_000, format: .init(sampleRate: 48_000))
    try writeTrack(archive, track: "microphone", startingAt: origin + 0.5, frames: 8_000,
                   format: .init(sampleRate: 16_000, channelCount: 1, bitsPerChannel: 16, isFloat: false))
    try archive.finish()

    let builder = try TimelineBuilder.plan(sessionDirectory: archive.sessionDirectory)
    let track = try #require(builder.timeline.track(.microphone))
    #expect(track.runs.count == 2)
    #expect(track.runs[0].format.sampleRate == 48_000)
    #expect(track.runs[1].format.sampleRate == 16_000)
    // Half a second at 48 kHz plus half a second at 16 kHz is one second of timeline.
    #expect(track.outputFrameCount == 48_000)
    #expect(builder.timeline.diagnostics.contains { $0.code == "format-change" })
}

@Test func correctsMeasuredDriftGraduallyOnTheProcessingCopy() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try CaptureArchiveFixture(root: root)
    // Sixty seconds at 8 kHz keeps the archive small while giving the measurement a
    // span long enough to be trusted. Timestamps advance 200 ppm faster than samples.
    let drift = 1.0002
    try writeTrack(archive, track: "microphone", startingAt: origin, frames: 480_000,
                   format: .init(sampleRate: 8_000, channelCount: 1, bitsPerChannel: 16, isFloat: false),
                   bufferFrames: 320, driftRatio: drift)
    try archive.finish()

    let builder = try TimelineBuilder.plan(sessionDirectory: archive.sessionDirectory)
    let track = try #require(builder.timeline.track(.microphone))
    #expect(track.drift.corrected)
    #expect(abs(track.drift.partsPerMillion - 200) < 0.5)
    // Sixty seconds of samples must be stretched to the 60.012 s the timestamps span.
    let expected = Int64((60 * drift * 48_000).rounded())
    #expect(abs(track.outputFrameCount - expected) <= 48, "off by more than one millisecond")
}

@Test func leavesShortMeasurementsAloneRatherThanExtrapolatingThem() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try CaptureArchiveFixture(root: root)
    try writeTrack(archive, track: "microphone", startingAt: origin, frames: 96_000,
                   format: .init(sampleRate: 48_000), driftRatio: 1.0002)
    try archive.finish()

    let builder = try TimelineBuilder.plan(sessionDirectory: archive.sessionDirectory)
    let track = try #require(builder.timeline.track(.microphone))
    #expect(abs(track.drift.partsPerMillion - 200) < 1)
    #expect(!track.drift.corrected)
    #expect(track.drift.appliedRatio == 1)
    #expect(track.diagnostics.contains { $0.code == "drift-not-corrected" })
}

@Test func aClockThatMatchesItsSamplesIsReportedAsNoDrift() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try CaptureArchiveFixture(root: root)
    try writeTrack(archive, track: "microphone", startingAt: origin, frames: 480_000,
                   format: .init(sampleRate: 8_000, channelCount: 1, bitsPerChannel: 16, isFloat: false), bufferFrames: 320)
    try archive.finish()

    let track = try #require(try TimelineBuilder.plan(sessionDirectory: archive.sessionDirectory).timeline.track(.microphone))
    #expect(abs(track.drift.partsPerMillion) < 0.1)
    #expect(!track.drift.corrected)
}

@Test func aJournaledRouteChangeIsAMarkerAndNeverInventsSilence() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try CaptureArchiveFixture(root: root)
    try writeTrack(archive, track: "system", startingAt: origin, frames: 48_000,
                   format: .init(sampleRate: 48_000, channelCount: 2), bufferFrames: 960)
    archive.journal(["event": "output-route-change", "currentDeviceID": "LG", "currentDeviceName": "LG Display"])
    try archive.finish()

    let builder = try TimelineBuilder.plan(sessionDirectory: archive.sessionDirectory)
    let track = try #require(builder.timeline.track(.system))
    // Measured: a route change can silence the content for about a second while the
    // timestamps stay perfectly continuous. The timeline must not react to it.
    #expect(track.gaps.isEmpty)
    #expect(track.runs.count == 1)
    #expect(builder.timeline.diagnostics.contains { $0.code == "output-route-change" })
}
