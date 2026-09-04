import Foundation
import Testing
@testable import CaptureHarness

@Test func identifiesDriftGapOverlapAndFormatChange() throws {
    let journal = """
    {"outputType":"audio","presentationTimestamp":{"value":0,"timescale":48000},"frameCount":480,"formatDescription":{"mSampleRate":48000,"mChannelsPerFrame":2},"clockDomain":"SCStream.presentationTimeStamp"}
    {"outputType":"microphone","presentationTimestamp":{"value":0,"timescale":48000},"frameCount":480,"formatDescription":{"mSampleRate":48000,"mChannelsPerFrame":1},"clockDomain":"SCStream.presentationTimeStamp"}
    {"outputType":"audio","presentationTimestamp":"960/48000","frameCount":480,"formatDescription":{"mSampleRate":48000,"mChannelsPerFrame":2},"clockDomain":"SCStream.presentationTimeStamp"}
    {"outputType":"audio","presentationTimestamp":0.025,"frameCount":480,"formatDescription":{"mSampleRate":44100,"mChannelsPerFrame":2},"clockDomain":"SCStream.presentationTimeStamp"}
    {"outputType":"audio","presentationTimestamp":0.035884354,"frameCount":480,"formatDescription":{"mSampleRate":44100,"mChannelsPerFrame":2},"clockDomain":"SCStream.presentationTimeStamp"}
    """
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".jsonl")
    try journal.write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }

    let report = try TimestampInspector.inspect(journalURL: url)
    let audio = try #require(report.tracks["audio"])
    #expect(audio.gaps.count == 1)
    #expect(audio.overlaps.count == 1)
    #expect(audio.formatChanges.count == 1)
    #expect(report.clockRelationship.contains("common timeline"))
}
