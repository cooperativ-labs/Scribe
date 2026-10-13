import AppKit
import Assist
import Combine
import Platform
import Transcription
import XCTest
@testable import Dictation

@MainActor
private final class SecureInputCapture: DictationAudioCapturing {
    var isRecording = false
    var level: Float = 0
    var onRecoveryFailure: (@MainActor (String) -> Void)?
    var starts = 0
    var stops = 0
    func start(microphoneID: String?) throws { starts += 1; isRecording = true }
    func stop() { stops += 1; isRecording = false }
    func finish() throws -> [Float] { isRecording = false; return [0.1, 0.2] }
    func previewSamples() -> [Float] { [] }
}

private struct SecureInputAssistant: TextAssistant {
    let displayName = "Test assistant"
    func respond(to request: AssistRequest) async throws -> AssistResponse { .init(text: "unused", model: "test") }
}

@MainActor
final class DictationSecureInputTests: XCTestCase {
    private func coordinator(capture: SecureInputCapture) -> DictationCoordinator {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let engine = DictationEngine(installation: WorkerInstallation(
            executableURL: root.appending(path: "unused-worker"), manifestURL: root.appending(path: "unused-manifest")),
            modelsDirectoryProvider: { root })
        let coordinator = DictationCoordinator(engine: engine, capture: capture)
        coordinator.assistantAvailability = {
            .ready(AssistantConfiguration(assistant: SecureInputAssistant(), modelName: nil,
                                          sources: .init(usesSelection: false, usesCopiedText: false, usesScreenText: false),
                                          copyOnly: true))
        }
        return coordinator
    }

    func testIdleTransitionsAndDuplicateNotificationsDoNotPublishErrorsOrCancel() {
        let capture = SecureInputCapture()
        let coordinator = coordinator(capture: capture)
        var states: [DictationState] = []
        let observation = coordinator.$state.dropFirst().sink { states.append($0) }
        for _ in 0..<3 {
            coordinator.setSecureInputBlocked(true)
            coordinator.setSecureInputBlocked(true)
            coordinator.setSecureInputBlocked(false)
            coordinator.setSecureInputBlocked(false)
        }
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(states, [])
        XCTAssertEqual(capture.stops, 0)
        withExtendedLifetime(observation) {}
    }

    func testAttemptInEitherModeShowsOneNoticeAndClearsForNextBlock() {
        for intent in DictationIntent.allCases {
            let capture = SecureInputCapture()
            let coordinator = coordinator(capture: capture)
            coordinator.setSecureInputBlocked(true)
            var states: [DictationState] = []
            let observation = coordinator.$state.dropFirst().sink { states.append($0) }
            coordinator.consume(.secureInputBlocked(intent))
            coordinator.consume(.secureInputBlocked(intent))
            coordinator.consume(.cancelled(.secureInput, intent))
            coordinator.setSecureInputBlocked(true)
            XCTAssertEqual(states, [.secureInputBlocked])
            XCTAssertEqual(coordinator.intent, intent)
            XCTAssertEqual(capture.starts, 0)
            XCTAssertEqual(capture.stops, 0)
            coordinator.setSecureInputBlocked(false)
            XCTAssertEqual(coordinator.state, .idle)
            coordinator.setSecureInputBlocked(true)
            coordinator.consume(.secureInputBlocked(intent))
            XCTAssertEqual(states, [.secureInputBlocked, .idle, .secureInputBlocked])
            withExtendedLifetime(observation) {}
        }
    }

    func testListeningStartCannotOpenCaptureWhileBlocked() {
        for intent in DictationIntent.allCases {
            let capture = SecureInputCapture()
            let coordinator = coordinator(capture: capture)
            coordinator.setSecureInputBlocked(true)
            coordinator.consume(.listeningStarted(.hold, intent))
            coordinator.consume(.listeningStarted(.hold, intent))
            XCTAssertEqual(coordinator.state, .secureInputBlocked)
            XCTAssertEqual(coordinator.intent, intent)
            XCTAssertEqual(capture.starts, 0)
        }
    }

    func testTransitionCancelsActiveCaptureOnceForBothModesAndGestures() {
        for intent in DictationIntent.allCases {
            for mode in [DictationTriggerMode.hold, .doubleTap] {
                let capture = SecureInputCapture()
                let coordinator = coordinator(capture: capture)
                coordinator.consume(.listeningStarted(mode, intent))
                XCTAssertTrue(capture.isRecording)
                coordinator.setSecureInputBlocked(true)
                coordinator.consume(.cancelled(.secureInput, intent))
                coordinator.setSecureInputBlocked(true)
                coordinator.consume(.listeningEnded(intent))
                XCTAssertFalse(capture.isRecording)
                XCTAssertEqual(capture.stops, 1)
                XCTAssertEqual(coordinator.state, .idle)
                coordinator.setSecureInputBlocked(false)
                coordinator.consume(.listeningStarted(mode, intent))
                XCTAssertTrue(capture.isRecording)
                coordinator.cancel()
            }
        }
    }

    func testTransitionsDoNotReplaceUnrelatedError() {
        let coordinator = coordinator(capture: SecureInputCapture())
        coordinator.showModelUnavailable()
        let error = coordinator.state
        coordinator.setSecureInputBlocked(true)
        coordinator.setSecureInputBlocked(false)
        XCTAssertEqual(coordinator.state, error)
    }

    func testTransitionAfterReleaseCancelsPendingTranscriptionWithoutLateError() async {
        for intent in DictationIntent.allCases {
            let capture = SecureInputCapture()
            let coordinator = coordinator(capture: capture)
            coordinator.consume(.listeningStarted(.hold, intent))
            coordinator.consume(.listeningEnded(intent))
            XCTAssertEqual(coordinator.state, .transcribing)
            coordinator.setSecureInputBlocked(true)
            coordinator.consume(.cancelled(.secureInput, intent))
            XCTAssertEqual(coordinator.state, .idle)
            // Let the cancelled task run: an unavailable worker must not
            // publish a late failure over the cleared session or a notice.
            coordinator.consume(.secureInputBlocked(intent))
            await Task.yield()
            XCTAssertEqual(coordinator.state, .secureInputBlocked)
            coordinator.setSecureInputBlocked(false)
            XCTAssertEqual(coordinator.state, .idle)
        }
    }

    func testMonitorOnlyReportsActualBlockedAttemptsAndCancelsRouterOnce() {
        var blocked = false
        let monitor = DictationTriggerMonitor(secureInputEnabled: { blocked })
        monitor.setKeys([.dictation: .rightCommand, .assistant: .rightShift])
        var events: [DictationTriggerEvent] = []
        var changes: [Bool] = []
        monitor.onEvent = { events.append($0) }
        monitor.onSecureInputChange = { changes.append($0) }
        blocked = true
        monitor.refreshSecureInput()
        monitor.refreshSecureInput()
        XCTAssertEqual(changes, [true])
        XCTAssertEqual(events, [])
        monitor.handleFlags(keyCode: 60, flags: .shift.union(.init(rawValue: 0x04)), time: 1)
        XCTAssertEqual(events, [.secureInputBlocked(.assistant)])
        monitor.handleFlags(keyCode: 60, flags: [], time: 1.1)
        blocked = false
        monitor.refreshSecureInput()
        events = []
        monitor.handleFlags(keyCode: 54, flags: .command.union(.init(rawValue: 0x10)), time: 2)
        blocked = true
        monitor.refreshSecureInput()
        monitor.refreshSecureInput()
        XCTAssertEqual(events, [.listeningStarted(.hold, .dictation), .cancelled(.secureInput, .dictation)])
        XCTAssertEqual(changes, [true, false, true])
        var router = monitor.router
        XCTAssertEqual(router.advance(to: 1000), [])
        monitor.stop()
        XCTAssertEqual(changes, [true, false, true, false])
    }
}
