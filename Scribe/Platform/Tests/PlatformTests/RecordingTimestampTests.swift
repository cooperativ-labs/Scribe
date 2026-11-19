import Foundation
import Platform
import XCTest

final class RecordingTimestampTests: XCTestCase {
    func testElapsedTextUsesMinutesUntilAnHourThenAddsHours() {
        XCTAssertEqual(RecordingTimestamp.elapsedText(0), "00:00")
        XCTAssertEqual(RecordingTimestamp.elapsedText(83), "01:23")
        XCTAssertEqual(RecordingTimestamp.elapsedText(3_723), "1:02:03")
    }

    func testPastableTextFollowsTheRecordingClock() {
        let start = Date(timeIntervalSince1970: 1_000)
        let activity = RecordingActivity(sessionID: UUID(), startedAt: start)

        XCTAssertEqual(
            RecordingTimestamp.pastableText(state: .recording(activity), at: start.addingTimeInterval(83)),
            "at 01:23"
        )
        XCTAssertEqual(
            RecordingTimestamp.pastableText(state: .paused(activity), at: start.addingTimeInterval(83)),
            "at 01:23"
        )
        XCTAssertEqual(RecordingTimestamp.pastableText(state: .starting, at: start), "at 00:00")
        XCTAssertNil(RecordingTimestamp.pastableText(state: .idle, at: start))
        XCTAssertNil(RecordingTimestamp.pastableText(state: .stopping, at: start))
    }

    func testPastableTextSubtractsOffsetAndFloorsAtZero() {
        let start = Date(timeIntervalSince1970: 1_000)
        let activity = RecordingActivity(sessionID: UUID(), startedAt: start)

        XCTAssertEqual(
            RecordingTimestamp.pastableText(state: .recording(activity), at: start.addingTimeInterval(83), offset: 30),
            "at 00:53"
        )
        XCTAssertEqual(
            RecordingTimestamp.pastableText(state: .recording(activity), at: start.addingTimeInterval(10), offset: 30),
            "at 00:00"
        )
    }

    func testNoteOffsetIsTheSameClockAsPasteTimestampInMilliseconds() {
        let start = Date(timeIntervalSince1970: 1_000)
        let activity = RecordingActivity(sessionID: UUID(), startedAt: start)

        XCTAssertEqual(
            RecordingTimestamp.noteOffsetMilliseconds(state: .recording(activity), at: start.addingTimeInterval(83.4567)),
            83_456
        )
        XCTAssertEqual(
            RecordingTimestamp.noteOffsetMilliseconds(state: .recording(activity), at: start.addingTimeInterval(83), offset: 30),
            53_000
        )
        XCTAssertEqual(
            RecordingTimestamp.noteOffsetMilliseconds(state: .recording(activity), at: start.addingTimeInterval(10), offset: 30),
            0
        )
    }

    func testNoteOffsetIsNilUnlessAudioIsBeingCaptured() {
        let start = Date(timeIntervalSince1970: 1_000)
        let activity = RecordingActivity(sessionID: UUID(), startedAt: start)
        let later = start.addingTimeInterval(60)

        XCTAssertNil(RecordingTimestamp.noteOffsetMilliseconds(state: .paused(activity), at: later))
        XCTAssertNil(RecordingTimestamp.noteOffsetMilliseconds(state: .starting, at: later))
        XCTAssertNil(RecordingTimestamp.noteOffsetMilliseconds(state: .stopping, at: later))
        XCTAssertNil(RecordingTimestamp.noteOffsetMilliseconds(state: .idle, at: later))
        XCTAssertNil(RecordingTimestamp.noteOffsetMilliseconds(startedAt: start, isPaused: true, at: later))
        XCTAssertEqual(RecordingTimestamp.noteOffsetMilliseconds(startedAt: start, isPaused: false, at: later, offset: 5), 55_000)
    }

    func testNoteOffsetCoversLongRecordings() {
        let start = Date(timeIntervalSince1970: 1_000)
        let activity = RecordingActivity(sessionID: UUID(), startedAt: start)
        // Eleven hours in: well past the hour boundary, no overflow or wrap.
        XCTAssertEqual(
            RecordingTimestamp.noteOffsetMilliseconds(state: .recording(activity), at: start.addingTimeInterval(11 * 3_600 + 5)),
            (11 * 3_600 + 5) * 1_000
        )
    }
}
