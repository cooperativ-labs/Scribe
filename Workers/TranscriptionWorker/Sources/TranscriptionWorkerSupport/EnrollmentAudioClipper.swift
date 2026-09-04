@preconcurrency import AVFoundation
import Foundation

public struct AudioTimeRange: Sendable, Equatable {
    public let startSeconds: TimeInterval
    public let endSeconds: TimeInterval

    public init(startSeconds: TimeInterval, endSeconds: TimeInterval) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }

    public var duration: TimeInterval { max(0, endSeconds - startSeconds) }
}

public enum EnrollmentAudioClipper {
    public enum Error: Swift.Error, LocalizedError, Sendable, Equatable {
        case inputDoesNotExist(String)
        case emptySelection
        case invalidRange(start: TimeInterval, end: TimeInterval)
        case readFailed(String)

        public var errorDescription: String? {
            switch self {
            case let .inputDoesNotExist(path): "Enrollment clip source does not exist at \(path)."
            case .emptySelection: "Enrollment clip ranges are empty."
            case let .invalidRange(start, end): "Invalid enrollment range \(start)–\(end)."
            case let .readFailed(message): "Could not read enrollment audio: \(message)"
            }
        }
    }

    /// Writes a single contiguous clip of the selected ranges, preserving the
    /// source sample format. The diarizer converts to 16 kHz mono itself.
    public static func writeClip(
        from sourceURL: URL,
        ranges: [AudioTimeRange],
        to destinationURL: URL
    ) throws -> TimeInterval {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw Error.inputDoesNotExist(sourceURL.path)
        }
        let ordered = ranges.filter { $0.duration > 0 }
        guard !ordered.isEmpty else { throw Error.emptySelection }
        for range in ordered where range.endSeconds <= range.startSeconds {
            throw Error.invalidRange(start: range.startSeconds, end: range.endSeconds)
        }

        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: sourceURL)
        } catch {
            throw Error.readFailed(error.localizedDescription)
        }
        let format = input.processingFormat
        let sampleRate = format.sampleRate
        let sourceFrames = input.length
        var pieces: [AVAudioPCMBuffer] = []
        for range in ordered {
            let startFrame = max(0, AVAudioFramePosition((range.startSeconds * sampleRate).rounded(.down)))
            let endFrame = min(sourceFrames, AVAudioFramePosition((range.endSeconds * sampleRate).rounded(.up)))
            guard endFrame > startFrame else {
                throw Error.invalidRange(start: range.startSeconds, end: range.endSeconds)
            }
            input.framePosition = startFrame
            let count = AVAudioFrameCount(endFrame - startFrame)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else {
                throw Error.readFailed("Could not allocate an audio buffer.")
            }
            do {
                try input.read(into: buffer, frameCount: count)
            } catch {
                throw Error.readFailed(error.localizedDescription)
            }
            pieces.append(buffer)
        }

        let totalFrames = pieces.reduce(0) { $0 + Int($1.frameLength) }
        guard let combined = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrames)) else {
            throw Error.readFailed("Could not allocate the concatenated buffer.")
        }
        combined.frameLength = AVAudioFrameCount(totalFrames)
        var offset = 0
        for piece in pieces {
            copy(piece, into: combined, at: offset)
            offset += Int(piece.frameLength)
        }

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        let output = try AVAudioFile(forWriting: destinationURL, settings: format.settings)
        try output.write(from: combined)
        return Double(totalFrames) / sampleRate
    }

    private static func copy(_ source: AVAudioPCMBuffer, into destination: AVAudioPCMBuffer, at offset: Int) {
        let length = Int(source.frameLength)
        if let src = source.floatChannelData, let dst = destination.floatChannelData {
            for channel in 0..<Int(source.format.channelCount) {
                dst[channel].advanced(by: offset).update(from: src[channel], count: length)
            }
        } else if let src = source.int16ChannelData, let dst = destination.int16ChannelData {
            for channel in 0..<Int(source.format.channelCount) {
                dst[channel].advanced(by: offset).update(from: src[channel], count: length)
            }
        } else if let src = source.int32ChannelData, let dst = destination.int32ChannelData {
            for channel in 0..<Int(source.format.channelCount) {
                dst[channel].advanced(by: offset).update(from: src[channel], count: length)
            }
        }
    }
}
