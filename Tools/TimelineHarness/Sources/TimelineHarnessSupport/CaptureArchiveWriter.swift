import Foundation
import Processing

/// Writes a capture archive in exactly the on-disk shape `SessionStore` produces:
/// interleaved linear-PCM CAF segments beside a `capture/timeline.jsonl` journal.
///
/// This exists so the timeline builder can be exercised on inputs whose correct
/// reconstruction is known in advance — the synthetic fixture suite, and the
/// deliberate gap, overlap, drift, rotation and rate cases the plan calls for.
/// It is a harness, not a second recorder: nothing in the app writes through it.
public final class CaptureArchiveWriter {
    public struct BufferSpec: Sendable {
        public let track: String
        /// Presentation timestamp in seconds, on the session's media clock.
        public let timestampSeconds: Double
        public let channels: [[Float]]
        public let format: ArchiveFormat

        public init(track: String, timestampSeconds: Double, channels: [[Float]], format: ArchiveFormat) {
            self.track = track
            self.timestampSeconds = timestampSeconds
            self.channels = channels
            self.format = format
        }

        public var frameCount: Int { channels.first?.count ?? 0 }
    }

    public struct ArchiveFormat: Sendable, Equatable {
        public let sampleRate: Int
        public let channelCount: Int
        public let bitsPerChannel: Int
        public let isFloat: Bool

        public init(sampleRate: Int, channelCount: Int, bitsPerChannel: Int = 32, isFloat: Bool = true) {
            self.sampleRate = sampleRate
            self.channelCount = channelCount
            self.bitsPerChannel = bitsPerChannel
            self.isFloat = isFloat
        }

        var bytesPerFrame: Int { (bitsPerChannel / 8) * channelCount }
        var journalObject: [String: Any] {
            ["sampleRate": sampleRate, "channelCount": channelCount, "bitsPerChannel": bitsPerChannel, "isFloat": isFloat, "interleaved": true, "description": "lpcm \(sampleRate) \(channelCount)ch"]
        }
    }

    public let sessionDirectory: URL
    public let captureDirectory: URL
    private let segmentSeconds: Double
    private var journalLines: [String] = []

    private struct Segment {
        let file: String
        let format: ArchiveFormat
        let firstTimestamp: Double
        var frameCount: Int64 = 0
        var data = Data()
    }
    private var segments: [String: Segment] = [:]
    private var segmentNumbers: [String: Int] = [:]
    private var lastEnd: [String: Double] = [:]

    public init(sessionDirectory: URL, segmentSeconds: Double = 60) throws {
        self.sessionDirectory = sessionDirectory
        self.captureDirectory = sessionDirectory.appendingPathComponent("capture", isDirectory: true)
        self.segmentSeconds = segmentSeconds
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        append(["event": "session-created", "sessionID": UUID().uuidString])
    }

    /// Mirrors `SessionStore.append`: rotate on format change or the bounded
    /// interval, journal the discontinuity class, then write the PCM.
    public func write(_ buffer: BufferSpec) throws {
        let track = buffer.track
        var needsRotation = false
        if let active = segments[track] {
            needsRotation = active.format != buffer.format
                || (segmentSeconds > 0 && buffer.timestampSeconds - active.firstTimestamp >= segmentSeconds)
            if active.format != buffer.format {
                append(["event": "format-change", "track": track, "from": active.format.journalObject, "to": buffer.format.journalObject, "atSeconds": buffer.timestampSeconds])
            }
        }
        if segments[track] == nil || needsRotation {
            try closeSegment(track: track, reason: needsRotation ? "format-change" : "initial")
            openSegment(track: track, buffer: buffer)
        }
        guard var segment = segments[track] else { return }

        let expected = lastEnd[track] ?? buffer.timestampSeconds
        let delta = buffer.timestampSeconds - expected
        let tolerance = max(0.5 / Double(buffer.format.sampleRate), 0.000_001)
        if delta > tolerance {
            append(["event": "gap", "track": track, "startedAtSeconds": expected, "durationSeconds": delta, "file": segment.file, "fileFrameOffset": segment.frameCount])
        } else if delta < -tolerance {
            append(["event": "overlap", "track": track, "startedAtSeconds": buffer.timestampSeconds, "durationSeconds": -delta, "file": segment.file, "fileFrameOffset": segment.frameCount])
        } else {
            append(["event": "contiguous-run", "track": track, "startedAtSeconds": buffer.timestampSeconds, "frameCount": buffer.frameCount, "file": segment.file, "fileFrameOffset": segment.frameCount])
        }

        segment.data.append(interleave(buffer))
        segment.frameCount += Int64(buffer.frameCount)
        segments[track] = segment
        lastEnd[track] = buffer.timestampSeconds + Double(buffer.frameCount) / Double(buffer.format.sampleRate)
    }

    public func journal(_ object: [String: Any]) { append(object) }

    public func finish() throws {
        for track in segments.keys.sorted() { try closeSegment(track: track, reason: "finished") }
        append(["event": "session-writer-finished"])
        let text = journalLines.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: captureDirectory.appendingPathComponent("timeline.jsonl"))
    }

    private func openSegment(track: String, buffer: BufferSpec) {
        let number = (segmentNumbers[track] ?? 0) + 1
        segmentNumbers[track] = number
        let file = String(format: "%@-%04d.caf", track, number)
        segments[track] = Segment(file: file, format: buffer.format, firstTimestamp: buffer.timestampSeconds)
        append(["event": "initial-timestamp", "track": track, "timestampSeconds": buffer.timestampSeconds, "file": file, "fileFrameOffset": 0, "format": buffer.format.journalObject])
        append(["event": "segment-opened", "track": track, "file": file, "reason": "active", "format": buffer.format.journalObject])
    }

    private func closeSegment(track: String, reason: String) throws {
        guard let segment = segments[track] else { return }
        var file = Data()
        Self.appendCAFHeader(format: segment.format, to: &file, dataByteCount: Int64(segment.data.count))
        file.append(segment.data)
        try file.write(to: captureDirectory.appendingPathComponent(segment.file))
        append(["event": "segment-closed", "track": track, "file": segment.file, "reason": reason, "frameCount": segment.frameCount, "dataByteCount": Int64(segment.data.count)])
        segments[track] = nil
    }

    private func interleave(_ buffer: BufferSpec) -> Data {
        var data = Data(capacity: buffer.frameCount * buffer.format.bytesPerFrame)
        for frame in 0..<buffer.frameCount {
            for channel in 0..<buffer.format.channelCount {
                let value = buffer.channels[min(channel, buffer.channels.count - 1)][frame]
                switch (buffer.format.isFloat, buffer.format.bitsPerChannel) {
                case (true, 32):
                    data.appendUInt32LE(value.bitPattern)
                case (false, 16):
                    let clamped = Int16(max(-32_768, min(32_767, (Double(value) * 32_768).rounded())))
                    data.appendUInt16LE(UInt16(bitPattern: clamped))
                case (false, 24):
                    let clamped = Int32(max(-8_388_608, min(8_388_607, (Double(value) * 8_388_608).rounded())))
                    let raw = UInt32(bitPattern: clamped)
                    data.append(contentsOf: [UInt8(raw & 0xFF), UInt8((raw >> 8) & 0xFF), UInt8((raw >> 16) & 0xFF)])
                default:
                    data.appendUInt32LE(value.bitPattern)
                }
            }
        }
        return data
    }

    private func append(_ object: [String: Any]) {
        var line = object
        line["journalVersion"] = 1
        line["wallClock"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        journalLines.append(String(decoding: data, as: UTF8.self))
    }

    /// The CAF layout `SessionStore` writes: a 32-byte `desc` chunk followed by a
    /// `data` chunk whose first four bytes are the edit count.
    private static func appendCAFHeader(format: ArchiveFormat, to data: inout Data, dataByteCount: Int64) {
        data.appendASCII("caff"); data.appendUInt16BE(1); data.appendUInt16BE(0)
        data.appendASCII("desc"); data.appendInt64BE(32)
        data.appendDoubleBE(Double(format.sampleRate))
        data.appendASCII("lpcm")
        var flags: UInt32 = 1 << 1
        if format.isFloat { flags |= 1 }
        data.appendUInt32BE(flags)
        data.appendUInt32BE(UInt32(format.bytesPerFrame))
        data.appendUInt32BE(1)
        data.appendUInt32BE(UInt32(format.channelCount))
        data.appendUInt32BE(UInt32(format.bitsPerChannel))
        data.appendASCII("data"); data.appendInt64BE(dataByteCount + 4); data.appendUInt32BE(0)
    }
}

extension Data {
    mutating func appendUInt16BE(_ value: UInt16) { append(contentsOf: [UInt8(value >> 8), UInt8(value & 0xFF)]) }
    mutating func appendUInt32BE(_ value: UInt32) {
        append(contentsOf: (0..<4).reversed().map { UInt8((value >> (8 * UInt32($0))) & 0xFF) })
    }
    mutating func appendInt64BE(_ value: Int64) {
        let raw = UInt64(bitPattern: value)
        append(contentsOf: (0..<8).reversed().map { UInt8((raw >> (8 * UInt64($0))) & 0xFF) })
    }
    mutating func appendDoubleBE(_ value: Double) { appendInt64BE(Int64(bitPattern: value.bitPattern)) }
}
