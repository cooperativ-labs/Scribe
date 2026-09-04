import Foundation
import Testing
@testable import Platform

/// A permission provider whose answers the test controls, so the service's
/// decisions are exercised without a TCC database or a real System Settings pane.
private final class StubPermissions: RecordingPermissionProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: PermissionSnapshot
    private(set) var requestCount = 0
    private(set) var openedPanes: [SystemSettingsPane] = []
    /// What `requestMissingPermissions` should leave behind, if anything.
    var afterRequest: PermissionSnapshot?

    init(_ snapshot: PermissionSnapshot) { self.snapshot = snapshot }

    func set(_ snapshot: PermissionSnapshot) { lock.withLock { self.snapshot = snapshot } }

    func currentStatus() -> PermissionSnapshot { lock.withLock { snapshot } }

    func requestMissingPermissions() async -> PermissionSnapshot {
        lock.withLock {
            requestCount += 1
            if let afterRequest { snapshot = afterRequest }
            return snapshot
        }
    }

    @MainActor
    func openSystemSettings(_ pane: SystemSettingsPane) {
        lock.withLock { openedPanes.append(pane) }
    }
}

@Suite struct PermissionServiceTests {
    @Test func reportsBothPermissionsAsBlockingWithAnActionableRoute() {
        let stub = StubPermissions(PermissionSnapshot(screenAndSystemAudio: .denied, microphone: .notDetermined))
        let service = PermissionService(provider: stub)

        let snapshot = service.currentStatus()
        #expect(!snapshot.isReadyToRecord)

        let requirements = snapshot.blockingRequirements
        #expect(requirements.map(\.pane) == [.screenRecording, .microphone])
        #expect(requirements[0].settingsURL.absoluteString.contains("Privacy_ScreenCapture"))
        #expect(requirements[1].settingsURL.absoluteString.contains("Privacy_Microphone"))
        // A microphone that has never been asked can still be prompted in-app.
        #expect(requirements[1].canRequestInApp)
        #expect(snapshot.blockingFailure?.recoveryHint?.contains("System Settings") == true)
    }

    @Test func aDeniedMicrophoneCanOnlyBeFixedInSystemSettings() {
        let stub = StubPermissions(PermissionSnapshot(screenAndSystemAudio: .granted, microphone: .denied))
        let service = PermissionService(provider: stub)

        let requirements = service.currentStatus().blockingRequirements
        #expect(requirements.count == 1)
        #expect(requirements[0].pane == .microphone)
        #expect(!requirements[0].canRequestInApp)
        #expect(requirements[0].message.contains("declined"))
    }

    @Test func grantedPermissionsBlockNothing() {
        let service = PermissionService(provider: StubPermissions(.allGranted))
        let snapshot = service.currentStatus()
        #expect(snapshot.isReadyToRecord)
        #expect(snapshot.blockingRequirements.isEmpty)
        #expect(snapshot.blockingFailure == nil)
    }

    @Test func requestingLeavesOnlyWhatSystemSettingsCanFix() async {
        let stub = StubPermissions(PermissionSnapshot(screenAndSystemAudio: .denied, microphone: .notDetermined))
        stub.afterRequest = PermissionSnapshot(screenAndSystemAudio: .denied, microphone: .granted)
        let service = PermissionService(provider: stub)

        let snapshot = await service.requestMissingPermissions()
        #expect(stub.requestCount == 1)
        #expect(snapshot.microphone == .granted)
        #expect(snapshot.blockingRequirements.map(\.pane) == [.screenRecording])
    }

    /// The mid-recording case: a decision that was granted is withdrawn while
    /// Scribe is using it. macOS posts no notification, so the service has to
    /// notice the transition itself.
    @Test func revocationOfAGrantedPermissionIsReportedOnce() {
        let stub = StubPermissions(.allGranted)
        let observed = Locked<[PermissionRevocation]>([])
        let moment = Date(timeIntervalSince1970: 1_700_000_000)
        let service = PermissionService(provider: stub, clock: { moment })
        service.observeRevocations { revocation in observed.mutate { $0.append(revocation) } }

        #expect(service.currentStatus().isReadyToRecord)
        #expect(observed.value.isEmpty)

        stub.set(PermissionSnapshot(screenAndSystemAudio: .denied, microphone: .granted))
        _ = service.currentStatus()

        #expect(observed.value.count == 1)
        #expect(observed.value[0].pane == .screenRecording)
        #expect(observed.value[0].currentStatus == .denied)
        #expect(observed.value[0].observedAt == moment)
        #expect(observed.value[0].failure.recoveryHint?.contains("System Settings") == true)

        // Still denied on the next read: a revocation is a transition, not a state,
        // so it is not reported again.
        _ = service.currentStatus()
        #expect(observed.value.count == 1)
    }

    @Test func regrantingThenLosingAccessReportsASecondRevocation() {
        let stub = StubPermissions(.allGranted)
        let observed = Locked<[PermissionRevocation]>([])
        let service = PermissionService(provider: stub)
        service.observeRevocations { revocation in observed.mutate { $0.append(revocation) } }

        _ = service.currentStatus()
        stub.set(PermissionSnapshot(screenAndSystemAudio: .granted, microphone: .denied))
        _ = service.currentStatus()
        stub.set(.allGranted)
        _ = service.currentStatus()
        stub.set(PermissionSnapshot(screenAndSystemAudio: .granted, microphone: .denied))
        _ = service.currentStatus()

        #expect(observed.value.count == 2)
        #expect(observed.value.allSatisfy { $0.pane == .microphone })
    }

    @Test func neverGrantedPermissionsAreNotRevocations() {
        let stub = StubPermissions(PermissionSnapshot(screenAndSystemAudio: .notDetermined, microphone: .notDetermined))
        let observed = Locked<[PermissionRevocation]>([])
        let service = PermissionService(provider: stub)
        service.observeRevocations { revocation in observed.mutate { $0.append(revocation) } }

        _ = service.currentStatus()
        stub.set(PermissionSnapshot(screenAndSystemAudio: .denied, microphone: .denied))
        _ = service.currentStatus()

        #expect(observed.value.isEmpty)
    }

    @MainActor
    @Test func openingSettingsRoutesToTheRequestedPane() {
        let stub = StubPermissions(PermissionSnapshot(screenAndSystemAudio: .denied, microphone: .granted))
        let service = PermissionService(provider: stub)
        service.openSystemSettings(.screenRecording)
        #expect(stub.openedPanes == [.screenRecording])
    }

    @Test func monitoringPollsUntilStopped() async throws {
        let stub = StubPermissions(.allGranted)
        let observed = Locked<[PermissionRevocation]>([])
        let service = PermissionService(provider: stub)
        service.observeRevocations { revocation in observed.mutate { $0.append(revocation) } }
        _ = service.currentStatus()

        service.startMonitoring(interval: 0.02)
        stub.set(PermissionSnapshot(screenAndSystemAudio: .denied, microphone: .granted))
        try await waitUntil { observed.value.count == 1 }
        service.stopMonitoring()

        stub.set(PermissionSnapshot(screenAndSystemAudio: .denied, microphone: .denied))
        try await Task.sleep(for: .milliseconds(80))
        #expect(observed.value.count == 1)
    }
}

private func waitUntil(timeout: TimeInterval = 2, _ condition: @Sendable () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { Issue.record("Condition was not met within \(timeout)s."); return }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value { lock.withLock { storage } }

    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&storage) } }
}
