import AppKit
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
    /// Retained while visible because the status item is otherwise Scribe's
    /// only AppKit-owned surface.
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = ScribeMenuBarController(
            model: environment.menuModel,
            image: NSImage(named: "MenuBarIcon"),
            accessibilityLabel: ScribeAppCore.displayName,
            transcription: { [environment] in environment.transcriptionMenuCommands },
            updates: { [environment] in environment.updateMenuCommands },
            openSettings: { [weak self] in self?.openSettings() }
        )
        // The anchor is read at each appearance rather than captured: the menu
        // bar rearranges itself as other items come and go.
        meetingChip = MeetingChipController(
            model: environment.meetingChipModel,
            anchor: { [weak menuBar] in menuBar?.statusItemAnchor }
        )
        environment.presentFirstRunPermissionsIfNeeded()
        environment.checkForUpdates()
    }

    func applicationWillTerminate(_ notification: Notification) {
        environment.cleanUpPendingUpdateOnTermination()
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
    /// it activates this LSUIElement app but can have no target to display the
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
                meetingDetector: environment.meetingDetector
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
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        settingsWindow = nil
        environment.settingsWindowDidClose()
    }
}
