import Foundation
import Platform
import ScribeAppCore
import Storage
import Testing
@testable import Capture

/// The adapter's own responsibilities: what the menu is told about background
/// work it did not start, and that termination waits for the drain.
@MainActor
@Suite("Live recording coordinator") struct LiveRecordingCoordinatorTests {
    @Test func backgroundJobsAppearAndAreRetiredWithoutDisturbingCapture() throws {
        let root = liveTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = makeLiveCoordinator(root: root)
        let first = UUID()
        let second = UUID()

        coordinator.noteBackgroundJob(id: first, title: "Waiting to process recording")
        coordinator.noteBackgroundJob(id: second, title: "Processing recording")
        // The same job seen twice — once from the recorder, once from the queue —
        // must stay one row rather than becoming two.
        coordinator.noteBackgroundJob(id: first, title: "Processing recording")

        #expect(coordinator.snapshot.processing.jobs.map(\.id) == [first, second])
        #expect(coordinator.snapshot.processing.jobs.first?.title == "Processing recording")
        // Background work never moves the recorder off idle.
        #expect(coordinator.snapshot.state == .idle)

        coordinator.finishBackgroundJob(id: first)
        coordinator.finishBackgroundJob(id: second)
        #expect(coordinator.snapshot.processing.jobs.isEmpty)
        #expect(!coordinator.snapshot.processing.isActive)
    }

    @Test func aBackgroundFailureIsSurfacedAndCanBeCleared() throws {
        let root = liveTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = makeLiveCoordinator(root: root)
        let failure = RecorderFailure(
            code: "handoff.cleanupFailed",
            message: "Audio cleanup failed, so there is no final recording to transcribe: the echo delay could not be trusted",
            recoveryHint: "The original tracks were kept. Reprocess the session to try again."
        )

        coordinator.reportBackgroundFailure(failure)
        #expect(coordinator.snapshot.processing.lastFailure == failure)
        // A failure in the background must not put the recorder into a failed state.
        #expect(coordinator.snapshot.state == .idle)

        coordinator.reportBackgroundFailure(nil)
        #expect(coordinator.snapshot.processing.lastFailure == nil)
    }

    @Test func aRecoveryNoticeIsPublishedToObservers() throws {
        let root = liveTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = makeLiveCoordinator(root: root)
        var observed: [String?] = []
        let token = coordinator.observeSnapshot { observed.append($0.recoveryNotice) }
        defer { token.invalidate() }

        coordinator.setRecoveryNotice("Recovered 1 recording from an interrupted session; finishing them now.")
        coordinator.setRecoveryNotice(nil)

        #expect(observed == [nil, "Recovered 1 recording from an interrupted session; finishing them now.", nil])
    }

    @Test func theLaunchScanReportsWhatItRepaired() async throws {
        let root = liveTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // A session left mid-capture by a previous launch.
        let store = try SessionStore.create(configuration: SessionStoreConfiguration(
            recordingsDirectory: root,
            appBuild: "tests",
            macOSVersion: "tests",
            captureScope: CaptureScope(applicationBundleIdentifiers: [], processIdentifiers: []),
            microphone: AudioDeviceIdentity(uniqueID: "mic", name: "Test mic")
        ))

        let reported = RecoveryBox()
        let coordinator = makeLiveCoordinator(root: root)
        coordinator.recoveryReporter = { reported.sessions = $0 }
        // The scan starts during initialization; give its task a turn to finish.
        try await Task.sleep(for: .milliseconds(200))

        #expect(reported.sessions.map(\.sessionID) == [store.manifest.sessionID])
        let manifest = try RecorderSessionManifestCodec.decode(Data(contentsOf: store.manifestURL))
        #expect(manifest.capture.state == .interrupted)
    }

    @Test func terminationAlwaysRepliesEvenWhenNothingIsRecording() async throws {
        let root = liveTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = makeLiveCoordinator(root: root)

        // Stopping while idle is harmless, and the reply must still arrive:
        // a termination that waits forever for a drain that cannot happen would
        // hang the quit.
        await withCheckedContinuation { continuation in
            coordinator.stopForTermination { continuation.resume() }
        }
        #expect(coordinator.snapshot.state == .idle)
    }

    private func makeLiveCoordinator(root: URL) -> LiveRecordingCoordinator {
        LiveRecordingCoordinator(
            snapshot: RecorderSnapshot(permissions: .allGranted, recordingsFolderURL: root),
            permissions: StubPermissions(),
            sourceProvider: StubSourceProvider(),
            appBuild: "tests",
            macOSVersion: "tests"
        )
    }

    private func liveTemporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-coordinator-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

@MainActor private final class RecoveryBox {
    var sessions: [SessionStore.RecoveredSession] = []
}

private final class StubPermissions: RecordingPermissionProviding, @unchecked Sendable {
    func currentStatus() -> PermissionSnapshot { .allGranted }
    func requestMissingPermissions() async -> PermissionSnapshot { .allGranted }
    @MainActor func openSystemSettings(_: SystemSettingsPane) {}
}

private final class StubSourceProvider: CaptureSourceProviding, @unchecked Sendable {
    func shareableApplications() async throws -> [CaptureApplicationOption] { [] }
    func availableMicrophones() async -> [CaptureMicrophoneOption] { [] }
}
