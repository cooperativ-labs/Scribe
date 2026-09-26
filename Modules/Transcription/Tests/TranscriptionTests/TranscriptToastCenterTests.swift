import XCTest
@testable import Transcription

@MainActor
final class TranscriptToastCenterTests: XCTestCase {
    func testNewestThreeRemainInOrder() {
        let center = TranscriptToastCenter(schedulesExpiry: false)
        for label in ["one", "two", "three", "four"] {
            center.post(label, kind: .result)
        }
        XCTAssertEqual(center.visible.map(\.text), ["two", "three", "four"])
    }

    func testResultsExpireAfterFourSecondsAndHoverPausesRemainingTime() {
        var time = Date(timeIntervalSince1970: 0)
        let center = TranscriptToastCenter(now: { time }, schedulesExpiry: false)
        let id = center.post("Done", kind: .result)
        time.addTimeInterval(2)
        center.setHovered(true, for: id)
        time.addTimeInterval(10)
        center.expire()
        XCTAssertEqual(center.visible.count, 1)
        center.setHovered(false, for: id)
        time.addTimeInterval(1.9)
        center.expire()
        XCTAssertEqual(center.visible.count, 1)
        time.addTimeInterval(0.1)
        center.expire()
        XCTAssertTrue(center.visible.isEmpty)
    }

    func testFailuresPersistAndProgressBecomesResult() {
        var time = Date(timeIntervalSince1970: 0)
        let center = TranscriptToastCenter(now: { time }, schedulesExpiry: false)
        let failure = center.post("Failed", kind: .failure)
        let progress = center.post("Queuing", kind: .progress)
        center.finish(progress, text: "Queued", failure: false)
        time.addTimeInterval(5)
        center.expire()
        XCTAssertEqual(center.visible.map(\.id), [failure])
        center.dismiss(failure)
        XCTAssertTrue(center.visible.isEmpty)
    }

    func testOnlyLatestReversibleToastKeepsItsAction() {
        let center = TranscriptToastCenter(schedulesExpiry: false)
        center.post("Edited words", kind: .result, action: .undo)
        center.post("Split turn", kind: .result, action: .undo)
        XCTAssertEqual(center.visible.map(\.action), [nil, .undo])
        center.clearReversibleActions()
        XCTAssertEqual(center.visible.map(\.action), [nil, nil])
    }
}
