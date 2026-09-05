import AppKit
import ScribeAppCore
import ScribeUI

/// Owns AppKit lifecycle hooks that do not belong in SwiftUI scenes.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Created eagerly so the menu and the delegate share one coordinator.
    let environment = ScribeAppEnvironment()
    /// The status item and its menu. Held here because it is the app's only
    /// visible surface until a window is opened from it.
    private var menuBar: ScribeMenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = ScribeMenuBarController(
            model: environment.menuModel,
            image: NSImage(named: "MenuBarIcon"),
            accessibilityLabel: ScribeAppCore.displayName,
            transcription: { [environment] in environment.transcriptionMenuCommands },
            updates: { [environment] in environment.updateMenuCommands },
            openSettings: { Self.openSettings() }
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

    /// Opens the SwiftUI `Settings` scene. Scribe has no Dock icon, so the app
    /// is activated first, or the window opens behind whatever is in front.
    private static func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}
