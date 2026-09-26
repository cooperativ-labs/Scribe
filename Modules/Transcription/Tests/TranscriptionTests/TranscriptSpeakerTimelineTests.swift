import XCTest
@testable import Transcription

final class TranscriptSpeakerTimelineTests: XCTestCase {
    func testSpansCoverSourceWithSpeakerColoursAndNeutralGaps() {
        let spans = TranscriptSpeakerTimeline.spans(durationMs: 10_000, segments: [
            segment("second", speaker: "b", start: 5_000, end: 8_000),
            segment("first", speaker: "a", start: 1_000, end: 4_000),
        ])

        XCTAssertEqual(spans.map(\.durationMs), [1_000, 3_000, 1_000, 3_000, 2_000])
        XCTAssertEqual(spans.map(\.speakerID), [nil, "a", nil, "b", nil])
        XCTAssertEqual(spans.reduce(0) { $0 + $1.durationMs }, 10_000)
        XCTAssertEqual(spans.first?.startMs, 0)
        XCTAssertEqual(spans.last?.endMs, 10_000)
    }

    func testOverlapsAndOutOfBoundsTimesStillPartitionExactDuration() {
        let spans = TranscriptSpeakerTimeline.spans(durationMs: 6_000, segments: [
            segment("a", speaker: "a", start: -500, end: 3_000),
            segment("b", speaker: "b", start: 2_000, end: 5_000),
            segment("c", speaker: "c", start: 5_000, end: 9_000),
        ])

        XCTAssertEqual(spans.map(\.durationMs), [3_000, 2_000, 1_000])
        XCTAssertEqual(spans.map(\.speakerID), ["a", "b", "c"])
        XCTAssertEqual(spans.reduce(0) { $0 + $1.durationMs }, 6_000)
        XCTAssertTrue(zip(spans, spans.dropFirst()).allSatisfy { $0.endMs == $1.startMs })
    }

    func testEmptyTimelineIsNeutralAndZeroDurationHasNoWidths() {
        XCTAssertEqual(TranscriptSpeakerTimeline.spans(durationMs: 4_000, segments: []), [
            .init(startMs: 0, endMs: 4_000, speakerID: nil)
        ])
        XCTAssertTrue(TranscriptSpeakerTimeline.spans(durationMs: 0, segments: []).isEmpty)
    }

    func testTransportReadoutUsesHoursOnlyForLongSources() {
        XCTAssertEqual(TranscriptSpeakerTimeline.timeLabel(61_999, includeHours: false), "1:01")
        XCTAssertEqual(TranscriptSpeakerTimeline.timeLabel(3_661_999, includeHours: true), "1:01:01")
    }

    private func segment(_ id: String, speaker: String?, start: Int, end: Int) -> TranscriptSegment {
        TranscriptSegment(
            id: id, speakerID: speaker, speakerLabel: speaker ?? "Unknown",
            startMs: start, endMs: end, text: "Test", overlap: false,
            timingQuality: .asrWord
        )
    }
}
