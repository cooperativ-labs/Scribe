import AppKit
import ScribeUI
import SwiftUI

@main
struct ScribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// The menu bar is an AppKit status item owned by the delegate, not a
    /// `MenuBarExtra`: the recording controls sit side by side in one row, and
    /// the source submenus have to survive the once-a-second refresh a running
    /// recording produces. Neither is expressible in a SwiftUI menu. Settings
    /// stays a SwiftUI scene, and the menu opens it through the same
    /// `showSettingsWindow:` action a `SettingsLink` would have sent.
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
