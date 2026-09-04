import Foundation
import Testing
import ScribeAppCore
@testable import Processing

@Test func parsesEveryEventTheSessionStoreWrites() {
    let journal = CaptureJournal.parse("""
    {"event":"session-created","sessionID":"0E9EF1D0-6D4C-4B3E-9C86-7A2A2E2B0001"}
    {"event":"initial-timestamp","track":"microphone","timestampSeconds":207492.998875,"file":"microphone-0001.caf","fileFrameOffset":0,"format":{"sampleRate":48000,"channelCount":1,"bitsPerChannel":32,"isFloat":true}}
    {"event":"segment-opened","track":"microphone","file":"microphone-0001.caf","reason":"active"}
    {"event":"contiguous-run","track":"microphone","startedAtSeconds":207492.998875,"frameCount":512,"file":"microphone-0001.caf","fileFrameOffset":0}
    {"event":"gap","track":"microphone","startedAtSeconds":207493.01,"durationSeconds":0.25,"file":"microphone-0001.caf","fileFrameOffset":512}
    {"event":"overlap","track":"microphone","startedAtSeconds":207493.30,"durationSeconds":0.005,"file":"microphone-0001.caf","fileFrameOffset":1024}
    {"event":"format-change","track":"microphone","atSeconds":207494,"from":{"sampleRate":48000,"channelCount":1,"bitsPerChannel":32,"isFloat":true},"to":{"sampleRate":16000,"channelCount":1,"bitsPerChannel":16,"isFloat":false}}
    {"event":"segment-closed","track":"microphone","file":"microphone-0001.caf","reason":"finished","frameCount":2048,"dataByteCount":8192}
    {"event":"interruption","reason":"sleep"}
    {"event":"output-route-change","currentDeviceID":"LG","currentDeviceName":"LG Display"}
    {"event":"recovered-active-segments","files":["microphone-0002.caf"]}
    {"event":"checkpoint","track":"microphone","file":"microphone-0001.caf","dataByteCount":8192,"frameCount":2048}
    """)
    #expect(journal.records.count == 11)
    #expect(journal.malformedLines.isEmpty)
    // A checkpoint is not part of a reconstruction, so it is not reported as ignored.
    #expect(journal.unrecognized.isEmpty)
}

@Test func reportsEventsItDoesNotModelRatherThanDroppingThem() {
    let journal = CaptureJournal.parse("""
    {"event":"contiguous-run","track":"system","startedAtSeconds":1,"frameCount":480,"file":"system-0001.caf","fileFrameOffset":0}
    {"event":"a-future-event","track":"system"}
    {"event":"a-future-event","track":"system"}
    not json at all
    """)
    #expect(journal.records.count == 1)
    #expect(journal.unrecognized == ["a-future-event": 2])
    #expect(journal.malformedLines == [4])
}

@Test func prefersALosslessPresentationTimestampWhenTheJournalCarriesOne() {
    // The capture harness already writes CMTime as {value, timescale}. When that is
    // present it is used verbatim, with no quantization at all.
    let journal = CaptureJournal.parse("""
    {"event":"contiguous-run","track":"system","startedAtSeconds":0.5,"presentationTimestamp":{"value":1,"timescale":3},"frameCount":480,"file":"system-0001.caf","fileFrameOffset":0}
    """)
    guard case let .contiguousRun(_, timestamp, _, _, _) = journal.records[0] else {
        Issue.record("expected a contiguous run"); return
    }
    #expect(timestamp == RationalTime(value: 1, timescale: 3))
}

@Test func agapRecordDescribesTheIntervalBeforeTheBufferThatReportedIt() {
    let journal = CaptureJournal.parse("""
    {"event":"gap","track":"microphone","startedAtSeconds":2.0,"durationSeconds":0.25,"file":"microphone-0001.caf","fileFrameOffset":96000}
    """)
    guard case let .gap(track, startedAt, duration, file, offset) = journal.records[0] else {
        Issue.record("expected a gap"); return
    }
    #expect(track == .microphone)
    #expect(startedAt == RationalTime(seconds: 2))
    #expect(abs(duration.seconds - 0.25) < 1e-9)
    #expect(file == "microphone-0001.caf")
    #expect(offset == 96_000)
}
