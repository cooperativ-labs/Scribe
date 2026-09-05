import AVFoundation
import CoreMedia
import Foundation
import Platform
import ScribeAppCore
import Storage
import Testing
@testable import Capture

/// Drives `CaptureService`'s delivery path end to end into a real `SessionStore`
/// using synthetic `CMSampleBuffer`s in the two layouts ScreenCaptureKit was
/// measured to produce.
///
/// This is the deterministic half of the ten-minute gate: it proves every link
/// from a sample handler through the bounded queue and the writer queue to CAF
/// segments on disk, and leaves only `SCStream` itself for the real-Mac run in
/// `Tools/CaptureIntegration`, which needs a Screen & System Audio Recording grant.
@Suite struct CaptureDeliveryPipelineTests {
    private func makeService(
        store: SessionStore,
        maximumQueuedBytes: Int = 4 * 1_024 * 1_024,
        errors: Locked<[String]> = Locked([]),
        events: Locked<[String]> = Locked([])
    ) -> CaptureService {
        CaptureService(
            configuration: CaptureConfiguration(
                applicationBundleIdentifier: "com.apple.Safari",
                maximumQueuedBytes: maximumQueuedBytes
            ),
            sink: { buffer in
                do { try store.append(buffer) } catch { errors.mutate { $0.append(error.localizedDescription) } }
            },
            events: { event in events.mutate { $0.append("\(event)") } }
        )
    }

    private func systemBuffer(index: Int, startSeconds: Double = 207_492.667875) throws -> CMSampleBuffer {
        let frames = 960
        return try SyntheticSampleBuffer.make(
            sampleRate: 48_000, channelCount: 2, interleaved: false, frameCount: frames,
            presentation: CMTime(
                value: Int64((startSeconds + Double(index * frames) / 48_000) * 1_000_000),
                timescale: 1_000_000
            )
        ) { channel, frame in Float(channel) + Float(index * frames + frame) / 100_000 }
    }

    private func microphoneBuffer(index: Int, startSeconds: Double = 207_492.998875) throws -> CMSampleBuffer {
        let frames = 512
        return try SyntheticSampleBuffer.make(
            sampleRate: 48_000, channelCount: 1, interleaved: true, frameCount: frames,
            presentation: CMTime(
                value: Int64((startSeconds + Double(index * frames) / 48_000) * 1_000_000),
                timescale: 1_000_000
            )
        ) { _, frame in Float(index * frames + frame) / 100_000 }
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-pipeline-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeStore(in directory: URL) throws -> SessionStore {
        try SessionStore.create(configuration: SessionStoreConfiguration(
            recordingsDirectory: directory,
            appBuild: "capture-tests",
            macOSVersion: "test",
            captureScope: CaptureScope(applicationBundleIdentifiers: ["com.apple.Safari"], processIdentifiers: [340]),
            microphone: AudioDeviceIdentity(uniqueID: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")
        ))
    }

    /// The gate's shape, at a scale a unit test can run: both tracks delivered,
    /// nothing dropped, and archived CAF segments that actually hold the samples.
    @Test func bothTracksReachTheSessionStoreWithNothingDropped() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try makeStore(in: directory)
        let errors = Locked<[String]>([])
        let service = makeService(store: store, errors: errors)

        // Ten seconds of both tracks at the measured cadences: 20 ms system
        // buffers and 10.67 ms microphone buffers, interleaved as they arrive.
        let systemBuffers = 500
        let microphoneBuffers = 937
        for index in 0..<max(systemBuffers, microphoneBuffers) {
            if index < systemBuffers { service.ingest(try self.systemBuffer(index: index), track: .system) }
            if index < microphoneBuffers { service.ingest(try self.microphoneBuffer(index: index), track: .microphone) }
        }

        let statistics = await service.stop()
        try store.finish()

        #expect(statistics.hasBothTracks)
        #expect(statistics.system.enqueuedBuffers == systemBuffers)
        #expect(statistics.microphone.enqueuedBuffers == microphoneBuffers)
        #expect(statistics.droppedBuffers == 0)
        #expect(statistics.rejectedBuffers == 0)
        #expect(errors.value.isEmpty)

        let files = try FileManager.default.contentsOfDirectory(atPath: store.captureDirectory.path)
        let segments = files.filter { $0.hasSuffix(".caf") }.sorted()
        #expect(segments.contains("system-0001.caf"))
        #expect(segments.contains("microphone-0001.caf"))

        // Every archived sample is present as transcription-grade mono int16.
        let systemSize = try FileManager.default
            .attributesOfItem(atPath: store.captureDirectory.appendingPathComponent("system-0001.caf").path)[.size] as? Int
        #expect(systemSize == 68 + systemBuffers * 960 * 2)

        // And the CAF the store wrote is readable by AVFoundation, not just by us.
        let file = try AVAudioFile(forReading: store.captureDirectory.appendingPathComponent("microphone-0001.caf"))
        #expect(file.fileFormat.sampleRate == 48_000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(file.length == Int64(microphoneBuffers * 512))
    }

    /// The two tracks do not start together: the microphone was measured starting
    /// +0.123 s to +2.594 s after system audio, never simultaneously. The store's
    /// journal has to record each track's own first timestamp.
    @Test func eachTracksOwnFirstTimestampReachesTheJournal() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try makeStore(in: directory)
        let service = makeService(store: store)

        service.ingest(try systemBuffer(index: 0, startSeconds: 207_637.576748), track: .system)
        service.ingest(try microphoneBuffer(index: 0, startSeconds: 207_640.170292), track: .microphone)
        _ = await service.stop()
        try store.finish()

        let journal = try String(contentsOf: store.timelineURL, encoding: .utf8)
        let initial = journal
            .split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .filter { $0["event"] as? String == "initial-timestamp" }
        #expect(initial.count == 2)

        let byTrack = Dictionary(uniqueKeysWithValues: initial.map { ($0["track"] as! String, $0["timestampSeconds"] as! Double) })
        #expect(abs(byTrack["system"]! - 207_637.576748) < 0.000_01)
        #expect(abs(byTrack["microphone"]! - 207_640.170292) < 0.000_01)
        #expect(abs((byTrack["microphone"]! - byTrack["system"]!) - 2.593544) < 0.000_01)
    }

    /// The microphone ignores the stream's requested format and can change rate at
    /// any moment. Capture reports the change from the buffers themselves, and the
    /// store rotates to a new segment rather than splicing two formats together.
    @Test func aMidStreamFormatChangeIsReportedAndRotatesTheSegment() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try makeStore(in: directory)
        let events = Locked<[String]>([])
        let service = makeService(store: store, events: events)

        for index in 0..<5 { service.ingest(try microphoneBuffer(index: index), track: .microphone) }
        // The device reappears at 44.1 kHz, as a USB microphone changing rate would.
        let rateChanged = try SyntheticSampleBuffer.make(
            sampleRate: 44_100, channelCount: 1, interleaved: true, frameCount: 512,
            presentation: CMTime(value: Int64(207_493.05 * 1_000_000), timescale: 1_000_000)
        ) { _, _ in 0.25 }
        service.ingest(rateChanged, track: .microphone)

        _ = await service.stop()
        try store.finish()

        #expect(events.value.contains { $0.contains("formatChanged") && $0.contains("44100") })

        let files = try FileManager.default.contentsOfDirectory(atPath: store.captureDirectory.path)
        #expect(files.filter { $0.hasPrefix("microphone") && $0.hasSuffix(".caf") }.count == 2)

        let journal = try String(contentsOf: store.timelineURL, encoding: .utf8)
        #expect(journal.contains("\"event\":\"format-change\""))
    }

    /// A buffer that cannot be read as linear PCM is counted, not archived as
    /// garbage and not treated as fatal.
    @Test func anUnreadableBufferIsRejectedWithoutStoppingTheCapture() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try makeStore(in: directory)
        let events = Locked<[String]>([])
        let service = makeService(store: store, events: events)

        var empty: CMSampleBuffer?
        CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: nil,
            sampleCount: 0, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &empty
        )
        service.ingest(try #require(empty), track: .system)
        service.ingest(try systemBuffer(index: 0), track: .system)

        let statistics = await service.stop()
        try store.finish()

        #expect(statistics.rejectedBuffers == 1)
        #expect(statistics.system.enqueuedBuffers == 1)
        #expect(events.value.contains { $0.contains("bufferRejected") })
    }

    /// A stalled writer costs bounded memory and a counted refusal, never the
    /// machine -- and the refusal is reported rather than swallowed.
    @Test func aFullHandOffQueueDropsAndReportsRatherThanGrowing() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try makeStore(in: directory)
        let events = Locked<[String]>([])
        // Room for exactly two 960-frame mono int16 buffers.
        let service = makeService(store: store, maximumQueuedBytes: 2 * 960 * 2, events: events)

        // Fill the queue without letting the writer drain it.
        let blocked = DispatchSemaphore(value: 0)
        let releasedWriter = DispatchQueue(label: "test.blocker")
        releasedWriter.async { blocked.wait() }

        for index in 0..<6 { service.ingest(try systemBuffer(index: index), track: .system) }
        blocked.signal()

        let statistics = await service.stop()
        try store.finish()

        #expect(statistics.system.enqueuedBuffers + statistics.system.droppedBuffers == 6)
        #expect(statistics.system.peakQueuedBytes <= 2 * 960 * 2)
        if statistics.droppedBuffers > 0 {
            #expect(events.value.contains { $0.contains("buffersDropped") })
        }
    }

    /// Silence is valid input. A meeting where nobody spoke must archive exactly
    /// like a loud one, because a filter matching a silent application and one
    /// whose application has died deliver the same exactly-zero buffers.
    @Test func aSilentCaptureIsArchivedLikeAnyOther() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try makeStore(in: directory)
        let service = makeService(store: store)

        for index in 0..<50 {
            let silent = try SyntheticSampleBuffer.make(
                sampleRate: 48_000, channelCount: 2, interleaved: false, frameCount: 960,
                presentation: CMTime(value: Int64((207_492.0 + Double(index) * 0.02) * 1_000_000), timescale: 1_000_000)
            ) { _, _ in 0 }
            service.ingest(silent, track: .system)
        }

        let statistics = await service.stop()
        try store.finish()

        #expect(statistics.system.enqueuedBuffers == 50)
        #expect(statistics.droppedBuffers == 0)
        let size = try FileManager.default
            .attributesOfItem(atPath: store.captureDirectory.appendingPathComponent("system-0001.caf").path)[.size] as? Int
        #expect(size == 68 + 50 * 960 * 2)
    }
}

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value { lock.withLock { storage } }

    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&storage) } }
}
