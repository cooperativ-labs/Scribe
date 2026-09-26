@preconcurrency import AVFoundation
import Foundation

public enum AudioPreparation {
    /// Decode incrementally with platform codecs; never loads a whole meeting into RAM.
    /// The first audio track is selected deliberately; unsupported/protected files fail visibly.
    public static func prepare(source: URL, destination: URL) async throws -> Double {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw MobileError.message("This file has no readable audio track.")
        }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, duration < Double(Int64.max / 128_000) else {
            throw MobileError.message("The recording has an invalid duration.")
        }
        try StorageCapacity.require(Int64(duration * 64_000) + StorageCapacity.recordingReserve, at: destination.deletingLastPathComponent())
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(output) else { throw MobileError.message("This audio format is not supported.") }
        reader.add(output)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let file = try AVAudioFile(forWriting: destination, settings: format.settings)
        try MeetingStore.protectAudio(destination)
        var completed = false
        defer { reader.cancelReading(); if !completed { try? FileManager.default.removeItem(at: destination) } }
        guard reader.startReading() else { throw reader.error ?? MobileError.message("Cannot decode this file.") }
        var frames: Int64 = 0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let block = CMSampleBufferGetDataBuffer(sample) else {
                    throw MobileError.message("The audio decoder returned no samples.")
                }
                let count = CMSampleBufferGetNumSamples(sample)
                guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                      let samples = buffer.floatChannelData?[0],
                      CMBlockBufferGetDataLength(block) == count * MemoryLayout<Float>.size else {
                    throw MobileError.message("The audio decoder returned an invalid buffer.")
                }
                buffer.frameLength = AVAudioFrameCount(count)
                guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 4, destination: samples) == noErr else {
                    throw MobileError.message("Cannot read decoded audio.")
                }
                try file.write(from: buffer); frames += Int64(count)
            }
        }
        try Task.checkCancellation()
        guard reader.status == .completed, frames > 0 else {
            throw reader.error ?? MobileError.message("The recording is empty or could not be decoded.")
        }
        completed = true
        return Double(frames) / 16_000
    }
}
