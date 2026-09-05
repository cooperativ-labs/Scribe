import Combine
import Foundation
import Platform
import SwiftUI

/// Adapts a `RecordingCoordinating` to SwiftUI and owns the elapsed-time tick.
///
/// The model never mutates recorder state itself: every user action becomes a
/// `RecordingCommand`, so a menu click and a global shortcut take exactly the
/// same serialized route into the coordinator.
@MainActor
public final class RecorderMenuModel: ObservableObject {
    @Published public private(set) var presentation: MenuPresentation

    private let coordinator: any RecordingCoordinating
    private let now: @MainActor () -> Date
    private var snapshot: RecorderSnapshot
    private var observation: RecorderObservationToken?
    private var elapsedTimeTicker: Timer?

    public init(
        coordinator: any RecordingCoordinating,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.coordinator = coordinator
        self.now = now
        snapshot = coordinator.snapshot
        presentation = MenuPresentation(snapshot: coordinator.snapshot, at: now())
        observation = coordinator.observeSnapshot { [weak self] snapshot in
            guard let self else { return }
            self.snapshot = snapshot
            refreshPresentation()
        }
    }

    /// Recomputes the presentation against the current time. The elapsed timer
    /// calls this every second; tests call it directly with a stubbed clock.
    public func refreshPresentation() {
        presentation = MenuPresentation(snapshot: snapshot, at: now())
    }

    // MARK: Menu lifecycle

    /// Called when the menu opens. Sources are re-enumerated each time so a
    /// meeting application launched after Scribe still appears.
    public func menuDidAppear() {
        coordinator.submit(.refreshSources)
        refreshPresentation()
        guard elapsedTimeTicker == nil else { return }
        // Added to the main run loop, so the block always runs on the main actor.
        // It holds the model weakly, and `menuDidDisappear` retires it as soon as
        // the menu closes, which is the only time it can be running.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPresentation() }
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimeTicker = timer
    }

    /// Called when the menu closes. Nothing needs updating while it is hidden.
    public func menuDidDisappear() {
        elapsedTimeTicker?.invalidate()
        elapsedTimeTicker = nil
    }

    // MARK: Commands

    public func startRecording() { coordinator.submit(.start) }
    public func stopRecording() { coordinator.submit(.stop) }
    public func pauseRecording() { coordinator.submit(.pause) }
    public func resumeRecording() { coordinator.submit(.resume) }
    public func openRecordingsFolder() { coordinator.submit(.openRecordingsFolder) }
    public func requestPermissions() { coordinator.submit(.requestPermissions) }
    public func openSystemSettings(_ pane: SystemSettingsPane) { coordinator.submit(.openSystemSettings(pane)) }
    public func quit() { coordinator.submit(.quit) }
    public func refreshSources() { coordinator.submit(.refreshSources) }

    public func selectApplication(_ id: String?) { coordinator.submit(.selectApplication(id)) }
    public func selectMicrophone(_ id: String?) { coordinator.submit(.selectMicrophone(id)) }

    public var selectedApplication: Binding<String?> {
        Binding(
            get: { [weak self] in self?.presentation.selectedApplicationID },
            set: { [weak self] in self?.coordinator.submit(.selectApplication($0)) }
        )
    }

    public var selectedMicrophone: Binding<String?> {
        Binding(
            get: { [weak self] in self?.presentation.selectedMicrophoneID },
            set: { [weak self] in self?.coordinator.submit(.selectMicrophone($0)) }
        )
    }
}
