import AVFAudio
import FLACBridge
import Foundation
import ScribeAppCore
import Testing
@testable import Processing

private let exportOrigin = 207_492.667875

@Test func unprocessedExportsDecodePreserveStableFormatsAndLeaveTheArchiveUntouched() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try CaptureArchiveFixture(root: root)
    try writeTrack(archive, track: "system", start: exportOrigin, rate: 48_000, seconds: 1.0)
    try writeTrack(archive, track: "microphone", start: exportOrigin + 0.1, rate: 44_100, seconds: 1.0)
    try archive.finish()
    try writeManifest(at: archive.sessionDirectory)

    let before = try directoryDigest(archive.captureDirectory)
    let first = try UnprocessedFLACExporter().export(sessionDirectory: archive.sessionDirectory)
    let after = try directoryDigest(archive.captureDirectory)
    #expect(before == after)

    let system = try #require(first.tracks[.system])
    let microphone = try #require(first.tracks[.microphone])
    #expect(system.format.sampleRate == 48_000)
    #expect(system.format.channelCount == 1)
    #expect(microphone.format.sampleRate == 44_100)
    #expect(microphone.format.channelCount == 1)
    #expect(microphone.format.canonicalBecause == nil)
    #expect(system.result.bitDepth == .bits24)
    #expect(microphone.result.bitDepth == .bits24)
    #expect(system.result.frameCount == first.timeline.track(.system)?.outputFrameCount)
    #expect(microphone.result.frameCount == 48_510, "one-second mic plus its preserved 100 ms lead")
    #expect(abs(microphone.result.duration - first.timeline.durationSeconds) < 1.0 / 44_100)

    let decoded = try AVAudioFile(forReading: archive.sessionDirectory.appendingPathComponent("microphone.flac"))
    #expect(decoded.fileFormat.sampleRate == 44_100)
    #expect(decoded.fileFormat.channelCount == 1)
    #expect(decoded.length == microphone.result.frameCount)
    #expect(try FLACStreamInfo.read(from: microphone.result.url).bitsPerSample == 24)

    let manifest = try RecorderSessionManifestCodec.decode(Data(contentsOf: archive.sessionDirectory.appendingPathComponent("metadata.json")))
    #expect(manifest.tracks.system?.fileName == "system.flac")
    #expect(manifest.tracks.microphone?.checksum == microphone.result.sha256)
    #expect(manifest.tracks.microphone?.journalReference == "capture/timeline.jsonl")
    #expect(manifest.processing.configuration["unprocessedFLAC"] != nil)

    let second = try UnprocessedFLACExporter().export(sessionDirectory: archive.sessionDirectory)
    #expect(second.tracks[.system]?.result.sha256 == system.result.sha256)
    #expect(second.tracks[.microphone]?.result.sha256 == microphone.result.sha256)
    #expect(try directoryDigest(archive.captureDirectory) == before)
}

@Test func formatChangesUseTheDocumentedCanonicalTimelineFormat() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try CaptureArchiveFixture(root: root)
    try writeTrack(archive, track: "system", start: exportOrigin, rate: 44_100, seconds: 0.5)
    try writeTrack(archive, track: "system", start: exportOrigin + 0.5, rate: 48_000, seconds: 0.5)
    try archive.finish()
    try writeManifest(at: archive.sessionDirectory)

    let exported = try UnprocessedFLACExporter().export(sessionDirectory: archive.sessionDirectory)
    let system = try #require(exported.tracks[.system])
    #expect(system.format.sampleRate == 48_000)
    #expect(system.format.canonicalBecause?.contains("journaled format transition") == true)
    #expect(system.result.frameCount == exported.timeline.track(.system)?.outputFrameCount)
    #expect(try FLACStreamInfo.read(from: system.result.url).sampleRate == 48_000)
}

private func writeTrack(_ archive: CaptureArchiveFixture, track: String, start: Double, rate: Int, seconds: Double) throws {
    let total = Int(Double(rate) * seconds)
    var offset = 0
    while offset < total {
        let count = min(960, total - offset)
        try archive.write(
            track: track,
            at: start + Double(offset) / Double(rate),
            samples: testSignal(frames: count, startingAt: offset),
            format: .init(sampleRate: rate)
        )
        offset += count
    }
}

private func writeManifest(at directory: URL) throws {
    let manifest = RecorderSessionManifest(
        sessionID: UUID(),
        appBuild: "tests",
        macOSVersion: "tests",
        startedAt: Date(timeIntervalSince1970: 0),
        completionStatus: .complete,
        capture: CaptureMetadata(
            state: .complete,
            scope: CaptureScope(applicationBundleIdentifiers: [], processIdentifiers: []),
            microphone: AudioDeviceIdentity(uniqueID: "test", name: "Test Microphone")
        ),
        tracks: RecorderTrackCollection(),
        processing: ProcessingMetadata(state: .pending)
    )
    try AtomicReplaceFileWriter().write(manifest, to: directory.appendingPathComponent("metadata.json"))
}
