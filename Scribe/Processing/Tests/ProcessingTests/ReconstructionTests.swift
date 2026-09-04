import Foundation
import Testing
import ScribeAppCore
@testable import Processing

private let origin = 207_492.667875

@Test func theSourceArchiveIsNeverModified() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try CaptureArchiveFixture(root: root, segmentSeconds: 0.25)
    var frame = 0
    while frame < 48_000 {
        try archive.write(track: "microphone", at: origin + Double(frame) / 48_000,
                          samples: testSignal(frames: 512, startingAt: frame),
                          format: .init(sampleRate: 44_100))
        frame += 512
    }
    try archive.finish()

    let before = try directoryDigest(archive.captureDirectory)
    let builder = try TimelineBuilder.plan(sessionDirectory: archive.sessionDirectory)
    _ = try #require(try builder.makeReader(for: .microphone)).readAll()
    let after = try directoryDigest(archive.captureDirectory)
    #expect(before == after, "reconstruction must not write to capture/")
}

@Test func streamingInTenMillisecondBlocksMatchesReadingTheWholeTrack() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try CaptureArchiveFixture(root: root)
    // A rate conversion and a gap together, so the block boundaries land inside the
    // resampler's kernel context as well as across a silence boundary.
    var frame = 0
    while frame < 44_100 {
        let seconds = Double(frame) / 44_100
        if seconds >= 0.3 && seconds < 0.4 { frame = Int(0.4 * 44_100); continue }
        try archive.write(track: "microphone", at: origin + seconds,
                          samples: testSignal(frames: 441, startingAt: frame),
                          format: .init(sampleRate: 44_100))
        frame += 441
    }
    try archive.finish()

    let builder = try TimelineBuilder.plan(sessionDirectory: archive.sessionDirectory)
    let whole = try #require(try builder.makeReader(for: .microphone)).readAll()[0]

    let streamed = try #require(try builder.makeReader(for: .microphone))
    var blocks: [Float] = []
    var blockCount = 0
    while let block = try streamed.read(maxFrames: TimelineTrackReader.defaultBlockFrames) {
        #expect(block.frameCount <= TimelineTrackReader.defaultBlockFrames)
        #expect(block.startFrame == Int64(blocks.count))
        blocks.append(contentsOf: block.channels[0])
        blockCount += 1
    }
    #expect(blockCount > 90, "a one-second track should stream as many blocks, not one")
    #expect(blocks == whole)
}

@Test func integerArchivesBecomeFloatWorkingBuffersWithoutTouchingTheArchive() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try CaptureArchiveFixture(root: root)
    // Values that land exactly on 24-bit and 16-bit quantization steps, so the
    // conversion can be asserted exactly rather than within a tolerance.
    let samples: [Float] = [0, 0.5, -0.5, 0.25, -0.25, 0.125]
    try archive.write(track: "microphone", at: origin, samples: samples,
                      format: .init(sampleRate: 48_000, channelCount: 1, bitsPerChannel: 24, isFloat: false))
    try archive.finish()

    let builder = try TimelineBuilder.plan(sessionDirectory: archive.sessionDirectory)
    let audio = try #require(try builder.makeReader(for: .microphone)).readAll()[0]
    #expect(audio == samples)
    #expect(builder.timeline.track(.microphone)?.nativeFormat.isFloat == false)
}

@Test func aStereoArchiveKeepsItsChannelsSeparate() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try CaptureArchiveFixture(root: root)
    // Interleaved: left is the signal, right is its negation.
    let left = testSignal(frames: 480)
    var interleaved: [Float] = []
    for index in 0..<480 { interleaved.append(left[index]); interleaved.append(-left[index]) }
    try archive.write(track: "system", at: origin, samples: interleaved,
                      format: .init(sampleRate: 48_000, channelCount: 2))
    try archive.finish()

    let builder = try TimelineBuilder.plan(sessionDirectory: archive.sessionDirectory)
    let channels = try #require(try builder.makeReader(for: .system)).readAll()
    #expect(channels.count == 2)
    #expect(channels[0] == left)
    #expect(channels[1] == left.map { -$0 })
}

@Test func aTruncatedSegmentEndsItsRunRatherThanFabricatingSamples() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try CaptureArchiveFixture(root: root)
    try archive.write(track: "microphone", at: origin, samples: testSignal(frames: 4_800), format: .init(sampleRate: 48_000))
    try archive.finish()

    // Simulate a crash that left the file shorter than the journal's frame count.
    let segment = archive.captureDirectory.appendingPathComponent("microphone-0001.caf")
    let data = try Data(contentsOf: segment)
    try data.prefix(68 + 2_400 * 4).write(to: segment)

    let builder = try TimelineBuilder.plan(sessionDirectory: archive.sessionDirectory)
    let audio = try #require(try builder.makeReader(for: .microphone)).readAll()[0]
    #expect(audio.count == 2_400)
    #expect(audio == testSignal(frames: 2_400))
}

@Test func aMissingJournalIsReportedRatherThanGuessedAt() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = root.appendingPathComponent("empty", isDirectory: true)
    try FileManager.default.createDirectory(at: session.appendingPathComponent("capture"), withIntermediateDirectories: true)
    #expect(throws: TimelineBuilderError.self) {
        _ = try TimelineBuilder.plan(sessionDirectory: session)
    }
}
