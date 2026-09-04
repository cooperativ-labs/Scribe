import AppKit
import Platform
import ScribeAppCore
import ScribeUI
import SwiftUI

@main
struct ScribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra(ScribeAppCore.displayName, systemImage: "waveform") {
            ScribeMenuBarContents(environment: appDelegate.environment)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            ScribeSettingsView(settings: appDelegate.environment.settings)
                .onDisappear { appDelegate.environment.settingsWindowDidClose() }
        }
    }
}

/// Observes the environment so transcription status reaches the menu.
///
/// The recorder's own rows already refresh through `RecorderMenuModel`; this
/// exists because queue state belongs to a second, independent object and the
/// menu must show both without either owning the other.
private struct ScribeMenuBarContents: View {
    @ObservedObject var environment: ScribeAppEnvironment

    var body: some View {
        ScribeMenuBarContent(
            model: environment.menuModel,
            transcription: environment.transcriptionMenuCommands
        )
    }
}
