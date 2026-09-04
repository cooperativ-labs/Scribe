import AVFoundation
import Foundation

struct TrackSummary: Sendable {
    let bufferCount: Int
    let frames: Int64
    let firstPTSSeconds: Double?
    let lastPTSSeconds: Double?
    let segments: [String]
    let writeFailures: [String]
    let level: AudioLevel

    init(writer: TrackWriter) {
        level = writer.level
        bufferCount = writer.bufferCount
        frames = writer.totalFrames
        firstPTSSeconds = writer.firstPTSSeconds
        lastPTSSeconds = writer.lastPTSSeconds
        segments = writer.segments
        writeFailures = writer.writeFailures
    }

    var journalObject: [String: Any] {
        var object: [String: Any] = [
            "buffers": bufferCount,
            "frames": frames,
            "segments": segments,
            "writeFailures": writeFailures,
            "level": level.journalObject,
        ]
        if let firstPTSSeconds { object["firstPresentationTimestampSeconds"] = firstPTSSeconds }
        if let lastPTSSeconds { object["lastPresentationTimestampSeconds"] = lastPTSSeconds }
        return object
    }
}

struct CaptureReport: Sendable {
    let reason: StopReason
    let elapsedSeconds: Double
    let screenConsumer: ScreenConsumer
    let screenFramesDiscarded: Int
    let droppedUnparsedBuffers: Int
    let streamErrorMessage: String?
    let filterDescription: String
    let microphoneDescription: String
    let callbackThreads: [String]
    let system: TrackSummary
    let microphone: TrackSummary
    let selfCPU: ResourceSummary
    let daemonCPU: ResourceSummary?

    var manifest: [String: Any] {
        var object: [String: Any] = [
            "schemaVersion": 1,
            "tool": "capture-harness record",
            "stopReason": reason.rawValue,
            "elapsedSeconds": elapsedSeconds,
            "screenConsumer": screenConsumer.rawValue,
            "screenOutputRegistered": screenConsumer == .minimal,
            "screenFramesDiscarded": screenFramesDiscarded,
            "droppedUnparsedBuffers": droppedUnparsedBuffers,
            "filter": filterDescription,
            "microphone": microphoneDescription,
            "callbackThreads": callbackThreads,
            "tracks": ["audio": system.journalObject, "microphone": microphone.journalObject],
            "resourceUse": ["harness": selfCPU.journalObject],
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "finishedAt": Timestamp.iso8601(),
        ]
        if let streamErrorMessage { object["streamError"] = streamErrorMessage }
        if let daemonCPU {
            var resources = object["resourceUse"] as? [String: Any] ?? [:]
            resources["captureDaemon"] = daemonCPU.journalObject
            object["resourceUse"] = resources
        }
        return object
    }

    var humanSummary: String {
        var lines: [String] = []
        lines.append("Stop reason: \(reason.rawValue) after \(String(format: "%.1f", elapsedSeconds)) s")
        lines.append("Filter: \(filterDescription)")
        lines.append("Microphone: \(microphoneDescription)")
        lines.append("Screen consumer: \(screenConsumer.rawValue) (screen output registered: \(screenConsumer == .minimal); frames discarded: \(screenFramesDiscarded))")
        lines.append("Audio-only operation without a screen consumer: \(audioOnlyVerdict)")
        for (name, track) in [("audio", system), ("microphone", microphone)] {
            let first = track.firstPTSSeconds.map { String(format: "%.9f", $0) } ?? "none"
            lines.append(".\(name): \(track.bufferCount) buffers, \(track.frames) frames, first PTS \(first) s, level \(track.level.described), segments \(track.segments.joined(separator: ", "))")
            for failure in track.writeFailures { lines.append("  write failure: \(failure)") }
        }
        if droppedUnparsedBuffers > 0 { lines.append("Buffers the harness could not parse: \(droppedUnparsedBuffers)") }
        for thread in callbackThreads { lines.append("Callback thread \(thread)") }
        lines.append("CPU (harness process): \(selfCPU.described)")
        if let daemonCPU { lines.append("CPU (\(daemonCPU.process)): \(daemonCPU.described)") }
        if let streamErrorMessage { lines.append("Stream error: \(streamErrorMessage)") }
        return lines.joined(separator: "\n")
    }

    /// The explicit answer the objective asks for.
    var audioOnlyVerdict: String {
        let deliveredAudio = system.bufferCount > 0 || microphone.bufferCount > 0
        switch (screenConsumer, deliveredAudio) {
        case (.none, true):
            return "yes — the stream delivered audio with no .screen output registered"
        case (.none, false):
            return "no audio arrived and no .screen output was registered; rerun with --screen-consumer minimal to distinguish this from a permission or source problem"
        case (.minimal, true):
            return "not proven here — this run registered a minimal 2x2, 1 fps screen output and discarded its frames"
        case (.minimal, false):
            return "no audio arrived even with a minimal screen consumer; this is not an audio-only-configuration result"
        }
    }

}

enum MicrophoneCatalog {
    static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    static func describe(deviceID: String?) -> String {
        guard let deviceID else {
            let fallback = AVCaptureDevice.default(for: .audio)
            return "system default input\(fallback.map { " (\($0.localizedName), uid \($0.uniqueID))" } ?? "")"
        }
        if let match = devices().first(where: { $0.uniqueID == deviceID }) {
            return "\(match.localizedName) (uid \(match.uniqueID))"
        }
        return "requested uid \(deviceID) (not present in the current device list)"
    }
}
