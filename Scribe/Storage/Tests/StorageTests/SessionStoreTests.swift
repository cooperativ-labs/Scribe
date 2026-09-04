import AVFoundation
import Foundation
import Testing
@testable import Storage
import ScribeAppCore

@Test func createsTimezoneNamedDirectoryAndInitialManifest() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = makeConfiguration(root: root, timeZone: try #require(TimeZone(secondsFromGMT: 7_200)))
    let date = Date(timeIntervalSince1970: 1_725_381_012)
    let first = try SessionStore.create(configuration: configuration, now: date)
    let second = try SessionStore.create(configuration: configuration, now: date)
    defer { try? first.finish(); try? second.finish() }

    #expect(first.sessionDirectory.lastPathComponent.contains("+02:00"))
    #expect(second.sessionDirectory.lastPathComponent.hasPrefix(first.sessionDirectory.lastPathComponent + "-"))
    #expect(first.sessionDirectory != second.sessionDirectory)
    let manifest = try RecorderSessionManifestCodec.decode(Data(contentsOf: first.manifestURL))
    #expect(manifest.capture.state == .capturing)
    #expect(manifest.processing.state == .pending)
    #expect(FileManager.default.fileExists(atPath: first.timelineURL.path))
}

@Test func journalDescribesGapsOverlapsAndFormatChanges() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SessionStore.create(configuration: makeConfiguration(root: root, segmentDuration: 60))
    let floatStereo = PCMFormat(sampleRate: 48_000, channelCount: 2, bitsPerChannel: 32, isFloat: true)
    let integerMono = PCMFormat(sampleRate: 16_000, channelCount: 1, bitsPerChannel: 16, isFloat: false)
    try store.append(buffer(track: .system, timestamp: 0, frames: 480, format: floatStereo))
    try store.append(buffer(track: .system, timestamp: 0.01, frames: 480, format: floatStereo))
    try store.append(buffer(track: .system, timestamp: 0.03, frames: 480, format: floatStereo)) // 10ms gap
    try store.append(buffer(track: .system, timestamp: 0.035, frames: 480, format: floatStereo)) // 5ms overlap
    try store.append(buffer(track: .system, timestamp: 0.045, frames: 160, format: integerMono)) // format rotation
    try store.recordInterruption(reason: "sleep")
    try store.finish()

    let events = try journalEvents(at: store.timelineURL)
    #expect(events.contains { $0["event"] as? String == "initial-timestamp" })
    #expect(events.contains { $0["event"] as? String == "contiguous-run" })
    let gap = try #require(events.first { $0["event"] as? String == "gap" })
    #expect(abs(try #require(gap["durationSeconds"] as? Double) - 0.01) < 0.000_001)
    let overlap = try #require(events.first { $0["event"] as? String == "overlap" })
    #expect(abs(try #require(overlap["durationSeconds"] as? Double) - 0.005) < 0.000_001)
    #expect(events.contains { $0["event"] as? String == "format-change" })
    #expect(events.contains { $0["event"] as? String == "interruption" && $0["reason"] as? String == "sleep" })
    #expect(events.contains { $0["event"] as? String == "checkpoint" })
    #expect(FileManager.default.fileExists(atPath: store.captureDirectory.appendingPathComponent("system-0002.caf").path))
}

@Test func rotatesCAFSegmentsAtBoundedInterval() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SessionStore.create(configuration: makeConfiguration(root: root, segmentDuration: 0.02))
    let format = PCMFormat(sampleRate: 48_000, channelCount: 1, bitsPerChannel: 16, isFloat: false)
    try store.append(buffer(track: .microphone, timestamp: 0, frames: 480, format: format))
    try store.append(buffer(track: .microphone, timestamp: 0.01, frames: 480, format: format))
    try store.append(buffer(track: .microphone, timestamp: 0.02, frames: 480, format: format))
    try store.finish()

    #expect(FileManager.default.fileExists(atPath: store.captureDirectory.appendingPathComponent("microphone-0001.caf").path))
    #expect(FileManager.default.fileExists(atPath: store.captureDirectory.appendingPathComponent("microphone-0002.caf").path))
}

@Test func recoveryRepairsCheckpointedActiveSegmentAndKeepsCompletedSegments() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SessionStore.create(configuration: makeConfiguration(root: root, segmentDuration: 0.02))
    let format = PCMFormat(sampleRate: 48_000, channelCount: 1, bitsPerChannel: 16, isFloat: false)
    try store.append(buffer(track: .system, timestamp: 0, frames: 480, format: format))
    try store.append(buffer(track: .system, timestamp: 0.02, frames: 480, format: format)) // closes 0001; opens active 0002

    let completed = store.captureDirectory.appendingPathComponent("system-0001.caf")
    let active = store.captureDirectory.appendingPathComponent("system-0002.caf")
    let completedBytes = try fileSize(completed)
    let expectedActiveBytes = try fileSize(active)
    let handle = try FileHandle(forWritingTo: active)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(repeating: 0xA5, count: 25)) // simulates uncheckpointed crash tail
    try handle.close()

    let recovered = try SessionStore.recoverIncompleteSessions(in: root)
    #expect(recovered.count == 1)
    #expect(recovered[0].recoveredActiveSegments == ["system-0002.caf"])
    #expect(try fileSize(completed) == completedBytes)
    #expect(try fileSize(active) == expectedActiveBytes)
    #expect(try AVAudioFile(forReading: active).length == 480)
    #expect(!FileManager.default.fileExists(atPath: store.captureDirectory.appendingPathComponent("system.active.json").path))
    let recoveredManifest = try RecorderSessionManifestCodec.decode(Data(contentsOf: store.manifestURL))
    #expect(recoveredManifest.capture.state == .interrupted)
    #expect(recoveredManifest.interruptions.last?.reason == "recovered after unclean shutdown")
    let events = try journalEvents(at: store.timelineURL)
    #expect(events.contains { $0["event"] as? String == "recovered-active-segments" })
}

@Test func lowSpaceRequestsOneCleanStopBeforeWriting() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let requested = LockedFlag()
    let configuration = makeConfiguration(root: root, minimumFreeBytes: 1_000, freeSpace: { _ in 999 }, cleanStop: { requested.set() })
    let store = try SessionStore.create(configuration: configuration)
    let format = PCMFormat(sampleRate: 48_000, channelCount: 1, bitsPerChannel: 16, isFloat: false)
    #expect(throws: SessionStoreError.self) { try store.append(buffer(track: .microphone, timestamp: 0, frames: 10, format: format)) }
    #expect(requested.value)
}

@Test func outputRouteChangesAreDurableInJournalAndManifest() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SessionStore.create(configuration: makeConfiguration(root: root))
    let changedAt = Date(timeIntervalSince1970: 1_725_381_234)
    let change = OutputDeviceChange(
        occurredAt: changedAt,
        previousDevice: AudioDeviceIdentity(uniqueID: "built-in", name: "MacBook Speakers"),
        currentDevice: AudioDeviceIdentity(uniqueID: "usb", name: "USB Headset")
    )

    try store.recordOutputDeviceChange(change)
    try store.finish()
    _ = try store.commitCapture(state: .complete, completionStatus: .complete, endedAt: changedAt)

    let manifest = try RecorderSessionManifestCodec.decode(Data(contentsOf: store.manifestURL))
    #expect(manifest.capture.outputDeviceChanges == [change])
    let events = try journalEvents(at: store.timelineURL)
    #expect(events.contains { $0["event"] as? String == "output-route-change" && $0["currentDeviceID"] as? String == "usb" })
}

private func makeConfiguration(
    root: URL,
    timeZone: TimeZone = .gmt,
    segmentDuration: TimeInterval = 60,
    minimumFreeBytes: Int64 = 0,
    freeSpace: @escaping @Sendable (URL) throws -> Int64 = { _ in .max },
    cleanStop: @escaping @Sendable () -> Void = {}
) -> SessionStoreConfiguration {
    SessionStoreConfiguration(
        recordingsDirectory: root,
        appBuild: "tests",
        macOSVersion: "macOS tests",
        captureScope: CaptureScope(applicationBundleIdentifiers: ["com.example.meeting"], processIdentifiers: [42]),
        microphone: AudioDeviceIdentity(uniqueID: "mic", name: "Test microphone"),
        timeZone: timeZone,
        segmentDuration: segmentDuration,
        minimumFreeBytes: minimumFreeBytes,
        freeSpaceProvider: freeSpace,
        cleanStopRequester: cleanStop
    )
}

private func buffer(track: RecorderTrackKind, timestamp: TimeInterval, frames: Int, format: PCMFormat) throws -> OwnedPCMBuffer {
    try OwnedPCMBuffer(track: track, presentationTimestampSeconds: timestamp, format: format, frameCount: frames, samples: Data(repeating: 0, count: frames * format.bytesPerFrame))
}

private func temporaryDirectory() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("SessionStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func journalEvents(at url: URL) throws -> [[String: Any]] {
    try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
        try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
    }
}

private func fileSize(_ url: URL) throws -> UInt64 {
    try #require((try FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber).uint64Value
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false
    var value: Bool { lock.withLock { storage } }
    func set() { lock.withLock { storage = true } }
}

/// The archive is only worth keeping if the samples read back out of it are the
/// samples that went in. Checking the declared format alone is not enough: a CAF
/// whose description chunk claims the wrong byte order is still a valid file, is
/// still readable, and still reports the right sample rate, channel count and
/// duration -- while every value it hands back is byte-swapped nonsense.
///
/// CAF's LPCM `mFormatFlags` has exactly two bits, 0x1 float and 0x2 little-endian,
/// and PCM copied out of CoreAudio is host little-endian.
@Test func archivedSamplesReadBackAtTheirOriginalValues() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SessionStore.create(configuration: makeConfiguration(root: root))

    let format = PCMFormat(sampleRate: 48_000, channelCount: 2, bitsPerChannel: 32, isFloat: true)
    let written: [Float] = [0.000_115_550_46, -0.25, 0.5, -1, 0.75, 0.125]
    var samples = Data()
    for value in written { withUnsafeBytes(of: value.bitPattern.littleEndian) { samples.append(contentsOf: $0) } }
    try store.append(OwnedPCMBuffer(
        track: .system, presentationTimestampSeconds: 0, format: format,
        frameCount: written.count / 2, samples: samples
    ))
    try store.finish()

    let url = store.captureDirectory.appendingPathComponent("system-0001.caf")
    let file = try AVAudioFile(forReading: url)
    #expect(file.fileFormat.sampleRate == 48_000)
    #expect(file.fileFormat.channelCount == 2)
    #expect(!file.fileFormat.streamDescription.pointee.mFormatFlags.isBigEndian(for: file.fileFormat))

    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 3))
    try file.read(into: buffer, frameCount: 3)
    #expect(buffer.frameLength == 3)

    let left = buffer.floatChannelData![0]
    let right = buffer.floatChannelData![1]
    #expect(left[0] == written[0])
    #expect(right[0] == written[1])
    #expect(left[1] == written[2])
    #expect(right[1] == written[3])
    #expect(left[2] == written[4])
    #expect(right[2] == written[5])
}

private extension AudioFormatFlags {
    func isBigEndian(for format: AVAudioFormat) -> Bool {
        self & kAudioFormatFlagIsBigEndian != 0
    }
}
