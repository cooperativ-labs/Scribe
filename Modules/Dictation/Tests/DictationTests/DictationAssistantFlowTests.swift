import Assist
import XCTest
@testable import Dictation

final class DictationAssistantFlowTests: XCTestCase {
    func testTimeoutEndsASlowRequest() async {
        do {
            _ = try await DictationCoordinator.withTimeout(.milliseconds(50)) {
                try await Task.sleep(for: .seconds(5))
                return "late"
            }
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(DictationCoordinator.assistantState(for: error, timeout: .seconds(60)),
                           .error("No answer after 60 seconds. Try again."))
        }
    }

    func testFastRequestWinsTheRace() async throws {
        let answer = try await DictationCoordinator.withTimeout(.seconds(5)) { "answer" }
        XCTAssertEqual(answer, "answer")
    }

    func testCancellingTheCallerCancelsTheRequest() async {
        let task = Task {
            try await DictationCoordinator.withTimeout(.seconds(60)) {
                try await Task.sleep(for: .seconds(30))
                return "late"
            }
        }
        task.cancel()
        let result = await task.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
    }

    func testErrorsMapToIndicatorStates() {
        XCTAssertEqual(DictationCoordinator.assistantState(for: CodexAppServerError.notSignedIn, timeout: .seconds(60)),
                       .error("Sign in to ChatGPT through Codex in Voice Assistant settings."))
        XCTAssertEqual(DictationCoordinator.assistantState(for: DictationCoordinator.AssistantTimeout(), timeout: .seconds(60)),
                       .error("No answer after 60 seconds. Try again."))
    }
}
