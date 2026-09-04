import Foundation
import Processing

/// Writes a capture archive in the shape `SessionStore` produces, so the timeline
/// builder can be tested against inputs whose correct reconstruction is known.
///
/// It is deliberately a small, independent re-statement of the on-disk format
/// rather than a call into the recorder: a test that shared the writer with the
/// code under test could not catch the two of them drifting apart.
struct CaptureArchiveFixture {
    struct Format: Equatable {
        var sampleRate: Int
        var channelCount: Int = 1
        var bitsPerChannel: Int = 32
        var isFloat: Bool = true

        var bytesPerFrame: Int { (bitsPerChannel / 8) * channelCount }
        var journal: [String: Any] {
            ["sampleRate": sampleRate, "channelCount": channelCount, "bitsPerChannel": bitsPerChannel, "isFloat": isFloat, "interleaved": true, "description": "lpcm"]
        }
    }

    let sessionDirectory: URL
    let captureDirectory: URL
    private let segmentSeconds: Double

    private final class Box {
        var lines: [String] = []
        var open: [String: (file: String, format: Format, first: Double, frames: Int64, data: Data)] = [:]
        var numbers: [String: Int] = [:]
        var lastEnd: [String: Double] = [:]
    }
    private let box = Box()

    init(root: URL, name: String = "session", segmentSeconds: Double = 60) throws {
        sessionDirectory = root.appendingPathComponent(name, isDirectory: true)
        captureDirectory = sessionDirectory.appendingPathComponent("capture", isDirectory: true)
        self.segmentSeconds = segmentSeconds
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        append(["event": "session-created", "sessionID": UUID().uuidString])
    }

    func write(track: String, at timestamp: Double, samples: [Float], format: Format) throws {
        let frames = samples.count / format.channelCount
        if let active = box.open[track], active.format != format {
            append(["event": "format-change", "track": track, "from": active.format.journal, "to": format.journal, "atSeconds": timestamp])
        }
        let rotates = box.open[track].map { $0.format != format || (segmentSeconds > 0 && timestamp - $0.first >= segmentSeconds) } ?? false
        if box.open[track] == nil || rotates {
            try close(track: track, reason: rotates ? "rotation" : "initial")
            let number = (box.numbers[track] ?? 0) + 1
            box.numbers[track] = number
            let file = String(format: "%@-%04d.caf", track, number)
            box.open[track] = (file, format, timestamp, 0, Data())
            append(["event": "initial-timestamp", "track": track, "timestampSeconds": timestamp, "file": file, "fileFrameOffset": 0, "format": format.journal])
            append(["event": "segment-opened", "track": track, "file": file, "reason": "active", "format": format.journal])
        }
        guard var active = box.open[track] else { return }

        let expected = box.lastEnd[track] ?? timestamp
        let delta = timestamp - expected
        let tolerance = max(0.5 / Double(format.sampleRate), 1e-6)
        if delta > tolerance {
            append(["event": "gap", "track": track, "startedAtSeconds": expected, "durationSeconds": delta, "file": active.file, "fileFrameOffset": active.frames])
        } else if delta < -tolerance {
            append(["event": "overlap", "track": track, "startedAtSeconds": timestamp, "durationSeconds": -delta, "file": active.file, "fileFrameOffset": active.frames])
        } else {
            append(["event": "contiguous-run", "track": track, "startedAtSeconds": timestamp, "frameCount": frames, "file": active.file, "fileFrameOffset": active.frames])
        }

        for sample in samples { active.data.append(encode(sample, format: format)) }
        active.frames += Int64(frames)
        box.open[track] = active
        box.lastEnd[track] = timestamp + Double(frames) / Double(format.sampleRate)
    }

    func journal(_ object: [String: Any]) { append(object) }

    func finish() throws {
        for track in box.open.keys.sorted() { try close(track: track, reason: "finished") }
        append(["event": "session-writer-finished"])
        try Data((box.lines.joined(separator: "\n") + "\n").utf8)
            .write(to: captureDirectory.appendingPathComponent("timeline.jsonl"))
    }

    private func close(track: String, reason: String) throws {
        guard let active = box.open[track] else { return }
        var file = Data()
        file.appendASCII("caff"); file.appendBE(UInt16(1)); file.appendBE(UInt16(0))
        file.appendASCII("desc"); file.appendBE(Int64(32))
        file.appendBE(Int64(bitPattern: Double(active.format.sampleRate).bitPattern))
        file.appendASCII("lpcm")
        file.appendBE(UInt32(active.format.isFloat ? 0x3 : 0x2))
        file.appendBE(UInt32(active.format.bytesPerFrame))
        file.appendBE(UInt32(1))
        file.appendBE(UInt32(active.format.channelCount))
        file.appendBE(UInt32(active.format.bitsPerChannel))
        file.appendASCII("data"); file.appendBE(Int64(active.data.count) + 4); file.appendBE(UInt32(0))
        file.append(active.data)
        try file.write(to: captureDirectory.appendingPathComponent(active.file))
        append(["event": "segment-closed", "track": track, "file": active.file, "reason": reason, "frameCount": active.frames, "dataByteCount": Int64(active.data.count)])
        box.open[track] = nil
    }

    private func encode(_ sample: Float, format: Format) -> Data {
        var data = Data()
        switch (format.isFloat, format.bitsPerChannel) {
        case (false, 16):
            let value = Int16(max(-32_768, min(32_767, (Double(sample) * 32_768).rounded())))
            data.append(contentsOf: [UInt8(UInt16(bitPattern: value) & 0xFF), UInt8(UInt16(bitPattern: value) >> 8)])
        case (false, 24):
            let value = Int32(max(-8_388_608, min(8_388_607, (Double(sample) * 8_388_608).rounded())))
            let raw = UInt32(bitPattern: value)
            data.append(contentsOf: [UInt8(raw & 0xFF), UInt8((raw >> 8) & 0xFF), UInt8((raw >> 16) & 0xFF)])
        default:
            let raw = sample.bitPattern
            data.append(contentsOf: (0..<4).map { UInt8((raw >> (8 * UInt32($0))) & 0xFF) })
        }
        return data
    }

    private func append(_ object: [String: Any]) {
        var line = object
        line["journalVersion"] = 1
        line["wallClock"] = "2026-09-03T12:00:00Z"
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        box.lines.append(String(decoding: data, as: UTF8.self))
    }
}

private extension Data {
    mutating func appendASCII(_ value: String) { append(contentsOf: Array(value.utf8)) }
    mutating func appendBE(_ value: UInt16) { append(contentsOf: [UInt8(value >> 8), UInt8(value & 0xFF)]) }
    mutating func appendBE(_ value: UInt32) { append(contentsOf: (0..<4).reversed().map { UInt8((value >> (8 * UInt32($0))) & 0xFF) }) }
    mutating func appendBE(_ value: Int64) {
        let raw = UInt64(bitPattern: value)
        append(contentsOf: (0..<8).reversed().map { UInt8((raw >> (8 * UInt64($0))) & 0xFF) })
    }
}

/// A deterministic, broadband test signal. Not silence, so a misplaced run shows up.
///
/// Each sample is a pure function of its absolute position, so a signal generated
/// in chunks is identical to the same span generated in one call. Tests rely on
/// that to compare a reconstruction spanning several segments against the whole.
func testSignal(frames: Int, startingAt offset: Int = 0) -> [Float] {
    (0..<frames).map { index in
        let position = offset + index
        var hashed = UInt64(bitPattern: Int64(position)) &* 0x9E37_79B9_7F4A_7C15
        hashed ^= hashed >> 30; hashed = hashed &* 0xBF58_476D_1CE4_E5B9
        hashed ^= hashed >> 27; hashed = hashed &* 0x94D0_49BB_1331_11EB
        hashed ^= hashed >> 31
        let noise = Float(Int32(truncatingIfNeeded: hashed)) / Float(Int32.max) * 0.25
        return Float(sin(Double(position) * 0.037)) * 0.5 + noise
    }
}

func temporaryRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("processing-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A content digest of every file in a directory, used to prove the archive is
/// never written to by the processing pipeline.
func directoryDigest(_ url: URL) throws -> [String: Int] {
    var digest: [String: Int] = [:]
    let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
    for file in files {
        let data = try Data(contentsOf: file)
        digest[file.lastPathComponent] = data.reduce(into: 5381) { $0 = ($0 &* 33) &+ Int($1) }
    }
    return digest
}
