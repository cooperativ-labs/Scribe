import XCTest
import Platform
@testable import Transcription

@MainActor
final class TranscriptToastCenterTests: XCTestCase {
    func testHistoryKeepsEvictedDismissedAndFinishedMessages() async throws {
        let name = "ToastDebugLogTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let folder = FileManager.default.temporaryDirectory.appending(path: name)
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: folder)
        }
        let log = MessageDebugLog(defaults: defaults, fileURL: folder.appending(path: "messages.json"))
        log.isEnabled = true
        let center = TranscriptToastCenter(schedulesExpiry: false, debugLog: log)
        let progress = center.post("Queuing", kind: .progress)
        for index in 0..<4 { center.post("Result \(index)", kind: .result) }
        // Completion of an evicted progress toast must still be captured once.
        center.finish(progress, text: "Import failed", failure: true)
        let second = center.post("Exporting", kind: .progress)
        center.finish(second, text: "Exported", failure: false)
        center.dismiss(second)
        XCTAssertFalse(center.visible.contains { $0.text == "Queuing" || $0.text == "Exported" })
        XCTAssertEqual(log.entries.filter { $0.message == "Import failed" }.count, 1)
        XCTAssertTrue(log.entries.contains { $0.message == "Import failed" && $0.level == .error })
        XCTAssertTrue(log.exportText().contains("Queuing"))
        XCTAssertTrue(log.exportText().contains("Exported"))
        await log.flush()
    }

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
