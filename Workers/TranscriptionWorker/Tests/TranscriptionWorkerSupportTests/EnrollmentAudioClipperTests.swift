@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import TranscriptionWorkerSupport

@Test("enrollment clipper writes only the selected time ranges")
func enrollmentClipperKeepsSelectedRanges() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "enrollment-clip-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let source = directory.appending(path: "source.wav")
    try writeSine(to: source, sampleRate: 16_000, seconds: 2)
    let clip = directory.appending(path: "clip.wav")
    let duration = try EnrollmentAudioClipper.writeClip(
        from: source,
        ranges: [
            AudioTimeRange(startSeconds: 0.25, endSeconds: 0.75),
            AudioTimeRange(startSeconds: 1.25, endSeconds: 1.75),
        ],
        to: clip
    )
    #expect(abs(duration - 1.0) < 0.03)
    let file = try AVAudioFile(forReading: clip)
    #expect(file.length > 0)
    #expect(abs(Double(file.length) / file.processingFormat.sampleRate - 1.0) < 0.03)
}

private func writeSine(to url: URL, sampleRate: Double, seconds: Double) throws {
    let format = try #require(
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
    )
    let frames = AVAudioFrameCount((seconds * sampleRate).rounded())
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let samples = try #require(buffer.floatChannelData?[0])
    for index in 0..<Int(frames) {
        samples[index] = sinf(2 * .pi * 220 * Float(index) / Float(sampleRate))
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
}
