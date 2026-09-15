import Foundation
import Testing
import ScribeAppCore
@testable import Processing

@Test func energyTimelinePreservesOffsetsGapsAndPowerWithoutStereoCancellation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try CaptureArchiveFixture(root: root)
    // Both system channels are opposite: their mean power remains nonzero.
    try archive.write(track: "system", at: 100, samples: (0..<48_000).flatMap { _ in [Float(0.1), -0.1] },
                      format: .init(sampleRate: 48_000, channelCount: 2))
    try archive.write(track: "microphone", at: 100.2, samples: [Float](repeating: 0.2, count: 9_600), format: .init(sampleRate: 48_000))
    try archive.write(track: "microphone", at: 100.6, samples: [Float](repeating: 0.2, count: 19_200), format: .init(sampleRate: 48_000))
    try archive.finish()
    let builder = try TimelineBuilder.plan(sessionDirectory: archive.sessionDirectory)
    let timeline = try #require(try SourceEnergyPreparation.timeline(builder: builder))
    #expect(timeline.isValid)
    #expect(timeline.windows.count == 10)
    #expect(timeline.windows[0].bothTracksPresent == false)
    #expect(timeline.windows[4].bothTracksPresent == false)
    #expect(timeline.windows[7].bothTracksPresent)
    #expect(abs(timeline.windows[7].systemPower - 0.01) < 0.00001)
    #expect(abs(timeline.windows[7].microphonePower - 0.04) < 0.00001)
    #expect(!timeline.windows[7].microphoneDominant)
    #expect(try JSONDecoder().decode(SourceEnergyTimeline.self, from: JSONEncoder().encode(timeline)) == timeline)
}
