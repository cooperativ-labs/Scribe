import Platform
import ServiceManagement
import SwiftUI

/// Decides when the first-run setup window opens at launch.
///
/// The window is more than a permission prompt: it also downloads the models
/// and offers Login Items. So it appears once for every install, and after
/// that only while something macOS controls is still missing.
public enum FirstRunSetup {
    public static func shouldPresent(recordingReady: Bool, dictationReady: Bool, setupCompleted: Bool) -> Bool {
        !setupCompleted || !recordingReady || !dictationReady
    }
}

/// The first-run setup window.
///
/// Every step is optional to dismiss past, because each one is also reachable
/// from Settings. macOS prompts for each permission only once, so after a
/// denial the only way forward is System Settings, and every blocking
/// permission therefore always offers that route.
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
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set up Scribe")
                    .font(.title2.weight(.semibold))
                Text("Scribe records and transcribes meetings entirely on this Mac. A few things need to be in place first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            permissionsStep
            Divider()
            modelsStep
            Divider()
            launchAtLoginStep
            Divider()
            dictationStep

            HStack {
                if !isEverythingReady {
                    Text("Anything you skip can be changed later in Settings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(isEverythingReady ? "Done" : "Continue", action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    private var isEverythingReady: Bool {
        model.presentation.permissionPrompt == nil
            && modelInstaller.state == .installed
            && (!settings.dictationEnabled || DictationAccess.current().isReady)
    }

    // MARK: - Steps

    private var permissionsStep: some View {
        let prompt = model.presentation.permissionPrompt
        return step(
            title: "Recording permissions",
            systemImage: "lock.shield",
            done: prompt == nil,
            summary: prompt == nil
                ? "Scribe can record your microphone and system audio."
                : "Scribe needs access before it can record a meeting."
        ) {
            if let prompt {
                ForEach(prompt.requirements) { requirement in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(requirement.pane.displayName)
                            .font(.subheadline.weight(.medium))
                        Text(requirement.message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open \(requirement.pane.displayName) Settings") {
                            model.openSystemSettings(requirement.pane)
                        }
                    }
                }
                if prompt.canRequestInApp {
                    Button("Request Access") { model.requestPermissions() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var modelsStep: some View {
        step(
            title: "Transcription and speaker models",
            systemImage: "cpu",
            done: modelInstaller.state == .installed,
            summary: "Parakeet v3 transcribes speech and WeSpeaker tells voices apart. Both run locally; nothing leaves your Mac."
        ) {
            switch modelInstaller.state {
            case .checking:
                HStack { ProgressView().controlSize(.small); Text("Checking installed models…") }
                    .font(.footnote)
            case .installed:
                EmptyView()
            case .installing:
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(modelInstaller.completedBytes), total: Double(max(1, modelInstaller.totalBytes)))
                        .accessibilityLabel("Model download")
                    HStack {
                        Text("\(ByteCountFormatter.string(fromByteCount: modelInstaller.completedBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: modelInstaller.totalBytes, countStyle: .file))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { modelInstaller.cancel() }
                            .controlSize(.small)
                    }
                    Text("You can close this window; the download continues in the background.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .notInstalled:
                installButton("Download Models (\(downloadSize))")
            case .failed(let message):
                Text(message).font(.footnote).foregroundStyle(.red)
                installButton("Retry Download")
            }
            if let error = settings.modelsFolderError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private var launchAtLoginStep: some View {
        step(
            title: "Start Scribe at login",
            systemImage: "power",
            done: settings.launchAtLogin,
            summary: "Recommended. Scribe lives in the menu bar and notices meetings as they start, so it works best when it is always running."
        ) {
            Toggle("Launch at login", isOn: Binding(
                get: { settings.launchAtLogin },
                set: { settings.setLaunchAtLogin($0) }
            ))
            .toggleStyle(.switch)
            if let error = settings.launchAtLoginError {
                Text(error).font(.footnote).foregroundStyle(.red)
                if settings.launchAtLoginStatusMessage == error {
                    Button("Open Login Items Settings") { SMAppService.openSystemSettingsLoginItems() }
                }
            }
        }
    }

    @ViewBuilder
    private var dictationStep: some View {
        if settings.dictationEnabled {
            let access = DictationAccess.current()
            step(
                title: "Dictation",
                systemImage: "waveform",
                done: access.isReady,
                summary: "Microphone: \(access.microphone == .granted ? "Allowed" : "Not allowed") · Accessibility: \(access.accessibility ? "Allowed" : "Not allowed")"
            ) {
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
            step(
                title: "Optional: Dictation",
                systemImage: "waveform",
                done: nil,
                summary: "Hold or double-tap \(settings.dictationActivationKey.displayName) to dictate into other apps. Audio and text stay on this Mac."
            ) {
                Button("Enable Dictation") {
                    settings.dictationEnabled = true
                    Task { _ = await permissions.requestDictationAccess() }
                }
                .disabled(modelInstaller.state != .installed)
                if modelInstaller.state != .installed {
                    Text("Dictation uses the same models as transcription, so download them first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Building blocks

    /// A checklist row: a status glyph, a title, an explanation, and the
    /// controls that move the step along. `done == nil` marks an optional step.
    private func step<Content: View>(
        title: String,
        systemImage: String,
        done: Bool?,
        summary: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                switch done {
                case true: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case false: Image(systemName: "circle").foregroundStyle(.secondary)
                case nil: Image(systemName: systemImage).foregroundStyle(.secondary)
                }
            }
            .font(.title3)
            .frame(width: 24)
            .accessibilityLabel(done == true ? "Complete" : done == false ? "Incomplete" : "Optional")

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                content()
            }
        }
    }

    private var downloadSize: String {
        ByteCountFormatter.string(fromByteCount: modelInstaller.totalBytes, countStyle: .file)
    }

    private func installButton(_ title: String) -> some View {
        Button(title) { modelInstaller.install(directory: settings.modelsFolderURL) }
            .buttonStyle(.borderedProminent)
            .disabled(modelInstaller.isBusy)
    }
}
