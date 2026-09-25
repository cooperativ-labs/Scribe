import AppKit
import Combine
import ScribeAppCore
import ScribeUI
import SwiftUI

/// Owns AppKit lifecycle hooks that do not belong in SwiftUI scenes.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Created eagerly so the menu and the delegate share one coordinator.
    let environment = ScribeAppEnvironment()
    /// The status item and its menu. Held here because it is the app's only
    /// visible surface until a window is opened from it.
    private var menuBar: ScribeMenuBarController?
    /// The chip that hangs under the status item when a call is noticed. Its own
    /// window, so it can reach a person who is looking at their meeting rather
    /// than at Scribe's menu.
    private var meetingChip: MeetingChipController?
    /// Keeps the status item's recording dot and the chip from saying the same
    /// thing at once: the chip withdraws a few seconds into a recording, and the
    /// dot takes over from there.
    private var chipVisibilityObservation: AnyCancellable?
    private var dictationIndicator: DictationIndicatorController?
    private var dictationStateObservation: AnyCancellable?
    private var wasDictationListening = false
    private var dictationStartSoundTask: Task<Void, Never>?
    private var didPlayDictationStartSound = false
    /// Retained while visible because the status item is otherwise Scribe's
    /// only AppKit-owned surface.
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The transcript window's Vocabulary button opens Settings, which lives
        // here rather than in the environment.
        environment.openSettingsWindow = { [weak self] in self?.openSettings() }
        menuBar = ScribeMenuBarController(
            model: environment.menuModel,
            image: NSImage(named: "MenuBarIcon"),
            accessibilityLabel: ScribeAppCore.displayName,
            transcription: { [environment] in environment.transcriptionMenuCommands },
            updates: { [environment] in environment.updateMenuCommands },
            openSettings: { [weak self] in self?.openSettings() }
        )
        menuBar?.dictationEnabled = { [environment] in environment.settings.dictationEnabled }
        menuBar?.toggleDictation = { [environment] in environment.toggleDictation() }
        menuBar?.openDictationSettings = { [weak self] in self?.openDictationSettings() }
        menuBar?.dictationSecureInputBlocked = { [environment] in environment.settings.dictationSecureInputBlocked }
        if let dictation = environment.dictationCoordinator {
            dictationIndicator = DictationIndicatorController(
                coordinator: dictation,
                position: { [environment] in environment.settings.dictationIndicatorPosition },
                stop: { [environment] in environment.stopToggleDictation() },
                cancel: { [environment] in environment.cancelToggleDictation() },
                openSettings: { [weak self] in self?.openDictationSettings() }
            )
            dictationStateObservation = dictation.$state.sink { [weak self, weak menuBar] state in
                let listening: Bool
                if case .listening = state { listening = true }
                else { listening = false }
                menuBar?.isDictationListening = listening
                guard let self else { return }
                if listening != self.wasDictationListening {
                    self.dictationStartSoundTask?.cancel()
                    self.dictationStartSoundTask = nil
                    if listening, environment.settings.dictationPlaySounds {
                        if dictation.triggerMode == .doubleTap {
                            NSSound(named: NSSound.Name("Tink"))?.play()
                            self.didPlayDictationStartSound = true
                        } else {
                            self.dictationStartSoundTask = Task { [weak self] in
                                try? await Task.sleep(for: .milliseconds(300))
                                guard let self, !Task.isCancelled,
                                      case .listening = dictation.state else { return }
                                NSSound(named: NSSound.Name("Tink"))?.play()
                                self.didPlayDictationStartSound = true
                            }
                        }
                    } else if !listening {
                        if self.didPlayDictationStartSound, environment.settings.dictationPlaySounds {
                            NSSound(named: NSSound.Name("Pop"))?.play()
                        }
                        self.didPlayDictationStartSound = false
                    }
                }
                self.wasDictationListening = listening
            }
        }
        // The anchor is read at each appearance rather than captured: the menu
        // bar rearranges itself as other items come and go.
        meetingChip = MeetingChipController(
            model: environment.meetingChipModel,
            anchor: { [weak menuBar] in menuBar?.statusItemAnchor }
        )
        chipVisibilityObservation = environment.meetingChipModel.$presentation.sink { [weak menuBar] presentation in
            menuBar?.isMeetingChipVisible = presentation.isVisible
        }
        environment.presentFirstRunPermissionsIfNeeded()
        environment.checkForUpdates()
    }

    func applicationWillTerminate(_ notification: Notification) {
        environment.cleanUpPendingUpdateOnTermination()
    }

    /// The Dock is Scribe's reliable way back to its primary review surface.
    /// This is invoked for Dock activation even when the app currently has no
    /// visible windows, such as after the Transcripts window was closed.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        environment.openTranscriptWindow()
        return true
    }

    /// Quitting during capture performs a normal stop and saves the originals.
    ///
    /// The reply is deferred until the stop has actually drained. Exiting as soon
    /// as the command was submitted would race the finalization: the manifest
    /// would still read `capturing`, and a completed meeting would come back as
    /// recovery work on the next launch instead of as a finished recording.
    /// Background processing is not waited on — it resumes after relaunch.
    /// A paused capture is a live one: it is stopped and saved the same way.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let state = environment.coordinator.snapshot.state
        guard state.isCapturing || state.isTransitioning else { return .terminateNow }
        environment.coordinator.stopForTermination {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Opens Settings from the status-item menu. Sending `showSettingsWindow:`
    /// through the responder chain is unreliable while that menu is tracking:
    /// it activates Scribe but can have no target to display the
    /// SwiftUI scene. Host the same view in an owned AppKit window instead.
    private func openSettings() {
        if let settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(contentViewController: NSHostingController(
            rootView: ScribeSettingsView(
                settings: environment.settings,
                sources: environment.menuModel,
                meetingDetector: environment.meetingDetector,
                calendar: environment.calendar,
                vocabulary: environment.vocabulary,
                permissions: environment.permissions,
                focus: environment.settingsFocus,
                onShortcutCaptureChange: { [environment] in environment.setShortcutCaptureActive($0) }
            )
        ))
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 700, height: 650))
        window.minSize = NSSize(width: 500, height: 400)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func openDictationSettings() {
        environment.settingsFocus.request(.dictation)
        openSettings()
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        settingsWindow = nil
        environment.settingsWindowDidClose()
    }
}
