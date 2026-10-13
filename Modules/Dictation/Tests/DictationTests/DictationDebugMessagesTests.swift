import Platform
import Transcription
import XCTest
@testable import Dictation

@MainActor
final class DictationDebugMessagesTests: XCTestCase {
    func testSecureInputWarningSurvivesImmediateStateClearAndRelaunch() async throws {
        let name = "DictationDebugMessagesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let root = FileManager.default.temporaryDirectory.appending(path: name)
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: root)
        }
        let url = root.appending(path: "messages.json")
        let log = MessageDebugLog(defaults: defaults, fileURL: url)
        log.isEnabled = true
        // No microphone or model is needed to reproduce the warning path.
        let engine = DictationEngine(installation: WorkerInstallation(
            executableURL: root.appending(path: "unused-worker"), manifestURL: root.appending(path: "unused-manifest")),
            modelsDirectoryProvider: { root })
        let coordinator = DictationCoordinator(engine: engine, debugLog: log)
        coordinator.setSecureInputBlocked(true)
        coordinator.consume(.cancelled(.secureInput, .dictation))
        coordinator.consume(.secureInputBlocked(.dictation))
        coordinator.consume(.secureInputBlocked(.dictation))
        coordinator.setSecureInputBlocked(false)
        XCTAssertEqual(coordinator.state, .idle)
        coordinator.consume(.cancelled(.chord, .dictation))
        await log.flush()
        let saved = MessageDebugLog(defaults: defaults, fileURL: url)
        XCTAssertEqual(saved.entries.filter { $0.message == DictationState.secureInputMessage && $0.level == .warning }.count, 1)
        XCTAssertFalse(saved.exportText().contains("Session cancelled"))
        XCTAssertEqual(saved.entries.filter { $0.message.contains("Activation blocked by Secure Keyboard Entry") }.count, 1)
        XCTAssertTrue(saved.exportText().contains("reason=chord"))
        XCTAssertTrue(saved.exportText().contains("Dictation secure-input block cleared"))
    }
}
