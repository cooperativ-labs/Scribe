import Foundation
import Platform
import XCTest

final class RecordingTimestampTests: XCTestCase {
    func testElapsedTextUsesMinutesUntilAnHourThenAddsHours() {
        XCTAssertEqual(RecordingTimestamp.elapsedText(0), "00:00")
        XCTAssertEqual(RecordingTimestamp.elapsedText(83), "01:23")
        XCTAssertEqual(RecordingTimestamp.elapsedText(3_723), "1:02:03")
    }

    func testCopyableTextFollowsTheRecordingClock() {
        let start = Date(timeIntervalSince1970: 1_000)
        let activity = RecordingActivity(sessionID: UUID(), startedAt: start)

        XCTAssertEqual(
            RecordingTimestamp.copyableText(state: .recording(activity), at: start.addingTimeInterval(83)),
            "01:23"
        )
        XCTAssertEqual(
            RecordingTimestamp.copyableText(state: .paused(activity), at: start.addingTimeInterval(83)),
            "01:23"
        )
        XCTAssertEqual(RecordingTimestamp.copyableText(state: .starting, at: start), "00:00")
        XCTAssertNil(RecordingTimestamp.copyableText(state: .idle, at: start))
        XCTAssertNil(RecordingTimestamp.copyableText(state: .stopping, at: start))
    }
}
