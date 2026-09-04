import AVFoundation
import Foundation
import Testing
@testable import CaptureHarness

private func makeBuffer(
    track: TrackKind,
    sampleRate: Double,
    channels: UInt32,
    frames: Int,
    ptsValue: Int64,
    ptsTimescale: Int32,
    sequence: Int
) throws -> CapturedBuffer {
    var asbd = AudioStreamBasicDescription(
        mSampleRate: sampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
        mBytesPerPacket: 4,
        mFramesPerPacket: 1,
        mBytesPerFrame: 4,
        mChannelsPerFrame: channels,
        mBitsPerChannel: 32,
        mReserved: 0
    )
    let format = try #require(AVAudioFormat(streamDescription: &asbd))
    let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
    pcm.frameLength = AVAudioFrameCount(frames)
    return CapturedBuffer(
        track: track,
        pcm: pcm,
        format: asbd,
        channelLayoutTag: nil,
        ptsValue: ptsValue,
        ptsTimescale: ptsTimescale,
        frameCount: frames,
        sequence: sequence,
        callbackThread: "queue=test tid=1 main=false qos=33",
        callbackHostSeconds: 0
    )
}

@Test func recorderJournalIsReadableByTheInspector() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let journal = try JournalWriter(directory: directory)
    let system = TrackWriter(track: .audio, directory: directory, journal: journal, segmentSeconds: 0)
    let microphone = TrackWriter(track: .microphone, directory: directory, journal: journal, segmentSeconds: 0)

    // Two contiguous 10 ms system blocks, then a 10 ms gap before the third.
    for index in 0..<2 {
        try system.write(makeBuffer(track: .audio, sampleRate: 48_000, channels: 2, frames: 480,
                                    ptsValue: Int64(index * 480), ptsTimescale: 48_000, sequence: index))
    }
    try system.write(makeBuffer(track: .audio, sampleRate: 48_000, channels: 2, frames: 480,
                                ptsValue: 1_440, ptsTimescale: 48_000, sequence: 2))
    // The microphone runs at its own native rate, as ScreenCaptureKit delivers it.
    try microphone.write(makeBuffer(track: .microphone, sampleRate: 44_100, channels: 1, frames: 441,
                                    ptsValue: 0, ptsTimescale: 48_000, sequence: 3))
    system.finish()
    microphone.finish()
    journal.synchronizeAndClose()

    let report = try TimestampInspector.inspect(journalURL: journal.timelineURL)
    #expect(report.ignoredLines == 0)
    #expect(report.parsedBuffers == 4)
    #expect(report.clockRelationship.contains("common timeline"))

    let audio = try #require(report.tracks["audio"])
    #expect(audio.bufferCount == 3)
    #expect(audio.deliveredFrames == 1_440)
    #expect(audio.gaps.count == 1)
    #expect(abs((audio.gaps.first?.seconds ?? 0) - 0.01) < 1e-9)

    let mic = try #require(report.tracks["microphone"])
    #expect(mic.formats.first?.contains("44100") == true)

    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("system-0001.caf").path))
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("microphone-0001.caf").path))
}

@Test func formatChangeRotatesToANewSegment() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let journal = try JournalWriter(directory: directory)
    let writer = TrackWriter(track: .microphone, directory: directory, journal: journal, segmentSeconds: 0)
    try writer.write(makeBuffer(track: .microphone, sampleRate: 48_000, channels: 1, frames: 480,
                                ptsValue: 0, ptsTimescale: 48_000, sequence: 0))
    try writer.write(makeBuffer(track: .microphone, sampleRate: 16_000, channels: 1, frames: 160,
                                ptsValue: 480, ptsTimescale: 48_000, sequence: 1))
    writer.finish()
    journal.synchronizeAndClose()

    #expect(writer.segments == ["microphone-0001.caf", "microphone-0002.caf"])
    let report = try TimestampInspector.inspect(journalURL: journal.timelineURL)
    let mic = try #require(report.tracks["microphone"])
    #expect(mic.formatChanges.count == 1)

    let events = try String(contentsOf: journal.eventsURL, encoding: .utf8)
    #expect(events.contains("format-change"))
}

@Test func argumentParsingRejectsAmbiguousAndMissingSources() throws {
    // A value-less "--bundle-id" parses as a flag, so no source is selected and
    // makeOptions reports the missing-source error rather than guessing one.
    #expect(try Arguments(["--bundle-id"]).string("bundle-id") == nil)
    #expect(try Arguments(["--bundle-id"]).flag("bundle-id"))
    let parsed = try Arguments(["--bundle-id", "us.zoom.xos", "--duration", "600", "--no-screen-fallback"])
    #expect(parsed.string("bundle-id") == "us.zoom.xos")
    #expect(try parsed.double("duration", default: 300) == 600)
    #expect(parsed.flag("no-screen-fallback"))
    #expect(try parsed.int("channels", default: 2) == 2)
    #expect(throws: ArgumentError.self) { _ = try Arguments(["positional"]) }
    #expect(throws: ArgumentError.self) { _ = try Arguments(["--duration", "soon"]).double("duration", default: 0) }
}

@Test func formatDescriptionRecordsEveryStreamField() throws {
    let buffer = try makeBuffer(track: .audio, sampleRate: 48_000, channels: 2, frames: 480,
                                ptsValue: 0, ptsTimescale: 48_000, sequence: 0)
    let object = buffer.format.journalObject(channelLayoutTag: kAudioChannelLayoutTag_Stereo)
    #expect(object["mSampleRate"] as? Double == 48_000)
    #expect(object["mFormatIDString"] as? String == "lpcm")
    #expect(object["mChannelsPerFrame"] as? UInt32 == 2)
    #expect(object["mBitsPerChannel"] as? UInt32 == 32)
    #expect((object["mFormatFlagNames"] as? [String])?.contains("NonInterleaved") == true)
    #expect(object["channelLayoutTag"] as? AudioChannelLayoutTag == kAudioChannelLayoutTag_Stereo)
}

@Test func audioOnlyVerdictDistinguishesConfigurationFromFailure() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let journal = try JournalWriter(directory: directory)
    defer { journal.synchronizeAndClose() }

    let empty = TrackWriter(track: .audio, directory: directory, journal: journal, segmentSeconds: 0)
    let delivered = TrackWriter(track: .audio, directory: directory, journal: journal, segmentSeconds: 0)
    try delivered.write(makeBuffer(track: .audio, sampleRate: 48_000, channels: 2, frames: 480,
                                   ptsValue: 0, ptsTimescale: 48_000, sequence: 0))
    delivered.finish()

    func report(system: TrackWriter, consumer: ScreenConsumer) -> CaptureReport {
        CaptureReport(
            reason: .durationElapsed, elapsedSeconds: 300, screenConsumer: consumer,
            screenFramesDiscarded: 0, droppedUnparsedBuffers: 0, streamErrorMessage: nil,
            filterDescription: "", microphoneDescription: "", callbackThreads: [],
            system: TrackSummary(writer: system), microphone: TrackSummary(writer: empty),
            selfCPU: ResourceSummary(process: "capture-harness", pid: 1, cpuSeconds: 1,
                                     averagePercentOfOneCore: 0.3, peakPercentOfOneCore: 0.9,
                                     peakPhysFootprintBytes: 1_048_576),
            daemonCPU: nil
        )
    }

    #expect(report(system: delivered, consumer: .none).audioOnlyVerdict.hasPrefix("yes"))
    #expect(report(system: empty, consumer: .none).audioOnlyVerdict.hasPrefix("no audio arrived"))
    #expect(report(system: delivered, consumer: .minimal).audioOnlyVerdict.hasPrefix("not proven"))
}
