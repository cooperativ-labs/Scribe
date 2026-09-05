import Foundation
import Platform
import ScribeAppCore
import Storage
import Testing
@testable import Capture

@Suite("Recording coordinator") struct RecordingCoordinatorTests {
    @Test func serialStartStopFinalizesBeforePublishingFinalReady() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = FakeCapture()
        let coordinator = makeCoordinator(root: root, capture: capture)
        let stream = await coordinator.events()
        var iterator = stream.makeAsyncIterator()

        await coordinator.start()
        guard case let .recording(activity) = await coordinator.state() else {
            Issue.record("Coordinator did not enter recording")
            return
        }
        await coordinator.stop()

        #expect(capture.startCount == 1)
        #expect(capture.stopCount == 1)
        #expect(await coordinator.state() == .idle)
        let directory = try onlySessionDirectory(in: root)
        let manifest = try RecorderSessionManifestCodec.decode(Data(contentsOf: directory.appendingPathComponent("metadata.json")))
        #expect(manifest.sessionID == activity.sessionID)
        #expect(manifest.capture.state == .complete)
        #expect(manifest.completionStatus == .complete)

        var observed: [RecordingCoordinatorEvent] = []
        for _ in 0..<7 {
            if let event = await iterator.next() { observed.append(event) }
        }
        let stoppedIndex = observed.firstIndex { if case .recordingStopped = $0 { true } else { false } }
        let readyIndex = observed.firstIndex { if case .finalRecordingReady = $0 { true } else { false } }
        #expect(stoppedIndex != nil)
        #expect(readyIndex != nil)
        if let stoppedIndex, let readyIndex {
            #expect(stoppedIndex < readyIndex)
        }
    }

    @Test func pauseHoldsOneSessionAndResumeContinuesIt() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = FakeCapture()
        let coordinator = makeCoordinator(root: root, capture: capture)

        await coordinator.start()
        guard case let .recording(activity) = await coordinator.state() else {
            Issue.record("Coordinator did not enter recording")
            return
        }
        await coordinator.pause()
        #expect(await coordinator.state() == .paused(activity))
        await coordinator.resume()
        #expect(await coordinator.state() == .recording(activity))

        // The stream is held, never restarted: restarting would rebind the
        // microphone and re-resolve the application mid-meeting.
        #expect(capture.pauseChanges == [true, false])
        #expect(capture.startCount == 1)
        #expect(capture.stopCount == 0)
        let journal = try String(contentsOf: try onlySessionDirectory(in: root).appendingPathComponent("capture/timeline.jsonl"), encoding: .utf8)
        #expect(journal.contains("capture-paused"))
        #expect(journal.contains("capture-resumed"))
    }

    @Test func aPausedCaptureIsFinalizedByTheOrdinaryStop() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = FakeCapture()
        let coordinator = makeCoordinator(root: root, capture: capture)

        await coordinator.start()
        await coordinator.pause()
        await coordinator.stop()

        #expect(await coordinator.state() == .idle)
        // Released before the drain, so teardown takes one path whether or not
        // the capture was held.
        #expect(capture.pauseChanges == [true, false])
        #expect(capture.stopCount == 1)
        let directory = try onlySessionDirectory(in: root)
        let manifest = try RecorderSessionManifestCodec.decode(Data(contentsOf: directory.appendingPathComponent("metadata.json")))
        #expect(manifest.capture.state == .complete)
        #expect(manifest.completionStatus == .complete)
    }

    @Test func pauseAndResumeAreIgnoredOutsideTheStatesTheyBelongTo() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = FakeCapture()
        let coordinator = makeCoordinator(root: root, capture: capture)

        await coordinator.pause()
        #expect(await coordinator.state() == .idle)

        await coordinator.start()
        await coordinator.resume()
        // Already recording: a resume has nothing to release.
        #expect(capture.pauseChanges.isEmpty)

        await coordinator.pause()
        await coordinator.pause()
        #expect(capture.pauseChanges == [true])
    }

    @Test func sleepUsesTheSameDrainAndInterruptionPath() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = makeCoordinator(root: root, capture: FakeCapture())

        await coordinator.start()
        await coordinator.handleInterruption(.sleep)

        let directory = try onlySessionDirectory(in: root)
        let manifest = try RecorderSessionManifestCodec.decode(Data(contentsOf: directory.appendingPathComponent("metadata.json")))
        #expect(manifest.capture.state == .interrupted)
        #expect(manifest.completionStatus == .interrupted)
        #expect(manifest.interruptions.last?.reason == "system-sleep")
        let journal = try String(contentsOf: directory.appendingPathComponent("capture/timeline.jsonl"), encoding: .utf8)
        #expect(journal.contains("system-sleep"))
    }

    @Test func fiftyRepeatedStartStopCyclesRemainSerialized() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = FakeCapture()
        let coordinator = makeCoordinator(root: root, capture: capture)

        for _ in 0..<50 {
            await coordinator.start()
            await coordinator.stop()
            #expect(await coordinator.state() == .idle)
        }

        #expect(capture.startCount == 50)
        #expect(capture.stopCount == 50)
        let sessions = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        #expect(sessions.count == 50)
    }

    @Test func launchRecoveryFindsAnUncleanSession() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore.create(configuration: storeConfiguration(root: root))
        let coordinator = makeCoordinator(root: root, capture: FakeCapture())

        let recovered = try await coordinator.recoverIncompleteSessions()
        #expect(recovered.map(\.sessionID) == [store.manifest.sessionID])
        let manifest = try RecorderSessionManifestCodec.decode(Data(contentsOf: store.manifestURL))
        #expect(manifest.capture.state == .interrupted)
    }

    private func makeCoordinator(root: URL, capture: FakeCapture) -> RecordingCoordinator {
        RecordingCoordinator(
            configuration: RecordingCoordinatorConfiguration(
                recordingsDirectory: root,
                appBuild: "tests",
                macOSVersion: "tests",
                selectedApplicationBundleIdentifier: "com.example.Meeting",
                selectedMicrophoneID: "mic"
            ),
            permissions: GrantedPermissions(),
            captureFactory: { _, _, _ in capture },
            freeSpace: { _ in Int64.max }
        )
    }

    private func storeConfiguration(root: URL) -> SessionStoreConfiguration {
        SessionStoreConfiguration(
            recordingsDirectory: root,
            appBuild: "tests",
            macOSVersion: "tests",
            captureScope: CaptureScope(applicationBundleIdentifiers: ["com.example.Meeting"], processIdentifiers: [1]),
            microphone: AudioDeviceIdentity(uniqueID: "mic", name: "Test mic")
        )
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recording-coordinator-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func onlySessionDirectory(in root: URL) throws -> URL {
        let directories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        return try #require(directories.first)
    }
}

private final class GrantedPermissions: RecordingPermissionProviding, @unchecked Sendable {
    func currentStatus() -> PermissionSnapshot { .allGranted }
    func requestMissingPermissions() async -> PermissionSnapshot { .allGranted }
    @MainActor func openSystemSettings(_: SystemSettingsPane) {}
}

private final class FakeCapture: RecordingCaptureControlling, @unchecked Sendable {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    /// Every hold and release, in order, so a pause is verifiable as an effect
    /// on capture rather than only as a published state.
    private(set) var pauseChanges: [Bool] = []

    func setPaused(_ paused: Bool) { pauseChanges.append(paused) }

    func start() async throws -> ResolvedCaptureSources {
        startCount += 1
        return ResolvedCaptureSources(
            scope: CaptureScope(applicationBundleIdentifiers: ["com.example.Meeting"], processIdentifiers: [42]),
            applications: [CaptureApplicationOption(bundleIdentifier: "com.example.Meeting", name: "Meeting", processIdentifier: 42)],
            microphone: AudioDeviceIdentity(uniqueID: "mic", name: "Test mic"),
            filterDescription: "test"
        )
    }

    func stop() async -> CaptureStatistics {
        stopCount += 1
        return CaptureStatistics(
            system: .init(enqueuedBuffers: 1, droppedBuffers: 0, droppedFrames: 0, queuedBytes: 0, peakQueuedBytes: 0),
            microphone: .init(enqueuedBuffers: 1, droppedBuffers: 0, droppedFrames: 0, queuedBytes: 0, peakQueuedBytes: 0),
            rejectedBuffers: 0,
            discardedScreenFrames: 0
        )
    }
}
