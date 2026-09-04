import Foundation

enum JSONValue: Codable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    var numberValue: Double? { if case .number(let value) = self { value } else { nil } }
    var objectValue: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
}

struct JournalBuffer {
    let track: String
    let ptsSeconds: Double
    let frameCount: Int
    let sampleRate: Double?
    let formatDescription: String
    let clockDomain: String?
    let line: Int

    var duration: Double? {
        guard let sampleRate, sampleRate > 0, frameCount >= 0 else { return nil }
        return Double(frameCount) / sampleRate
    }
}

struct Gap: Codable, Sendable {
    let afterLine: Int
    let beforeLine: Int
    let seconds: Double
}

struct FormatChange: Codable, Sendable {
    let line: Int
    let previousFormat: String
    let newFormat: String
}

struct TrackReport: Codable, Sendable {
    let bufferCount: Int
    let initialTimestampSeconds: Double
    let finalTimestampSeconds: Double
    let deliveredFrames: Int
    let deliveredDurationSeconds: Double?
    let timestampSpanSeconds: Double?
    let driftSeconds: Double?
    let driftPPM: Double?
    let gaps: [Gap]
    let overlaps: [Gap]
    let formatChanges: [FormatChange]
    let formats: [String]
    let missingSampleRateBuffers: Int
}

struct InspectionReport: Codable, Sendable {
    let journal: String
    let parsedBuffers: Int
    let ignoredLines: Int
    let clockRelationship: String
    let timelineRule: String
    let tracks: [String: TrackReport]
    let warnings: [String]
}

enum InspectorError: LocalizedError {
    case unreadableJournal(String)
    case noAudioBuffers

    var errorDescription: String? {
        switch self {
        case .unreadableJournal(let message): return message
        case .noAudioBuffers: return "No .audio or .microphone buffer records were found."
        }
    }
}

enum TimestampInspector {
    static let trackedOutputs = Set(["audio", "microphone"])

    static func inspect(journalURL: URL) throws -> InspectionReport {
        let source: String
        do { source = try String(contentsOf: journalURL, encoding: .utf8) }
        catch { throw InspectorError.unreadableJournal("Cannot read \(journalURL.path): \(error.localizedDescription)") }

        var buffers: [JournalBuffer] = []
        var ignored = 0
        for (offset, line) in source.split(whereSeparator: \.isNewline).enumerated() {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let object = try? JSONDecoder().decode([String: JSONValue].self, from: Data(line.utf8)),
                  let buffer = parseBuffer(object, line: offset + 1) else {
                ignored += 1
                continue
            }
            buffers.append(buffer)
        }

        guard !buffers.isEmpty else { throw InspectorError.noAudioBuffers }
        let grouped = Dictionary(grouping: buffers, by: \.track)
        var reports: [String: TrackReport] = [:]
        var warnings: [String] = []
        for track in trackedOutputs.sorted() {
            guard let trackBuffers = grouped[track], !trackBuffers.isEmpty else {
                warnings.append("No .\(track) buffer records were found.")
                continue
            }
            reports[track] = makeTrackReport(trackBuffers)
        }

        let domains = Set(buffers.compactMap(\.clockDomain))
        let relationship: String
        if domains.count > 1 {
            relationship = "different declared clock domains (\(domains.sorted().joined(separator: ", "))); convert each timestamp through its declared Core Media clock relationship before comparison"
        } else if let domain = domains.first {
            relationship = "both tracks declare \(domain); compare presentation timestamps on that common timeline"
        } else {
            relationship = "not provable from this journal: CMTime values carry a time value and timescale, not an auditable clock identity; treat both as the stream presentation timeline only after the harness records a shared clock-domain declaration"
            warnings.append("clockDomain was absent. The inspector can compare numeric PTS values but cannot prove Core Media clock identity from JSONL alone.")
        }

        return InspectionReport(
            journal: journalURL.path,
            parsedBuffers: buffers.count,
            ignoredLines: ignored,
            clockRelationship: relationship,
            timelineRule: "Use each buffer's presentation timestamp (not callback arrival time) mapped with rational CMTime arithmetic to a session origin. Preserve each track's initial offset; insert silence only for documented positive gaps and retain overlaps for explicit resolution. Resample only a processing copy when measured timestamp/sample-count drift requires it.",
            tracks: reports,
            warnings: warnings
        )
    }

    private static func parseBuffer(_ object: [String: JSONValue], line: Int) -> JournalBuffer? {
        guard let rawTrack = firstString(object, keys: ["outputType", "output_type", "track", "type"]),
              let track = normalizedTrack(rawTrack), trackedOutputs.contains(track),
              let pts = timestamp(object),
              let frameCount = firstNumber(object, keys: ["frameCount", "frame_count", "frames", "sampleFrames"]).map(Int.init) else { return nil }
        let format = object["formatDescription"] ?? object["format_description"] ?? object["format"] ?? object["audioStreamBasicDescription"] ?? .null
        return JournalBuffer(
            track: track,
            ptsSeconds: pts,
            frameCount: frameCount,
            sampleRate: sampleRate(object["sampleRate"] ?? object["sample_rate"] ?? format),
            formatDescription: canonicalDescription(format),
            clockDomain: firstString(object, keys: ["clockDomain", "clock_domain"]),
            line: line
        )
    }

    private static func makeTrackReport(_ unordered: [JournalBuffer]) -> TrackReport {
        let buffers = unordered.sorted { $0.ptsSeconds == $1.ptsSeconds ? $0.line < $1.line : $0.ptsSeconds < $1.ptsSeconds }
        var gaps: [Gap] = [], overlaps: [Gap] = [], changes: [FormatChange] = []
        var deliveredFrames = 0, missingRate = 0
        var deliveredDuration = 0.0
        var previous = buffers[0]
        var formats = Set<String>([previous.formatDescription])
        if let duration = previous.duration { deliveredDuration += duration } else { missingRate += 1 }
        deliveredFrames += previous.frameCount

        for buffer in buffers.dropFirst() {
            deliveredFrames += buffer.frameCount
            if let duration = buffer.duration { deliveredDuration += duration } else { missingRate += 1 }
            if let priorDuration = previous.duration {
                let discontinuity = buffer.ptsSeconds - (previous.ptsSeconds + priorDuration)
                let tolerance = 1.0 / max(previous.sampleRate ?? 48_000, buffer.sampleRate ?? 48_000)
                if discontinuity > tolerance { gaps.append(Gap(afterLine: previous.line, beforeLine: buffer.line, seconds: discontinuity)) }
                if discontinuity < -tolerance { overlaps.append(Gap(afterLine: previous.line, beforeLine: buffer.line, seconds: discontinuity)) }
            }
            if buffer.formatDescription != previous.formatDescription {
                changes.append(FormatChange(line: buffer.line, previousFormat: previous.formatDescription, newFormat: buffer.formatDescription))
            }
            formats.insert(buffer.formatDescription)
            previous = buffer
        }
        let end = (previous.duration ?? 0) + previous.ptsSeconds
        let span = end - buffers[0].ptsSeconds
        let expected: Double? = missingRate == 0 ? deliveredDuration : nil
        let drift = expected.map { span - $0 }
        let driftPPM = drift.flatMap { drift in
            expected.flatMap { duration in
                duration > 0 ? drift / duration * 1_000_000 : nil
            }
        }
        return TrackReport(
            bufferCount: buffers.count,
            initialTimestampSeconds: buffers[0].ptsSeconds,
            finalTimestampSeconds: end,
            deliveredFrames: deliveredFrames,
            deliveredDurationSeconds: expected,
            timestampSpanSeconds: span,
            driftSeconds: drift,
            driftPPM: driftPPM,
            gaps: gaps,
            overlaps: overlaps,
            formatChanges: changes,
            formats: formats.sorted(),
            missingSampleRateBuffers: missingRate
        )
    }

    private static func normalizedTrack(_ value: String) -> String? {
        let lower = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower == "audio" || lower == ".audio" { return "audio" }
        if lower == "microphone" || lower == ".microphone" || lower == "mic" { return "microphone" }
        return nil
    }

    private static func timestamp(_ object: [String: JSONValue]) -> Double? {
        for key in ["presentationTimestamp", "presentation_timestamp", "pts", "timestamp"] {
            if let seconds = timestampSeconds(object[key]) { return seconds }
        }
        return firstNumber(object, keys: ["presentationTimestampSeconds", "presentation_timestamp_seconds", "ptsSeconds", "pts_seconds"])
    }

    private static func timestampSeconds(_ value: JSONValue?) -> Double? {
        guard let value else { return nil }
        if let number = value.numberValue { return number }
        if let string = value.stringValue {
            let parts = string.split(separator: "/", maxSplits: 1).map(String.init)
            if parts.count == 2, let numerator = Double(parts[0]), let denominator = Double(parts[1]), denominator != 0 { return numerator / denominator }
            return Double(string)
        }
        guard let object = value.objectValue,
              let rawValue = firstNumber(object, keys: ["value"]),
              let timescale = firstNumber(object, keys: ["timescale", "timeScale"]), timescale != 0 else { return nil }
        return rawValue / timescale
    }

    private static func sampleRate(_ value: JSONValue?) -> Double? {
        guard let value else { return nil }
        if let direct = value.numberValue { return direct > 0 ? direct : nil }
        guard let object = value.objectValue else { return nil }
        if let direct = firstNumber(object, keys: ["sampleRate", "sample_rate", "mSampleRate"]) { return direct > 0 ? direct : nil }
        for nested in object.values { if let rate = sampleRate(nested) { return rate } }
        return nil
    }

    private static func firstString(_ object: [String: JSONValue], keys: [String]) -> String? {
        for key in keys { if let value = object[key]?.stringValue { return value } }
        return nil
    }

    private static func firstNumber(_ object: [String: JSONValue], keys: [String]) -> Double? {
        for key in keys { if let value = object[key]?.numberValue { return value } }
        return nil
    }

    private static func canonicalDescription(_ value: JSONValue) -> String {
        if let string = value.stringValue { return string }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(data: (try? encoder.encode(value)) ?? Data("null".utf8), encoding: .utf8) ?? "null"
    }
}
