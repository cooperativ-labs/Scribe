import Foundation
import ScribeAppCore

/// An owned, interleaved linear-PCM buffer ready for durable capture storage.
///
/// Capture code must copy sample data out of `CMSampleBuffer` before making this
/// value. `SessionStore` therefore never retains an audio callback's no-copy
/// memory.
public struct OwnedPCMBuffer: Sendable, Equatable {
    public let track: RecorderTrackKind
    public let presentationTimestampSeconds: TimeInterval
    public let format: PCMFormat
    public let frameCount: Int
    public let samples: Data

    public init(track: RecorderTrackKind, presentationTimestampSeconds: TimeInterval, format: PCMFormat, frameCount: Int, samples: Data) throws {
        guard frameCount >= 0, samples.count == frameCount * format.bytesPerFrame else {
            throw SessionStoreError.invalidBufferLength(expected: max(0, frameCount) * format.bytesPerFrame, actual: samples.count)
        }
        self.track = track
        self.presentationTimestampSeconds = presentationTimestampSeconds
        self.format = format
        self.frameCount = frameCount
        self.samples = samples
    }
}

/// The native layout retained in each CAF segment. Segment data is always
/// interleaved, packed Linear PCM, which keeps byte-count recovery unambiguous.
public struct PCMFormat: Codable, Sendable, Equatable {
    public let sampleRate: Double
    public let channelCount: Int
    public let bitsPerChannel: Int
    public let isFloat: Bool

    public init(sampleRate: Double, channelCount: Int, bitsPerChannel: Int, isFloat: Bool) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitsPerChannel = bitsPerChannel
        self.isFloat = isFloat
    }

    public var bytesPerSample: Int { bitsPerChannel / 8 }
    public var bytesPerFrame: Int { bytesPerSample * channelCount }
    public var durationPerFrame: TimeInterval { 1 / sampleRate }
    public var description: String {
        "lpcm " + String(sampleRate) + " Hz, " + String(channelCount) + " ch, "
            + String(bitsPerChannel) + "-bit " + (isFloat ? "float" : "integer") + ", interleaved"
    }

    fileprivate var isValid: Bool {
        sampleRate > 0 && channelCount > 0 && bitsPerChannel > 0 && bitsPerChannel.isMultiple(of: 8)
    }

    fileprivate var manifestFormat: AudioSourceFormat {
        AudioSourceFormat(sampleRate: sampleRate, channelCount: channelCount, formatDescription: description)
    }

    fileprivate var journalObject: [String: Any] {
        ["sampleRate": sampleRate, "channelCount": channelCount, "bitsPerChannel": bitsPerChannel, "isFloat": isFloat, "interleaved": true, "description": description]
    }
}

public struct SessionStoreConfiguration: Sendable {
    public let recordingsDirectory: URL
    /// Provided by the coordinator so UI activity, processing work, and the
    /// durable manifest all address the same recording.
    public let sessionID: UUID?
    public let appBuild: String
    public let macOSVersion: String
    public let captureScope: CaptureScope
    public let microphone: AudioDeviceIdentity
    public let timeZone: TimeZone
    public let segmentDuration: TimeInterval
    public let minimumFreeBytes: Int64
    public let journalCheckpointEveryBuffers: Int
    public let freeSpaceProvider: @Sendable (URL) throws -> Int64
    public let cleanStopRequester: @Sendable () -> Void

    public init(
        recordingsDirectory: URL,
        sessionID: UUID? = nil,
        appBuild: String,
        macOSVersion: String,
        captureScope: CaptureScope,
        microphone: AudioDeviceIdentity,
        timeZone: TimeZone = .current,
        segmentDuration: TimeInterval = 60,
        minimumFreeBytes: Int64 = 512 * 1_024 * 1_024,
        journalCheckpointEveryBuffers: Int = 1,
        freeSpaceProvider: @escaping @Sendable (URL) throws -> Int64 = SessionStore.availableCapacity,
        cleanStopRequester: @escaping @Sendable () -> Void = {}
    ) {
        self.recordingsDirectory = recordingsDirectory
        self.sessionID = sessionID
        self.appBuild = appBuild
        self.macOSVersion = macOSVersion
        self.captureScope = captureScope
        self.microphone = microphone
        self.timeZone = timeZone
        self.segmentDuration = segmentDuration
        self.minimumFreeBytes = minimumFreeBytes
        self.journalCheckpointEveryBuffers = max(1, journalCheckpointEveryBuffers)
        self.freeSpaceProvider = freeSpaceProvider
        self.cleanStopRequester = cleanStopRequester
    }
}

public enum SessionStoreError: Error, Equatable, LocalizedError {
    case invalidBufferLength(expected: Int, actual: Int)
    case invalidFormat
    case unsupportedTrack(RecorderTrackKind)
    case insufficientFreeSpace(available: Int64, minimum: Int64)
    case corruptActiveSegment(URL)

    public var errorDescription: String? {
        switch self {
        case let .invalidBufferLength(expected, actual): return "PCM buffer has \(actual) bytes; expected \(expected)."
        case .invalidFormat: return "PCM format must be packed Linear PCM with a whole-byte sample width."
        case let .unsupportedTrack(track): return "\(track.rawValue) is not a capture track."
        case let .insufficientFreeSpace(available, minimum): return "Only \(available) bytes remain; clean stop requested before the \(minimum)-byte reserve."
        case let .corruptActiveSegment(url): return "The active segment at \(url.path) is shorter than its checkpointed byte count."
        }
    }
}

/// A crash-resilient archive for a single recorder session.
///
/// The class is intended to be called only from the capture writer's serial
/// queue. It has no callback-thread work and all incoming PCM is already owned.
public final class SessionStore: @unchecked Sendable {
    public let sessionDirectory: URL
    public let captureDirectory: URL
    public let manifestURL: URL
    public let timelineURL: URL
    public private(set) var manifest: RecorderSessionManifest

    private let configuration: SessionStoreConfiguration
    private let journal: TimelineJournal
    private var writers: [RecorderTrackKind: CAFSegmentWriter] = [:]
    private var cleanStopRequested = false

    private init(sessionDirectory: URL, configuration: SessionStoreConfiguration, manifest: RecorderSessionManifest, journal: TimelineJournal) {
        self.sessionDirectory = sessionDirectory
        self.captureDirectory = sessionDirectory.appendingPathComponent("capture", isDirectory: true)
        self.manifestURL = sessionDirectory.appendingPathComponent("metadata.json")
        self.timelineURL = sessionDirectory.appendingPathComponent("capture/timeline.jsonl")
        self.configuration = configuration
        self.manifest = manifest
        self.journal = journal
    }

    /// Atomically reserves a timestamp-and-time-zone session directory, writes
    /// its manifest, then creates the capture journal before capture begins.
    public static func create(configuration: SessionStoreConfiguration, now: Date = Date(), sessionID: UUID = UUID()) throws -> SessionStore {
        let manager = FileManager.default
        try manager.createDirectory(at: configuration.recordingsDirectory, withIntermediateDirectories: true)
        let baseName = sessionDirectoryName(for: now, timeZone: configuration.timeZone)
        let directory = try reserveSessionDirectory(in: configuration.recordingsDirectory, baseName: baseName)
        let capture = directory.appendingPathComponent("capture", isDirectory: true)
        try manager.createDirectory(at: capture, withIntermediateDirectories: false)

        let resolvedSessionID = configuration.sessionID ?? sessionID
        let manifest = RecorderSessionManifest(
            sessionID: resolvedSessionID,
            appBuild: configuration.appBuild,
            macOSVersion: configuration.macOSVersion,
            startedAt: now,
            completionStatus: .interrupted,
            capture: CaptureMetadata(state: .capturing, scope: configuration.captureScope, microphone: configuration.microphone),
            tracks: RecorderTrackCollection(),
            processing: ProcessingMetadata(state: .pending)
        )
        let manifestURL = directory.appendingPathComponent("metadata.json")
        try AtomicReplaceFileWriter().write(manifest, to: manifestURL)
        let journal = try TimelineJournal(url: capture.appendingPathComponent("timeline.jsonl"), checkpointEvery: configuration.journalCheckpointEveryBuffers)
        try journal.append(["event": "session-created", "sessionID": resolvedSessionID.uuidString, "wallClock": ISO8601DateFormatter().string(from: now)])
        return SessionStore(sessionDirectory: directory, configuration: configuration, manifest: manifest, journal: journal)
    }

    public func append(_ buffer: OwnedPCMBuffer) throws {
        guard buffer.format.isValid else { throw SessionStoreError.invalidFormat }
        guard buffer.track == .system || buffer.track == .microphone else { throw SessionStoreError.unsupportedTrack(buffer.track) }
        try ensureFreeSpace()

        let writer: CAFSegmentWriter
        if let existing = writers[buffer.track] {
            writer = existing
        } else {
            writer = try CAFSegmentWriter(track: buffer.track, directory: captureDirectory, journal: journal, segmentDuration: configuration.segmentDuration)
            writers[buffer.track] = writer
        }
        try writer.append(buffer)
    }

    /// Marks a deliberate hold on archiving. It authorizes nothing on its own:
    /// the timestamp discontinuity the pause creates is journaled as an ordinary
    /// gap by the segment writer, which is what the builder reconstructs from.
    /// This exists so a gap that was intended is distinguishable, after the
    /// fact, from one that was not.
    public func recordCapturePause(resumed: Bool, at date: Date = Date()) throws {
        try journal.append([
            "event": resumed ? "capture-resumed" : "capture-paused",
            "wallClock": ISO8601DateFormatter().string(from: date),
        ], forceCheckpoint: true)
    }

    public func recordInterruption(reason: String, at date: Date = Date()) throws {
        try journal.append([
            "event": "interruption", "reason": reason,
            "wallClock": ISO8601DateFormatter().string(from: date),
        ], forceCheckpoint: true)
    }

    /// Replaces the provisional source identity written before `SCStream` was
    /// started with the process and microphone that were actually bound.
    public func updateCaptureSources(_ sources: CaptureSourceUpdate) throws {
        let current = try currentManifest()
        let updated = RecorderSessionManifest(
            schemaVersion: current.schemaVersion,
            sessionID: current.sessionID,
            appBuild: current.appBuild,
            macOSVersion: current.macOSVersion,
            startedAt: current.startedAt,
            endedAt: current.endedAt,
            durationSeconds: current.durationSeconds,
            completionStatus: current.completionStatus,
            capture: CaptureMetadata(state: current.capture.state, scope: sources.scope, microphone: sources.microphone, outputDeviceChanges: current.capture.outputDeviceChanges),
            tracks: current.tracks,
            gaps: current.gaps,
            interruptions: current.interruptions,
            processing: current.processing
        )
        try AtomicReplaceFileWriter().write(updated, to: manifestURL)
        manifest = updated
    }

    /// Output changes do not stop capture, but downstream AEC needs the fact
    /// and its time in the durable journal and manifest.
    public func recordOutputDeviceChange(_ change: OutputDeviceChange) throws {
        try journal.append([
            "event": "output-route-change",
            "wallClock": ISO8601DateFormatter().string(from: change.occurredAt),
            "previousDeviceID": change.previousDevice?.uniqueID as Any,
            "currentDeviceID": change.currentDevice.uniqueID,
            "currentDeviceName": change.currentDevice.name,
        ], forceCheckpoint: true)
        let current = try currentManifest()
        let updated = RecorderSessionManifest(
            schemaVersion: current.schemaVersion, sessionID: current.sessionID,
            appBuild: current.appBuild, macOSVersion: current.macOSVersion,
            startedAt: current.startedAt, endedAt: current.endedAt,
            durationSeconds: current.durationSeconds, completionStatus: current.completionStatus,
            capture: CaptureMetadata(state: current.capture.state, scope: current.capture.scope, microphone: current.capture.microphone, outputDeviceChanges: current.capture.outputDeviceChanges + [change]),
            tracks: current.tracks, gaps: current.gaps, interruptions: current.interruptions,
            processing: current.processing
        )
        try AtomicReplaceFileWriter().write(updated, to: manifestURL)
        manifest = updated
    }

    /// Finalizes currently-open segments. The coordinator owns the final manifest
    /// transition, so this method deliberately does not claim processing is done.
    public func finish() throws {
        for writer in writers.values { try writer.finish() }
        try journal.append(["event": "session-writer-finished"], forceCheckpoint: true)
        try journal.close()
    }

    /// Restores every session that still advertises `capture.state == capturing`.
    /// Completed CAF segments are untouched; an active segment is truncated to
    /// the last persisted byte count and its CAF data-chunk length is repaired.
    @discardableResult
    public static func recoverIncompleteSessions(in recordingsDirectory: URL) throws -> [RecoveredSession] {
        let manager = FileManager.default
        let directories = try manager.contentsOfDirectory(at: recordingsDirectory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        return try directories.compactMap { directory -> RecoveredSession? in
            let metadata = directory.appendingPathComponent("metadata.json")
            guard let data = try? Data(contentsOf: metadata), let manifest = try? RecorderSessionManifestCodec.decode(data), manifest.capture.state == .capturing else { return nil }
            return try recover(sessionDirectory: directory)
        }
    }

    @discardableResult
    public static func recover(sessionDirectory: URL) throws -> RecoveredSession {
        let metadata = sessionDirectory.appendingPathComponent("metadata.json")
        let manifest = try RecorderSessionManifestCodec.decode(Data(contentsOf: metadata))
        let capture = sessionDirectory.appendingPathComponent("capture", isDirectory: true)
        let activeStates = try FileManager.default.contentsOfDirectory(at: capture, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".active.json") }
        var recovered: [String] = []
        for stateURL in activeStates {
            let state = try JSONDecoder().decode(ActiveSegmentState.self, from: Data(contentsOf: stateURL))
            let segmentURL = capture.appendingPathComponent(state.file)
            try CAFSegmentWriter.repair(segmentURL: segmentURL, format: state.format, dataByteCount: state.dataByteCount)
            try? FileManager.default.removeItem(at: stateURL)
            recovered.append(state.file)
        }
        let journal = try TimelineJournal(url: capture.appendingPathComponent("timeline.jsonl"), append: true, checkpointEvery: 1)
        try journal.append(["event": "recovered-active-segments", "files": recovered.sorted()], forceCheckpoint: true)
        try journal.close()
        let recoveredAt = Date()
        let recoveredManifest = RecorderSessionManifest(
            schemaVersion: manifest.schemaVersion,
            sessionID: manifest.sessionID,
            appBuild: manifest.appBuild,
            macOSVersion: manifest.macOSVersion,
            startedAt: manifest.startedAt,
            endedAt: recoveredAt,
            durationSeconds: max(0, recoveredAt.timeIntervalSince(manifest.startedAt)),
            completionStatus: .interrupted,
            capture: CaptureMetadata(state: .interrupted, scope: manifest.capture.scope, microphone: manifest.capture.microphone, outputDeviceChanges: manifest.capture.outputDeviceChanges),
            tracks: manifest.tracks,
            gaps: manifest.gaps,
            interruptions: manifest.interruptions + [CaptureInterruption(occurredAt: recoveredAt, reason: "recovered after unclean shutdown")],
            processing: manifest.processing
        )
        try AtomicReplaceFileWriter().write(recoveredManifest, to: metadata)
        return RecoveredSession(sessionDirectory: sessionDirectory, sessionID: manifest.sessionID, recoveredActiveSegments: recovered.sorted())
    }

    public struct RecoveredSession: Sendable, Equatable {
        public let sessionDirectory: URL
        public let sessionID: UUID
        public let recoveredActiveSegments: [String]
    }

    public static func availableCapacity(at directory: URL) throws -> Int64 {
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values.volumeAvailableCapacityForImportantUsage { return important }
        if let standard = values.volumeAvailableCapacity { return Int64(standard) }
        return Int64.max
    }

    private func ensureFreeSpace() throws {
        let available = try configuration.freeSpaceProvider(sessionDirectory)
        guard available >= configuration.minimumFreeBytes else {
            if !cleanStopRequested {
                cleanStopRequested = true
                configuration.cleanStopRequester()
                try journal.append(["event": "low-free-space", "availableBytes": available, "minimumBytes": configuration.minimumFreeBytes], forceCheckpoint: true)
            }
            throw SessionStoreError.insufficientFreeSpace(available: available, minimum: configuration.minimumFreeBytes)
        }
    }

    /// The coordinator calls this only after `finish()`: writers and the
    /// journal are closed before the manifest claims the capture is final.
    @discardableResult
    public func commitCapture(
        state: CaptureState,
        completionStatus: RecorderSessionCompletionStatus,
        endedAt: Date = Date(),
        interruptionReason: String? = nil
    ) throws -> RecorderSessionManifest {
        let current = try currentManifest()
        let interruptions = interruptionReason.map {
            current.interruptions + [CaptureInterruption(occurredAt: endedAt, reason: $0)]
        } ?? current.interruptions
        let updated = RecorderSessionManifest(
            schemaVersion: current.schemaVersion, sessionID: current.sessionID,
            appBuild: current.appBuild, macOSVersion: current.macOSVersion,
            startedAt: current.startedAt, endedAt: endedAt,
            durationSeconds: max(0, endedAt.timeIntervalSince(current.startedAt)),
            completionStatus: completionStatus,
            capture: CaptureMetadata(state: state, scope: current.capture.scope, microphone: current.capture.microphone, outputDeviceChanges: current.capture.outputDeviceChanges),
            tracks: current.tracks, gaps: current.gaps, interruptions: interruptions,
            processing: current.processing
        )
        try AtomicReplaceFileWriter().write(updated, to: manifestURL)
        manifest = updated
        return updated
    }

    private func currentManifest() throws -> RecorderSessionManifest {
        try RecorderSessionManifestCodec.decode(Data(contentsOf: manifestURL))
    }
}

/// The resolved source identities that replace a selection-time placeholder in
/// the initial manifest once `SCStream` has successfully started.
public struct CaptureSourceUpdate: Sendable, Equatable {
    public let scope: CaptureScope
    public let microphone: AudioDeviceIdentity

    public init(scope: CaptureScope, microphone: AudioDeviceIdentity) {
        self.scope = scope
        self.microphone = microphone
    }
}

private final class CAFSegmentWriter {
    private static let cafAudioDataOffset: UInt64 = 68
    private let track: RecorderTrackKind
    private let directory: URL
    private let journal: TimelineJournal
    private let segmentDuration: TimeInterval
    private var segmentNumber = 0
    private var active: ActiveSegment?
    private var lastEndTimestamp: TimeInterval?

    init(track: RecorderTrackKind, directory: URL, journal: TimelineJournal, segmentDuration: TimeInterval) throws {
        self.track = track
        self.directory = directory
        self.journal = journal
        self.segmentDuration = segmentDuration
    }

    func append(_ buffer: OwnedPCMBuffer) throws {
        let needsFormatRotation = active.map { $0.format != buffer.format } ?? false
        let needsDurationRotation = active.map { segmentDuration > 0 && buffer.presentationTimestampSeconds - $0.firstTimestamp >= segmentDuration } ?? false
        if active == nil || needsFormatRotation || needsDurationRotation {
            if needsFormatRotation, let old = active {
                try journal.append(["event": "format-change", "track": track.rawValue, "from": old.format.journalObject, "to": buffer.format.journalObject, "atSeconds": buffer.presentationTimestampSeconds], forceCheckpoint: true)
            }
            try closeActive(reason: needsFormatRotation ? "format-change" : (needsDurationRotation ? "bounded-interval" : "initial"))
            try open(for: buffer)
        }
        guard var active else { return }
        let expected = lastEndTimestamp ?? buffer.presentationTimestampSeconds
        let delta = buffer.presentationTimestampSeconds - expected
        let tolerance = max(buffer.format.durationPerFrame / 2, 0.000_001)
        if delta > tolerance {
            try journal.append(["event": "gap", "track": track.rawValue, "startedAtSeconds": expected, "durationSeconds": delta, "file": active.file, "fileFrameOffset": active.frameCount], forceCheckpoint: true)
        } else if delta < -tolerance {
            try journal.append(["event": "overlap", "track": track.rawValue, "startedAtSeconds": buffer.presentationTimestampSeconds, "durationSeconds": -delta, "file": active.file, "fileFrameOffset": active.frameCount], forceCheckpoint: true)
        } else {
            try journal.append(["event": "contiguous-run", "track": track.rawValue, "startedAtSeconds": buffer.presentationTimestampSeconds, "frameCount": buffer.frameCount, "file": active.file, "fileFrameOffset": active.frameCount])
        }

        try active.handle.seekToEnd()
        try active.handle.write(contentsOf: buffer.samples)
        active.dataByteCount += Int64(buffer.samples.count)
        active.frameCount += Int64(buffer.frameCount)
        try writeDataChunkByteCount(active.dataByteCount, to: active.handle)
        try active.handle.synchronize()
        try writeCheckpoint(active)
        lastEndTimestamp = buffer.presentationTimestampSeconds + Double(buffer.frameCount) / buffer.format.sampleRate
        self.active = active
    }

    func finish() throws { try closeActive(reason: "finished") }

    private func open(for buffer: OwnedPCMBuffer) throws {
        segmentNumber += 1
        let stem = buffer.track == .system ? "system" : "microphone"
        let file = String(format: "%@-%04d.caf", stem, segmentNumber)
        let url = directory.appendingPathComponent(file)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try Self.writeCAFHeader(format: buffer.format, to: handle)
        try handle.synchronize()
        active = ActiveSegment(file: file, format: buffer.format, firstTimestamp: buffer.presentationTimestampSeconds, frameCount: 0, dataByteCount: 0, handle: handle)
        guard let active else { return }
        try writeCheckpoint(active)
        try journal.append(["event": "initial-timestamp", "track": track.rawValue, "timestampSeconds": buffer.presentationTimestampSeconds, "file": file, "fileFrameOffset": 0, "format": buffer.format.journalObject], forceCheckpoint: true)
        try journal.append(["event": "segment-opened", "track": track.rawValue, "file": file, "reason": "active", "format": buffer.format.journalObject])
    }

    private func closeActive(reason: String) throws {
        guard let active else { return }
        try writeDataChunkByteCount(active.dataByteCount, to: active.handle)
        try active.handle.synchronize()
        try active.handle.close()
        try? FileManager.default.removeItem(at: checkpointURL)
        try journal.append(["event": "segment-closed", "track": track.rawValue, "file": active.file, "reason": reason, "frameCount": active.frameCount, "dataByteCount": active.dataByteCount], forceCheckpoint: true)
        self.active = nil
    }

    private var checkpointURL: URL {
        let stem = track == .system ? "system" : "microphone"
        return directory.appendingPathComponent("\(stem).active.json")
    }

    private func writeCheckpoint(_ active: ActiveSegment) throws {
        let state = ActiveSegmentState(file: active.file, format: active.format, dataByteCount: active.dataByteCount, frameCount: active.frameCount)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try atomicWrite(try encoder.encode(state), to: checkpointURL)
        try journal.append(["event": "checkpoint", "track": track.rawValue, "file": active.file, "dataByteCount": active.dataByteCount, "frameCount": active.frameCount], forceCheckpoint: true)
    }

    static func repair(segmentURL: URL, format: PCMFormat, dataByteCount: Int64) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: segmentURL.path)
        let expectedLength = cafAudioDataOffset + UInt64(max(0, dataByteCount))
        guard let actual = attributes[.size] as? NSNumber, actual.uint64Value >= expectedLength else {
            throw SessionStoreError.corruptActiveSegment(segmentURL)
        }
        let handle = try FileHandle(forWritingTo: segmentURL)
        try handle.truncate(atOffset: expectedLength)
        // The active sidecar is the durable authority after a crash: restore the
        // description chunk as well as the data length before exposing the CAF.
        try handle.seek(toOffset: 0)
        try writeCAFHeader(format: format, to: handle)
        try writeDataChunkByteCount(dataByteCount, to: handle)
        try handle.synchronize()
        try handle.close()
    }

    private static func writeCAFHeader(format: PCMFormat, to handle: FileHandle) throws {
        var data = Data()
        data.appendASCII("caff")
        data.appendUInt16(1)
        data.appendUInt16(0)
        data.appendASCII("desc")
        data.appendInt64(32)
        data.appendDouble(format.sampleRate)
        data.appendASCII("lpcm")
        // CAF's mFormatFlags for LPCM defines exactly two bits: 0x1
        // kCAFLinearPCMFormatFlagIsFloat and 0x2 kCAFLinearPCMFormatFlagIsLittleEndian.
        // There is no "packed" flag here -- that one belongs to an ASBD, not to a
        // CAF description chunk. Segment data is copied straight out of CoreAudio
        // and is therefore host little-endian, so 0x2 is always set; declaring
        // otherwise makes every float sample read back byte-swapped.
        // CAF's mFormatFlags for LPCM defines exactly two bits: 0x1
        // kCAFLinearPCMFormatFlagIsFloat and 0x2 kCAFLinearPCMFormatFlagIsLittleEndian.
        // There is no "packed" flag here -- that one belongs to an ASBD, not to a
        // CAF description chunk. Segment data is copied straight out of CoreAudio
        // and is therefore host little-endian, so 0x2 is always set; declaring
        // otherwise makes every float sample read back byte-swapped.
        var flags: UInt32 = 1 << 1 // little-endian
        if format.isFloat { flags |= 1 }
        data.appendUInt32(flags)
        data.appendUInt32(UInt32(format.bytesPerFrame))
        data.appendUInt32(1)
        data.appendUInt32(UInt32(format.channelCount))
        data.appendUInt32(UInt32(format.bitsPerChannel))
        data.appendASCII("data")
        data.appendInt64(4) // edit count plus zero bytes of PCM
        data.appendUInt32(0)
        try handle.write(contentsOf: data)
    }

    private static func writeDataChunkByteCount(_ byteCount: Int64, to handle: FileHandle) throws {
        try handle.seek(toOffset: 56)
        var data = Data()
        data.appendInt64(byteCount + 4)
        try handle.write(contentsOf: data)
    }

    private func writeDataChunkByteCount(_ byteCount: Int64, to handle: FileHandle) throws {
        try Self.writeDataChunkByteCount(byteCount, to: handle)
    }
}

private struct ActiveSegment {
    let file: String
    let format: PCMFormat
    let firstTimestamp: TimeInterval
    var frameCount: Int64
    var dataByteCount: Int64
    let handle: FileHandle
}

private struct ActiveSegmentState: Codable {
    let file: String
    let format: PCMFormat
    let dataByteCount: Int64
    let frameCount: Int64
}

private final class TimelineJournal {
    private let url: URL
    private let handle: FileHandle
    private let checkpointEvery: Int
    private var appendCount = 0

    init(url: URL, append: Bool = false, checkpointEvery: Int) throws {
        self.url = url
        self.checkpointEvery = checkpointEvery
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        self.handle = try FileHandle(forWritingTo: url)
        if append { try handle.seekToEnd() }
    }

    func append(_ object: [String: Any], forceCheckpoint: Bool = false) throws {
        var line = object
        line["journalVersion"] = 1
        line["wallClock"] = line["wallClock"] ?? ISO8601DateFormatter().string(from: Date())
        var data = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try handle.write(contentsOf: data)
        appendCount += 1
        if forceCheckpoint || appendCount.isMultiple(of: checkpointEvery) { try handle.synchronize() }
    }

    func close() throws { try handle.synchronize(); try handle.close() }
}

private func reserveSessionDirectory(in root: URL, baseName: String) throws -> URL {
    let manager = FileManager.default
    for attempt in 0..<128 {
        let suffix = attempt == 0 ? "" : "-\(String(UUID().uuidString.prefix(8)).lowercased())"
        let candidate = root.appendingPathComponent(baseName + suffix, isDirectory: true)
        do {
            try manager.createDirectory(at: candidate, withIntermediateDirectories: false)
            return candidate
        } catch let error as NSError where error.code == CocoaError.Code.fileWriteFileExists.rawValue {
            continue
        }
    }
    throw CocoaError(.fileWriteFileExists)
}

private func sessionDirectoryName(for date: Date, timeZone: TimeZone) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd HH-mm-ss ZZZZZ"
    return formatter.string(from: date)
}

private func atomicWrite(_ data: Data, to url: URL) throws {
    let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    do {
        try data.write(to: temporary, options: .withoutOverwriting)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    } catch {
        try? FileManager.default.removeItem(at: temporary)
        throw error
    }
}

private extension Data {
    mutating func appendASCII(_ value: String) { append(value.data(using: .ascii)!) }
    mutating func appendUInt16(_ value: UInt16) { var value = value.bigEndian; Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) } }
    mutating func appendUInt32(_ value: UInt32) { var value = value.bigEndian; Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) } }
    mutating func appendInt64(_ value: Int64) { var value = UInt64(bitPattern: value).bigEndian; Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) } }
    mutating func appendDouble(_ value: Double) { var value = value.bitPattern.bigEndian; Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) } }
}
