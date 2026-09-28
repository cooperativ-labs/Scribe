@testable import Assist
import XCTest
#if canImport(FoundationModels, _version: 2)
import FoundationModels
#endif

final class PrivateCloudAssistantTests: XCTestCase {
    func testTheBudgetLeavesRoomForTheInstructionsAndTheAnswer() {
        let instructions = String(repeating: "i", count: 300)
        // 32,768 tokens less 2,048 for the answer and 100 for the instructions, at 3 characters a token.
        XCTAssertEqual(PrivateCloudAssistant.characterBudget(contextSize: 32_768, instructions: instructions), 91_860)
        XCTAssertEqual(PrivateCloudAssistant.characterBudget(contextSize: 1_000, instructions: instructions), 0)
    }

    func testAnOverrunShrinksTheBudgetInProportion() {
        // Twice the usable tokens: roughly half the characters, less a tenth.
        XCTAssertEqual(PrivateCloudAssistant.shrunk(90_000, contextSize: 12_048, tokenCount: 20_000), 40_500)
        XCTAssertEqual(PrivateCloudAssistant.shrunk(90_000, contextSize: 1_000, tokenCount: 20_000), 0)
    }

    func testStatusMessagesSayWhatToDo() {
        XCTAssertEqual(PrivateCloudModel.Status.unsupportedSystem.message, "Private Cloud Compute needs macOS 27 or later.")
        XCTAssertTrue(PrivateCloudModel.Status.notEntitled.message.contains("not approved by Apple"))
        XCTAssertEqual(PrivateCloudModel.Status.limitReached(resetsAt: nil).message, "You’ve reached your Private Cloud Compute limit. Try again later.")
        XCTAssertTrue(PrivateCloudModel.Status.limitReached(resetsAt: Date()).message.contains("It resets at"))
    }

    func testTheTestRunnerIsNotEntitled() {
        // xctest is not signed with the Private Cloud Compute entitlement, so
        // on macOS 27 the account must say so instead of failing a request.
        XCTAssertFalse(PrivateCloudModel.isEntitled)
        XCTAssertNotEqual(PrivateCloudModel.status, .available)
    }

    func testAnUnentitledRequestFailsWithTheReason() async {
        let request = AssistRequest(instruction: "Say hi", selectedText: nil, copiedText: nil, screenText: [])
        do {
            _ = try await PrivateCloudAssistant().respond(to: request)
            XCTFail("expected an error")
        } catch let error as AssistError {
            XCTAssertEqual(error, .appleModel(PrivateCloudModel.status.message))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    #if canImport(FoundationModels, _version: 2)
    func testServiceErrorsBecomePlainMessages() throws {
        guard #available(macOS 27.0, *) else { throw XCTSkip("needs macOS 27") }
        typealias PCCError = PrivateCloudComputeLanguageModel.Error
        let quota = PrivateCloudAssistant.assistError(for: PCCError.quotaLimitReached(.init(debugDescription: "quota")))
        XCTAssertEqual(quota as? AssistError, .appleModel("You’ve reached your Private Cloud Compute limit. Try again later."))
        let network = PrivateCloudAssistant.assistError(for: PCCError.networkFailure(.init(debugDescription: "offline")))
        XCTAssertEqual(network as? AssistError, .network("Could not reach Apple’s Private Cloud Compute. Check your internet connection."))
        let service = PrivateCloudAssistant.assistError(for: PCCError.serviceUnavailable(.init(debugDescription: "down")))
        XCTAssertEqual(service as? AssistError, .appleModel("Apple’s Private Cloud Compute is unavailable right now. Try again shortly."))
        XCTAssertTrue(PrivateCloudAssistant.assistError(for: CancellationError()) is CancellationError)
        XCTAssertEqual(PrivateCloudAssistant.assistError(for: AssistError.emptyResponse) as? AssistError, .emptyResponse)
    }
    #endif
}
