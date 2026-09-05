import Foundation
import ScribeAppCore

/// One decoded line of `capture/timeline.jsonl`.
///
/// The journal is the recorder's durable account of what happened during capture,
/// and it is the only thing that authorizes the builder to insert silence. A line
/// the builder does not recognize is retained in ``CaptureJournal/unrecognized``
/// rather than dropped, so an added event type shows up as a diagnostic instead of
/// silently changing a reconstruction.
public enum CaptureJournalRecord: Sendable, Equatable {
    case sessionCreated(sessionID: UUID?)
    case initialTimestamp(track: RecorderTrackKind, timestamp: RationalTime, file: String, fileFrameOffset: Int64, format: CaptureAudioFormat?)
    case contiguousRun(track: RecorderTrackKind, timestamp: RationalTime, frameCount: Int64, file: String, fileFrameOffset: Int64)
    case gap(track: RecorderTrackKind, startedAt: RationalTime, duration: RationalTime, file: String?, fileFrameOffset: Int64?)
    case overlap(track: RecorderTrackKind, startedAt: RationalTime, duration: RationalTime, file: String?, fileFrameOffset: Int64?)
    case formatChange(track: RecorderTrackKind, at: RationalTime, from: CaptureAudioFormat?, to: CaptureAudioFormat?)
    case segmentOpened(track: RecorderTrackKind, file: String, format: CaptureAudioFormat?)
    case segmentClosed(track: RecorderTrackKind, file: String, reason: String, frameCount: Int64, dataByteCount: Int64)
    case interruption(reason: String)
    case outputRouteChange(currentDeviceID: String?, currentDeviceName: String?)
    case recoveredActiveSegments(files: [String])
}

/// A parsed capture journal.
public struct CaptureJournal: Sendable {
    public let records: [CaptureJournalRecord]
    /// Event names present in the file that this reader does not model, with counts.
    public let unrecognized: [String: Int]
    /// Lines that were not decodable JSON objects, by line number.
    public let malformedLines: [Int]

    public init(records: [CaptureJournalRecord], unrecognized: [String: Int] = [:], malformedLines: [Int] = []) {
        self.records = records
        self.unrecognized = unrecognized
        self.malformedLines = malformedLines
    }

    public static func read(contentsOf url: URL) throws -> CaptureJournal {
        parse(String(decoding: try Data(contentsOf: url), as: UTF8.self))
    }

    /// Event names that are legitimately not part of a timeline reconstruction, so
    /// their presence should not be reported as something the builder ignored.
    private static let uninterestingEvents: Set<String> = [
        "checkpoint", "session-writer-finished", "low-free-space",
        // A deliberate hold. The gap it produces is journaled separately and is
        // what authorizes the silence, so these two are diagnostics only.
        "capture-paused", "capture-resumed",
    ]

    public static func parse(_ text: String) -> CaptureJournal {
        var records: [CaptureJournalRecord] = []
        var unrecognized: [String: Int] = [:]
        var malformed: [Int] = []

        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let event = object["event"] as? String
            else {
                malformed.append(index + 1)
                continue
            }
            if let record = decode(event: event, object: object) {
                records.append(record)
            } else if !uninterestingEvents.contains(event) {
                unrecognized[event, default: 0] += 1
            }
        }
        return CaptureJournal(records: records, unrecognized: unrecognized, malformedLines: malformed)
    }

    private static func decode(event: String, object: [String: Any]) -> CaptureJournalRecord? {
        switch event {
        case "session-created":
            return .sessionCreated(sessionID: (object["sessionID"] as? String).flatMap(UUID.init(uuidString:)))
        case "initial-timestamp":
            guard let track = track(object), let timestamp = timestamp(object, keys: ["timestampSeconds", "startedAtSeconds"]) else { return nil }
            return .initialTimestamp(
                track: track,
                timestamp: timestamp,
                file: object["file"] as? String ?? "",
                fileFrameOffset: integer(object["fileFrameOffset"]) ?? 0,
                format: format(object["format"])
            )
        case "contiguous-run":
            guard let track = track(object), let timestamp = timestamp(object, keys: ["startedAtSeconds"]),
                  let frameCount = integer(object["frameCount"]) else { return nil }
            return .contiguousRun(
                track: track,
                timestamp: timestamp,
                frameCount: frameCount,
                file: object["file"] as? String ?? "",
                fileFrameOffset: integer(object["fileFrameOffset"]) ?? 0
            )
        case "gap", "overlap":
            guard let track = track(object), let startedAt = timestamp(object, keys: ["startedAtSeconds"]),
                  let seconds = number(object["durationSeconds"]) else { return nil }
            let duration = RationalTime(seconds: seconds)
            let file = object["file"] as? String
            let offset = integer(object["fileFrameOffset"])
            return event == "gap"
                ? .gap(track: track, startedAt: startedAt, duration: duration, file: file, fileFrameOffset: offset)
                : .overlap(track: track, startedAt: startedAt, duration: duration, file: file, fileFrameOffset: offset)
        case "format-change":
            guard let track = track(object), let at = timestamp(object, keys: ["atSeconds"]) else { return nil }
            return .formatChange(track: track, at: at, from: format(object["from"]), to: format(object["to"]))
        case "segment-opened":
            guard let track = track(object), let file = object["file"] as? String else { return nil }
            return .segmentOpened(track: track, file: file, format: format(object["format"]))
        case "segment-closed":
            guard let track = track(object), let file = object["file"] as? String else { return nil }
            return .segmentClosed(
                track: track,
                file: file,
                reason: object["reason"] as? String ?? "",
                frameCount: integer(object["frameCount"]) ?? 0,
                dataByteCount: integer(object["dataByteCount"]) ?? 0
            )
        case "interruption":
            return .interruption(reason: object["reason"] as? String ?? "")
        case "output-route-change":
            return .outputRouteChange(
                currentDeviceID: object["currentDeviceID"] as? String,
                currentDeviceName: object["currentDeviceName"] as? String
            )
        case "recovered-active-segments":
            return .recoveredActiveSegments(files: (object["files"] as? [String]) ?? [])
        default:
            return nil
        }
    }

    private static func track(_ object: [String: Any]) -> RecorderTrackKind? {
        (object["track"] as? String).flatMap(RecorderTrackKind.init(rawValue:))
    }

    /// Prefers a lossless `{value, timescale}` presentation timestamp — which the
    /// capture harness writes and the recorder may later adopt — and otherwise
    /// quantizes the `Double` seconds field the session store writes today.
    private static func timestamp(_ object: [String: Any], keys: [String]) -> RationalTime? {
        if let pts = object["presentationTimestamp"] as? [String: Any],
           let value = integer(pts["value"]), let timescale = integer(pts["timescale"]), timescale != 0 {
            return RationalTime(value: value, timescale: timescale)
        }
        for key in keys {
            if let seconds = number(object[key]) { return RationalTime(seconds: seconds) }
        }
        return nil
    }

    private static func format(_ raw: Any?) -> CaptureAudioFormat? {
        guard let object = raw as? [String: Any],
              let sampleRate = number(object["sampleRate"]),
              let channels = integer(object["channelCount"]),
              let bits = integer(object["bitsPerChannel"])
        else { return nil }
        return CaptureAudioFormat(
            sampleRate: Int(sampleRate.rounded()),
            channelCount: Int(channels),
            bitsPerChannel: Int(bits),
            isFloat: object["isFloat"] as? Bool ?? false
        )
    }

    private static func number(_ raw: Any?) -> Double? { (raw as? NSNumber)?.doubleValue }
    private static func integer(_ raw: Any?) -> Int64? { (raw as? NSNumber)?.int64Value }
}
