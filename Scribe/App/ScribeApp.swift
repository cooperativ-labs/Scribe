import AppKit
import ScribeUI
import SwiftUI

@main
struct ScribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// The menu bar is an AppKit status item owned by the delegate, not a
    /// `MenuBarExtra`: the recording controls sit side by side in one row, and
    /// the source submenus have to survive the once-a-second refresh a running
    /// recording produces. Neither is expressible in a SwiftUI menu. Keep a
    /// Settings scene for the standard app command; the status-item menu uses
    /// an explicitly owned AppKit window so it can present reliably while its
    /// menu is tracking.
    var body: some Scene {
        Settings {
            ScribeSettingsView(
                settings: appDelegate.environment.settings,
                sources: appDelegate.environment.menuModel,
                meetingDetector: appDelegate.environment.meetingDetector
            )
                .onDisappear { appDelegate.environment.settingsWindowDidClose() }
        }
    }
}
