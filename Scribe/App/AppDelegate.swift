import AppKit

/// Owns AppKit lifecycle hooks that do not belong in SwiftUI scenes.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Created eagerly so the menu scene and the delegate share one coordinator.
    let environment = ScribeAppEnvironment()

    func applicationDidFinishLaunching(_ notification: Notification) {
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
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let state = environment.coordinator.snapshot.state
        guard state.isRecording || state.isTransitioning else { return .terminateNow }
        environment.coordinator.stopForTermination {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
