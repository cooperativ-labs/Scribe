import AVFoundation
import Foundation

/// One delivered ScreenCaptureKit audio buffer, copied out of its backing
/// `CMSampleBuffer` so no no-copy pointer outlives the callback.
struct CapturedBuffer: @unchecked Sendable {
    let track: TrackKind
    let pcm: AVAudioPCMBuffer
    let format: AudioStreamBasicDescription
    let channelLayoutTag: AudioChannelLayoutTag?
    let ptsValue: Int64
    let ptsTimescale: Int32
    let frameCount: Int
    let sequence: Int
    /// Diagnostic only. Never used as a timing source.
    let callbackThread: String
    let callbackHostSeconds: Double
}

enum TrackKind: String, Sendable {
    case audio
    case microphone

    /// File stem used for the per-track CAF segments.
    var fileStem: String {
        switch self {
        case .audio: return "system"
        case .microphone: return "microphone"
        }
    }
}

/// Serialises one track to rotating CAF segments and appends its buffer records
/// to the shared JSONL journal. All work happens on the owning writer queue.
final class TrackWriter {
    private let track: TrackKind
    private let directory: URL
    private let journal: JournalWriter
    private let segmentSeconds: Double

    private var file: AVAudioFile?
    private var currentFormat: AudioStreamBasicDescription?
    private var segmentIndex = 0
    private var segmentName = ""
    private var segmentFirstPTS: Double?
    private var framesInSegment: Int64 = 0

    private(set) var totalFrames: Int64 = 0
    private(set) var bufferCount = 0
    private(set) var firstPTSSeconds: Double?
    private(set) var lastPTSSeconds: Double?
    private(set) var writeFailures: [String] = []
    private(set) var segments: [String] = []
    /// Running level for the whole track. Diagnostic only; see `AudioLevel`.
    private(set) var level = AudioLevel()

    init(track: TrackKind, directory: URL, journal: JournalWriter, segmentSeconds: Double) {
        self.track = track
        self.directory = directory
        self.journal = journal
        self.segmentSeconds = segmentSeconds
    }

    func write(_ buffer: CapturedBuffer) {
        let pts = Double(buffer.ptsValue) / Double(buffer.ptsTimescale)
        let formatChanged = currentFormat.map { !$0.matches(buffer.format) } ?? true
        let elapsed = segmentFirstPTS.map { pts - $0 } ?? 0
        let rotateForLength = segmentSeconds > 0 && elapsed >= segmentSeconds
        if formatChanged || rotateForLength || file == nil {
            rotate(to: buffer, at: pts, reason: formatChanged && bufferCount > 0 ? "format-change" : (rotateForLength ? "segment-length" : "start"))
        }

        let bufferLevel = AudioLevel.measure(buffer.pcm)
        level.accumulate(bufferLevel)

        let offsetInSegment = framesInSegment
        var writeError: String?
        do {
            try file?.write(from: buffer.pcm)
            framesInSegment += Int64(buffer.frameCount)
        } catch {
            writeError = error.localizedDescription
            writeFailures.append("\(track.rawValue) frame \(totalFrames): \(error.localizedDescription)")
        }

        totalFrames += Int64(buffer.frameCount)
        bufferCount += 1
        if firstPTSSeconds == nil { firstPTSSeconds = pts }
        lastPTSSeconds = pts

        journal.append(record(for: buffer, pts: pts, offsetInSegment: offsetInSegment, level: bufferLevel, writeError: writeError))
    }

    /// Journal record shaped for `capture-harness inspect`. `formatDescription`
    /// carries only format fields so it never reports a spurious format change.
    private func record(for buffer: CapturedBuffer, pts: Double, offsetInSegment: Int64, level: AudioLevel, writeError: String?) -> [String: Any] {
        var record: [String: Any] = [
            "record": "buffer",
            "outputType": buffer.track.rawValue,
            "sequence": buffer.sequence,
            "presentationTimestamp": ["value": buffer.ptsValue, "timescale": buffer.ptsTimescale],
            "presentationTimestampSeconds": pts,
            "frameCount": buffer.frameCount,
            "sampleRate": buffer.format.mSampleRate,
            "clockDomain": "SCStream.presentationTimeStamp",
            "formatDescription": buffer.format.journalObject(channelLayoutTag: buffer.channelLayoutTag),
            "file": segmentName,
            "fileFrameOffset": offsetInSegment,
            "callbackThread": buffer.callbackThread,
            "callbackHostSeconds": buffer.callbackHostSeconds,
            "peak": level.peak,
            "rms": level.rms,
        ]
        if let writeError { record["writeError"] = writeError }
        return record
    }

    private func rotate(to buffer: CapturedBuffer, at pts: Double, reason: String) {
        closeCurrentFile()
        segmentIndex += 1
        segmentName = String(format: "%@-%04d.caf", track.fileStem, segmentIndex)
        segmentFirstPTS = pts
        framesInSegment = 0
        currentFormat = buffer.format
        segments.append(segmentName)

        let url = directory.appendingPathComponent(segmentName)
        do {
            let format = buffer.pcm.format
            file = try AVAudioFile(
                forWriting: url,
                settings: format.settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
        } catch {
            file = nil
            writeFailures.append("cannot open \(segmentName): \(error.localizedDescription)")
        }

        var event: [String: Any] = [
            "record": "segment",
            "outputType": track.rawValue,
            "file": segmentName,
            "reason": reason,
            "firstPresentationTimestampSeconds": pts,
            "formatDescription": buffer.format.journalObject(channelLayoutTag: buffer.channelLayoutTag),
            "opened": file != nil,
        ]
        if let fileFormat = file?.fileFormat {
            // CAF cannot store non-interleaved linear PCM, so the archive holds the same
            // float samples interleaved. Journal the on-disk layout next to the delivered one.
            event["fileFormat"] = [
                "sampleRate": fileFormat.sampleRate,
                "channelCount": fileFormat.channelCount,
                "interleaved": fileFormat.isInterleaved,
                "commonFormat": fileFormat.commonFormat.rawValue,
            ]
        }
        journal.appendEvent(event)
    }

    private func closeCurrentFile() {
        file = nil
    }

    func finish() {
        closeCurrentFile()
    }
}

extension AudioStreamBasicDescription {
    func matches(_ other: AudioStreamBasicDescription) -> Bool {
        mSampleRate == other.mSampleRate
            && mFormatID == other.mFormatID
            && mFormatFlags == other.mFormatFlags
            && mBytesPerPacket == other.mBytesPerPacket
            && mFramesPerPacket == other.mFramesPerPacket
            && mBytesPerFrame == other.mBytesPerFrame
            && mChannelsPerFrame == other.mChannelsPerFrame
            && mBitsPerChannel == other.mBitsPerChannel
    }

    /// The full stream description, as required by the objective, plus decoded
    /// flag names and the channel layout tag when one is present.
    func journalObject(channelLayoutTag: AudioChannelLayoutTag?) -> [String: Any] {
        var object: [String: Any] = [
            "mSampleRate": mSampleRate,
            "mFormatID": mFormatID,
            "mFormatIDString": fourCharacterString(mFormatID),
            "mFormatFlags": mFormatFlags,
            "mFormatFlagNames": formatFlagNames,
            "mBytesPerPacket": mBytesPerPacket,
            "mFramesPerPacket": mFramesPerPacket,
            "mBytesPerFrame": mBytesPerFrame,
            "mChannelsPerFrame": mChannelsPerFrame,
            "mBitsPerChannel": mBitsPerChannel,
        ]
        if let channelLayoutTag {
            object["channelLayoutTag"] = channelLayoutTag
        }
        return object
    }

    private var formatFlagNames: [String] {
        var names: [String] = []
        if mFormatFlags & kAudioFormatFlagIsFloat != 0 { names.append("Float") }
        if mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 { names.append("SignedInteger") }
        if mFormatFlags & kAudioFormatFlagIsBigEndian != 0 { names.append("BigEndian") }
        if mFormatFlags & kAudioFormatFlagIsPacked != 0 { names.append("Packed") }
        if mFormatFlags & kAudioFormatFlagIsAlignedHigh != 0 { names.append("AlignedHigh") }
        if mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 { names.append("NonInterleaved") }
        if mFormatFlags & kAudioFormatFlagIsNonMixable != 0 { names.append("NonMixable") }
        return names
    }
}

func fourCharacterString(_ value: UInt32) -> String {
    let bytes = [
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8(value & 0xFF),
    ]
    return String(bytes: bytes, encoding: .ascii) ?? String(value)
}
