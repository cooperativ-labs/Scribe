import Platform
import SwiftUI

/// The first-run permission window.
///
/// macOS prompts for each permission only once, so after a denial the only way
/// forward is System Settings. Every blocking permission therefore always offers
/// that route, whether or not an in-app prompt is still possible.
public struct ScribePermissionsView: View {
    @ObservedObject private var model: RecorderMenuModel
    @ObservedObject private var settings: ScribeSettings
    @ObservedObject private var modelInstaller: TranscriptionModelInstaller
    private let permissions: PermissionService
    private let dismiss: () -> Void

    public init(model: RecorderMenuModel, settings: ScribeSettings, permissions: PermissionService, dismiss: @escaping () -> Void) {
        self.settings = settings
        self.modelInstaller = settings.modelInstaller
        self.permissions = permissions
        self.model = model
        self.dismiss = dismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Scribe records meeting audio locally")
                .font(.title3.weight(.semibold))

            if settings.dictationEnabled {
                let access = DictationAccess.current()
                VStack(alignment: .leading, spacing: 6) {
                    Label("Dictation", systemImage: "waveform")
                        .font(.headline)
                    Text("Microphone: \(access.microphone == .granted ? "Allowed" : "Not allowed") · Accessibility: \(access.accessibility ? "Allowed" : "Not allowed")")
                    if !access.accessibility {
                        Button("Open Accessibility Settings") { permissions.openSystemSettings(.accessibility) }
                    }
                    if !access.isReady {
                        Button("Request Dictation Access") {
                            Task { _ = await permissions.requestDictationAccess() }
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Optional: Dictation", systemImage: "waveform")
                        .font(.headline)
                    Text("Hold or double-tap \(settings.dictationActivationKey.displayName) to dictate into other apps. Audio and text stay on this Mac.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if modelInstaller.state == .installed {
                        Button("Enable Dictation") {
                            settings.dictationEnabled = true
                            Task { _ = await permissions.requestDictationAccess() }
                        }
                    } else {
                        Button("Download Dictation Model") {
                            modelInstaller.install(directory: settings.modelsFolderURL)
                        }
                        .disabled(modelInstaller.isBusy)
                    }
                }
            }

            if let prompt = model.presentation.permissionPrompt {
                Text(prompt.title)
                    .font(.headline)
                ForEach(prompt.requirements) { requirement in
                    VStack(alignment: .leading, spacing: 6) {
                        Label(requirement.pane.displayName, systemImage: "lock.shield")
                            .font(.subheadline.weight(.medium))
                        Text(requirement.message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Open \(requirement.pane.displayName) Settings") {
                            model.openSystemSettings(requirement.pane)
                        }
                    }
                }
                HStack {
                    if prompt.canRequestInApp {
                        Button("Request Access") { model.requestPermissions() }
                            .keyboardShortcut(.defaultAction)
                    }
                    Spacer()
                    Button("Continue Without Recording", action: dismiss)
                }
            } else {
                Label(settings.dictationEnabled && !DictationAccess.current().isReady
                    ? "Recording is ready. Grant dictation access in System Settings."
                    : "Scribe has everything it needs to record.", systemImage: "checkmark.circle")
                Button("Done", action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
