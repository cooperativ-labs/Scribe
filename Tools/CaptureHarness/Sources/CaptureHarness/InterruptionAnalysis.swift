import Foundation

/// One buffer, reduced to what marker correlation needs.
struct CorrelationBuffer: Sendable {
    let track: String
    let hostSeconds: Double
    let ptsSeconds: Double
    let frameCount: Int
    let sampleRate: Double
    let format: String
    let peak: Double

    var endPTSSeconds: Double { sampleRate > 0 ? ptsSeconds + Double(frameCount) / sampleRate : ptsSeconds }
}

/// What the stream did around one system event, per track.
struct MarkerTrackOutcome: Codable, Sendable {
    let track: String
    let buffersBefore: Int
    let buffersAfter: Int
    /// Presentation-timestamp discontinuity measured across the marker: the first
    /// timestamp after it minus the end of the last buffer before it.
    let ptsGapSeconds: Double?
    let formatChanged: Bool
    let formatBefore: String?
    let formatAfter: String?
    let sampleRateBefore: Double?
    let sampleRateAfter: Double?
    /// Wall-clock-free statement of behaviour, in the vocabulary the plan uses.
    let behaviour: String

    var journalObject: [String: Any] {
        var object: [String: Any] = [
            "track": track,
            "buffersBefore": buffersBefore,
            "buffersAfter": buffersAfter,
            "formatChanged": formatChanged,
            "behaviour": behaviour,
        ]
        if let ptsGapSeconds { object["ptsGapSeconds"] = ptsGapSeconds }
        if let formatBefore { object["formatBefore"] = formatBefore }
        if let formatAfter { object["formatAfter"] = formatAfter }
        if let sampleRateBefore { object["sampleRateBefore"] = sampleRateBefore }
        if let sampleRateAfter { object["sampleRateAfter"] = sampleRateAfter }
        return object
    }
}

struct MarkerOutcome: Sendable {
    let event: String
    let detail: String
    let wallClock: String
    let tracks: [MarkerTrackOutcome]

    var journalObject: [String: Any] {
        [
            "event": event,
            "detail": detail,
            "wallClock": wallClock,
            "tracks": tracks.map(\.journalObject),
        ]
    }

    var described: String {
        let parts = tracks.map { "\($0.track): \($0.behaviour)" }.joined(separator: "; ")
        return "\(wallClock)  \(event) — \(detail)\n    \(parts)"
    }
}

enum InterruptionAnalysis {
    /// Threshold above which a presentation-timestamp discontinuity is reported as a gap
    /// rather than ordinary buffer jitter. One 10 ms processing block is the alignment unit
    /// the validation gates in section 8 are written in.
    static let gapThresholdSeconds = 0.010

    static func buffers(inTimeline url: URL) throws -> [CorrelationBuffer] {
        let source = try String(contentsOf: url, encoding: .utf8)
        var result: [CorrelationBuffer] = []
        for line in source.split(whereSeparator: \.isNewline) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty,
                  let object = try? JSONDecoder().decode([String: JSONValue].self, from: Data(line.utf8)),
                  object["record"]?.stringValue == "buffer",
                  let track = object["outputType"]?.stringValue,
                  TimestampInspector.trackedOutputs.contains(track),
                  let hostSeconds = object["callbackHostSeconds"]?.numberValue,
                  let pts = object["presentationTimestampSeconds"]?.numberValue,
                  let frames = object["frameCount"]?.numberValue else { continue }
            let sampleRate = object["sampleRate"]?.numberValue ?? 0
            let format = object["formatDescription"].map(describeFormat) ?? "unknown"
            result.append(CorrelationBuffer(
                track: track,
                hostSeconds: hostSeconds,
                ptsSeconds: pts,
                frameCount: Int(frames),
                sampleRate: sampleRate,
                format: format,
                peak: object["peak"]?.numberValue ?? 0
            ))
        }
        return result.sorted { $0.hostSeconds < $1.hostSeconds }
    }

    static func markers(inEvents url: URL) throws -> [InterruptionMarker] {
        let source = try String(contentsOf: url, encoding: .utf8)
        var result: [InterruptionMarker] = []
        for line in source.split(whereSeparator: \.isNewline) {
            guard let object = try? JSONDecoder().decode([String: JSONValue].self, from: Data(line.utf8)),
                  object["record"]?.stringValue == "interruption",
                  let event = object["event"]?.stringValue,
                  let hostSeconds = object["hostSeconds"]?.numberValue else { continue }
            result.append(InterruptionMarker(
                name: event,
                detail: object["detail"]?.stringValue ?? "",
                hostSeconds: hostSeconds,
                wallClock: object["markerWallClock"]?.stringValue ?? object["wallClock"]?.stringValue ?? ""
            ))
        }
        return result
    }

    /// Places each marker against the buffer stream. `callbackHostSeconds` is used here as a
    /// diagnostic index only — to locate roughly where in the stream an external OS event
    /// happened — never as the timing source for the audio timeline itself.
    static func correlate(markers: [InterruptionMarker], buffers: [CorrelationBuffer]) -> [MarkerOutcome] {
        let tracks = Array(Set(buffers.map(\.track))).sorted()
        return markers.map { marker in
            let outcomes = tracks.map { track -> MarkerTrackOutcome in
                let ofTrack = buffers.filter { $0.track == track }
                let before = ofTrack.last { $0.hostSeconds <= marker.hostSeconds }
                let after = ofTrack.first { $0.hostSeconds > marker.hostSeconds }
                let countBefore = ofTrack.count { $0.hostSeconds <= marker.hostSeconds }
                let countAfter = ofTrack.count - countBefore
                let gap = (before != nil && after != nil) ? after!.ptsSeconds - before!.endPTSSeconds : nil
                let formatChanged = before != nil && after != nil && before!.format != after!.format
                return MarkerTrackOutcome(
                    track: track,
                    buffersBefore: countBefore,
                    buffersAfter: countAfter,
                    ptsGapSeconds: gap,
                    formatChanged: formatChanged,
                    formatBefore: before?.format,
                    formatAfter: after?.format,
                    sampleRateBefore: before?.sampleRate,
                    sampleRateAfter: after?.sampleRate,
                    behaviour: behaviour(countBefore: countBefore, countAfter: countAfter, gap: gap, formatChanged: formatChanged)
                )
            }
            return MarkerOutcome(event: marker.name, detail: marker.detail, wallClock: marker.wallClock, tracks: outcomes)
        }
    }

    static func behaviour(countBefore: Int, countAfter: Int, gap: Double?, formatChanged: Bool) -> String {
        if countBefore == 0 { return "no buffers had arrived yet when this event happened" }
        if countAfter == 0 { return "stopped — no further buffers arrived after this event" }
        var parts: [String] = []
        if let gap, gap > gapThresholdSeconds {
            parts.append(String(format: "continued after a %.3f s presentation-timestamp gap", gap))
        } else if let gap, gap < -gapThresholdSeconds {
            parts.append(String(format: "continued with a %.3f s overlap", -gap))
        } else {
            parts.append("continued with no timestamp discontinuity")
        }
        if formatChanged { parts.append("format changed") }
        return parts.joined(separator: ", ")
    }

    private static func describeFormat(_ value: JSONValue) -> String {
        guard let object = value.objectValue else { return "unknown" }
        let rate = object["mSampleRate"]?.numberValue ?? 0
        let channels = object["mChannelsPerFrame"]?.numberValue ?? 0
        let bits = object["mBitsPerChannel"]?.numberValue ?? 0
        let flags = object["mFormatFlags"]?.numberValue ?? 0
        let identifier = object["mFormatIDString"]?.stringValue ?? ""
        return "\(identifier) \(Int(rate)) Hz \(Int(channels)) ch \(Int(bits)) bit flags \(Int(flags))"
    }
}
