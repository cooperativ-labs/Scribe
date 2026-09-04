import AVFoundation
import Foundation
import Testing
@testable import CaptureHarness

private func temporaryDirectory() throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func makeFloatBuffer(sampleRate: Double, channels: AVAudioChannelCount, frames: Int, fill: (Int) -> Float) throws -> AVAudioPCMBuffer {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
    buffer.frameLength = AVAudioFrameCount(frames)
    let data = try #require(buffer.floatChannelData)
    for channel in 0..<Int(channels) {
        for frame in 0..<frames { data[channel][frame] = fill(frame) }
    }
    return buffer
}

// MARK: - Level

@Test func levelSeparatesDigitalSilenceFromQuietAudio() throws {
    let silent = try makeFloatBuffer(sampleRate: 48_000, channels: 2, frames: 480) { _ in 0 }
    let silence = AudioLevel.measure(silent)
    #expect(silence.isDigitalSilence)
    #expect(silence.sampleCount == 960)
    #expect(silence.described.contains("digital silence"))

    // -60 dBFS is quiet enough to sound like nothing but is not a silent filter result.
    let quiet = try makeFloatBuffer(sampleRate: 48_000, channels: 2, frames: 480) { _ in 0.001 }
    let level = AudioLevel.measure(quiet)
    #expect(!level.isDigitalSilence)
    #expect(abs(level.peakDBFS - (-60)) < 0.1)
    #expect(abs(level.rmsDBFS - (-60)) < 0.1)
}

@Test func levelAccumulatesPeakAndEnergyAcrossBuffers() throws {
    var total = AudioLevel()
    total.accumulate(AudioLevel.measure(try makeFloatBuffer(sampleRate: 48_000, channels: 1, frames: 100) { _ in 0.25 }))
    total.accumulate(AudioLevel.measure(try makeFloatBuffer(sampleRate: 48_000, channels: 1, frames: 100) { _ in 0.75 }))
    #expect(abs(total.peak - 0.75) < 1e-6)
    #expect(total.sampleCount == 200)
    // RMS over both halves: sqrt((0.25^2 + 0.75^2) / 2).
    #expect(abs(total.rms - ((0.0625 + 0.5625) / 2).squareRoot()) < 1e-6)
}

// MARK: - Application families

@Test func applicationFamiliesClaimTheirHelperIdentifiers() throws {
    #expect(ApplicationFamily.chrome.claims(bundleIdentifier: "com.google.Chrome.helper.renderer"))
    #expect(ApplicationFamily.chrome.isMain("com.google.Chrome"))
    #expect(!ApplicationFamily.chrome.isMain("com.google.Chrome.helper"))
    // WebKit renders Safari media outside the Safari bundle identifier entirely, but the
    // same identifier is used by every other WebKit host, so the name decides ownership.
    #expect(ApplicationFamily.safari.claims(bundleIdentifier: "com.apple.WebKit.GPU"))
    #expect(!ApplicationFamily.safari.isMain("com.apple.WebKit.GPU"))
    #expect(ApplicationFamily.safari.isSharedHelper(bundleIdentifier: "com.apple.WebKit.GPU"))
    #expect(ApplicationFamily.safari.claims(bundleIdentifier: "com.apple.WebKit.GPU", applicationName: "Safari Graphics and Media"))
    #expect(!ApplicationFamily.safari.claims(bundleIdentifier: "com.apple.WebKit.GPU", applicationName: "Mail Graphics and Media"))
    // A family with no shared helpers accepts any name for its own identifiers.
    #expect(ApplicationFamily.chrome.claims(bundleIdentifier: "com.google.Chrome.helper", applicationName: "Google Chrome Helper (Renderer)"))
    #expect(ApplicationFamily.teams.isMain("com.microsoft.teams2"))
    #expect(ApplicationFamily.named("ZOOM")?.key == "zoom")
    #expect(ApplicationFamily.named("edge") == nil)
}

@Test func filterVariantsCompareMainOnlyAgainstMainPlusHelpers() throws {
    let both = ProbeFilterCommand.filterVariants(
        family: .chrome,
        main: ["com.google.Chrome"],
        helpers: ["com.google.Chrome.helper"]
    )
    #expect(both.map(\.label) == ["main-only", "main-plus-helpers"])
    #expect(both[1].identifiers == ["com.google.Chrome", "com.google.Chrome.helper"])

    // A native app with no helpers needs only the one variant.
    #expect(ProbeFilterCommand.filterVariants(family: .zoom, main: ["us.zoom.xos"], helpers: []).map(\.label) == ["main-only"])

    // If only helpers are filterable, that alone is the finding worth recording.
    let helpersOnly = ProbeFilterCommand.filterVariants(family: .safari, main: [], helpers: ["com.apple.WebKit.GPU"])
    #expect(helpersOnly.map(\.label) == ["main-plus-helpers", "helpers-only"])
}

@Test func probeOutcomeSeparatesNoBuffersFromSilentBuffers() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let journal = try JournalWriter(directory: directory)
    let writer = TrackWriter(track: .audio, directory: directory, journal: journal, segmentSeconds: 0)

    let asbd = AudioStreamBasicDescription(
        mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
        mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0
    )
    let pcm = try makeFloatBuffer(sampleRate: 48_000, channels: 2, frames: 480) { _ in 0 }
    writer.write(CapturedBuffer(
        track: .audio, pcm: pcm, format: asbd, channelLayoutTag: nil,
        ptsValue: 0, ptsTimescale: 48_000, frameCount: 480, sequence: 1,
        callbackThread: "queue=test tid=1 main=false qos=33", callbackHostSeconds: 0
    ))
    writer.finish()
    journal.synchronizeAndClose()
    #expect(writer.level.isDigitalSilence)
    _ = asbd
}

// MARK: - Interruption correlation

private func marker(_ name: String, at hostSeconds: Double) -> InterruptionMarker {
    InterruptionMarker(name: name, detail: "test", hostSeconds: hostSeconds, wallClock: "2026-09-03T12:00:00.000-07:00")
}

private func buffer(_ track: String, host: Double, pts: Double, rate: Double = 48_000, format: String = "lpcm 48000 Hz 2 ch 32 bit flags 41") -> CorrelationBuffer {
    CorrelationBuffer(track: track, hostSeconds: host, ptsSeconds: pts, frameCount: 480, sampleRate: rate, format: format, peak: 0.1)
}

@Test func correlationReportsContinuationGapAndStop() throws {
    let buffers = [
        buffer("audio", host: 1.00, pts: 1.00),
        buffer("audio", host: 1.01, pts: 1.01),
        // The second buffer ends at pts 1.02, so the third leaves 0.5 s of missing audio.
        buffer("audio", host: 2.50, pts: 1.52),
        buffer("microphone", host: 1.00, pts: 1.00),
        buffer("microphone", host: 1.01, pts: 1.01),
    ]
    let outcomes = InterruptionAnalysis.correlate(
        markers: [marker("output-route-changed", at: 2.0)],
        buffers: buffers
    )
    let outcome = try #require(outcomes.first)
    let audio = try #require(outcome.tracks.first { $0.track == "audio" })
    #expect(audio.buffersAfter == 1)
    #expect(abs((audio.ptsGapSeconds ?? 0) - 0.5) < 1e-6)
    #expect(audio.behaviour.contains("continued after a 0.500 s"))

    let microphone = try #require(outcome.tracks.first { $0.track == "microphone" })
    #expect(microphone.buffersAfter == 0)
    #expect(microphone.behaviour.contains("stopped"))
}

@Test func correlationReportsFormatChangeAcrossAMarker() throws {
    let buffers = [
        buffer("microphone", host: 1.0, pts: 1.0, rate: 48_000, format: "lpcm 48000 Hz 1 ch 32 bit flags 41"),
        buffer("microphone", host: 3.0, pts: 1.01, rate: 16_000, format: "lpcm 16000 Hz 1 ch 32 bit flags 41"),
    ]
    let outcome = try #require(InterruptionAnalysis.correlate(markers: [marker("input-route-changed", at: 2.0)], buffers: buffers).first)
    let track = try #require(outcome.tracks.first)
    #expect(track.formatChanged)
    #expect(track.sampleRateBefore == 48_000)
    #expect(track.sampleRateAfter == 16_000)
    #expect(track.behaviour.contains("format changed"))
}

@Test func jitterBelowOneProcessingBlockIsNotReportedAsAGap() throws {
    // 480 frames at 48 kHz is exactly 10 ms, so a contiguous pair has a zero gap.
    let buffers = [buffer("audio", host: 1.0, pts: 1.0), buffer("audio", host: 1.02, pts: 1.01)]
    let outcome = try #require(InterruptionAnalysis.correlate(markers: [marker("screen-locked", at: 1.01)], buffers: buffers).first)
    #expect(try #require(outcome.tracks.first).behaviour == "continued with no timestamp discontinuity")
}

@Test func markersAndBuffersRoundTripThroughTheJournal() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let journal = try JournalWriter(directory: directory)
    let writer = TrackWriter(track: .audio, directory: directory, journal: journal, segmentSeconds: 0)

    let asbd = AudioStreamBasicDescription(
        mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
        mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0
    )
    for index in 0..<3 {
        let pcm = try makeFloatBuffer(sampleRate: 48_000, channels: 2, frames: 480) { _ in 0.5 }
        writer.write(CapturedBuffer(
            track: .audio, pcm: pcm, format: asbd, channelLayoutTag: nil,
            ptsValue: Int64(index * 480), ptsTimescale: 48_000, frameCount: 480, sequence: index,
            callbackThread: "queue=test tid=1 main=false qos=33", callbackHostSeconds: Double(index) * 0.01
        ))
    }
    journal.appendEvent(marker("screen-locked", at: 0.015).journalObject)
    writer.finish()
    journal.synchronizeAndClose()
    _ = asbd

    let parsed = try InterruptionAnalysis.buffers(inTimeline: journal.timelineURL)
    #expect(parsed.count == 3)
    #expect(parsed.allSatisfy { $0.peak > 0 })

    let markers = try InterruptionAnalysis.markers(inEvents: journal.eventsURL)
    #expect(markers.count == 1)
    #expect(markers.first?.name == "screen-locked")

    // The buffer journal must stay free of lines the inspector would count as ignored,
    // so interruption markers belong in events.jsonl only.
    let inspection = try TimestampInspector.inspect(journalURL: journal.timelineURL)
    #expect(inspection.ignoredLines == 0)
    #expect(inspection.parsedBuffers == 3)
}

// MARK: - Fixtures

@Test func fixtureScenariosCoverThePlansRealRoomCases() throws {
    #expect(FixtureScenario.all.map(\.key) == ["far-end-only", "near-end-only", "double-talk"])
    #expect(FixtureScenario.named("DOUBLE-TALK")?.title == "Double-talk")
    #expect(FixtureScenario.named("silence") == nil)
    for scenario in FixtureScenario.all {
        #expect(!scenario.expectation.isEmpty)
        #expect(!scenario.script.isEmpty)
    }
}

@Test func fixtureExportConcatenatesSegmentsIntoOneCommittedFile() throws {
    let capture = try temporaryDirectory()
    let fixture = try temporaryDirectory()
    defer {
        try? FileManager.default.removeItem(at: capture)
        try? FileManager.default.removeItem(at: fixture)
    }

    let journal = try JournalWriter(directory: capture)
    let system = TrackWriter(track: .audio, directory: capture, journal: journal, segmentSeconds: 0)
    let microphone = TrackWriter(track: .microphone, directory: capture, journal: journal, segmentSeconds: 0)
    let stereo = AudioStreamBasicDescription(
        mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
        mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0
    )
    var mono = stereo
    mono.mChannelsPerFrame = 1
    mono.mSampleRate = 44_100


    for index in 0..<4 {
        let pcm = try makeFloatBuffer(sampleRate: 48_000, channels: 2, frames: 480) { frame in
            sin(Float(index * 480 + frame) * 0.05) * 0.5
        }
        system.write(CapturedBuffer(track: .audio, pcm: pcm, format: stereo, channelLayoutTag: nil,
                                    ptsValue: Int64(index * 480), ptsTimescale: 48_000, frameCount: 480,
                                    sequence: index, callbackThread: "t", callbackHostSeconds: Double(index) * 0.01))
    }
    for index in 0..<2 {
        let pcm = try makeFloatBuffer(sampleRate: 44_100, channels: 1, frames: 441) { _ in 0.25 }
        microphone.write(CapturedBuffer(track: .microphone, pcm: pcm, format: mono, channelLayoutTag: nil,
                                        ptsValue: Int64(index * 480), ptsTimescale: 48_000, frameCount: 441,
                                        sequence: index, callbackThread: "t", callbackHostSeconds: Double(index) * 0.01))
    }
    system.finish()
    microphone.finish()
    journal.synchronizeAndClose()

    let report = CaptureReport(
        reason: .durationElapsed, elapsedSeconds: 0.04, screenConsumer: .none,
        screenFramesDiscarded: 0, droppedUnparsedBuffers: 0, streamErrorMessage: nil,
        filterDescription: "test", microphoneDescription: "test", callbackThreads: [],
        system: TrackSummary(writer: system), microphone: TrackSummary(writer: microphone),
        selfCPU: ResourceSummary(process: "test", pid: 0, cpuSeconds: 0, averagePercentOfOneCore: 0,
                                 peakPercentOfOneCore: 0, peakPhysFootprintBytes: 0),
        daemonCPU: nil
    )
    let exports = try FixtureCommand.export(report: report, from: capture, to: fixture, format: .wav)
    #expect(exports.count == 2)

    let systemExport = try #require(exports.first(where: { $0.track == "system" }))
    #expect(systemExport.name == "system.wav")
    #expect(systemExport.frames == 1_920)
    #expect(systemExport.channels == 2)
    #expect(systemExport.byteSize > 0)

    // The microphone keeps its own native rate; the fixture must not silently resample it.
    let microphoneExport = try #require(exports.first(where: { $0.track == "microphone" }))
    #expect(microphoneExport.sampleRate == 44_100)
    #expect(microphoneExport.channels == 1)

    let written = try AVAudioFile(forReading: fixture.appendingPathComponent("system.wav"))
    #expect(written.fileFormat.sampleRate == 48_000)
    #expect(written.fileFormat.channelCount == 2)
    #expect(written.length == 1_920)
    _ = (stereo, mono)
}
