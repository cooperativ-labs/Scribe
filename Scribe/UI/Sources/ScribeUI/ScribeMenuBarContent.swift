import Platform
import SwiftUI

/// The contents of the menu-bar item.
///
/// Every row reads from `MenuPresentation` and every action submits a command,
/// so the menu has no state of its own and renders identically for the mock
/// coordinator and for the capture-backed one.
public struct ScribeMenuBarContent: View {
    @ObservedObject private var model: RecorderMenuModel
    /// Absent when the transcription module is not composed into this build; the
    /// menu then shows exactly what it showed before transcription existed.
    private let transcription: TranscriptionMenuCommands?
    private let updates: UpdateMenuCommands?

    public init(
        model: RecorderMenuModel,
        transcription: TranscriptionMenuCommands? = nil,
        updates: UpdateMenuCommands? = nil
    ) {
        self.model = model
        self.transcription = transcription
        self.updates = updates
    }

    public var body: some View {
        let presentation = model.presentation

        Group {
            Label(presentation.statusTitle, systemImage: presentation.statusSymbol)
            if let detail = presentation.statusDetail {
                Text(detail)
            }

            if let prompt = presentation.permissionPrompt {
                Divider()
                Text(prompt.title)
                if prompt.canRequestInApp {
                    Button("Request Access…") { model.requestPermissions() }
                }
                ForEach(prompt.settingsRoutes) { pane in
                    Button("Open \(pane.displayName) Settings…") { model.openSystemSettings(pane) }
                }
            }

            if presentation.recoveryNotice != nil || !presentation.processingLines.isEmpty {
                Divider()
            }
            if let notice = presentation.recoveryNotice {
                // Launch recovery, reported before background work: it explains
                // why there is processing to do that this session did not start.
                Text(notice)
            }
            if !presentation.processingLines.isEmpty {
                // Background work is listed separately from capture: the recorder
                // above may already be idle and ready for the next meeting.
                ForEach(presentation.processingLines, id: \.self) { line in
                    Text(line)
                }
            }

            Divider()
            Button("Start Recording") { model.startRecording() }
                .disabled(!presentation.isStartEnabled)
            Button("Stop Recording") { model.stopRecording() }
                .disabled(!presentation.isStopEnabled)

            Divider()
            Picker("Application", selection: model.selectedApplication) {
                Text("Choose…").tag(String?.none)
                if let unavailable = presentation.unavailableSelectedApplication {
                    Text(InstalledApplicationName.unavailableLabel(for: unavailable)).tag(String?.some(unavailable.id))
                }
                ForEach(presentation.applications) { application in
                    Text(application.name).tag(String?.some(application.id))
                }
            }
            Picker("Microphone", selection: model.selectedMicrophone) {
                Text(presentation.systemDefaultMicrophoneLabel).tag(String?.none)
                if let unavailable = presentation.unavailableSelectedMicrophone {
                    Text(unavailable.label).tag(String?.some(unavailable.id))
                }
                ForEach(presentation.microphones) { microphone in
                    Text(microphone.name).tag(String?.some(microphone.id))
                }
            }

            if !presentation.shortcutIssues.isEmpty {
                Divider()
                // Shortcut registration can fail without disabling anything here.
                ForEach(presentation.shortcutIssues, id: \.self) { issue in
                    Text(issue)
                }
            }

            if let transcription {
                Divider()
                // Transcription is reported separately from capture and from
                // audio cleanup: all three run independently and a person needs
                // to see which one is busy.
                ForEach(transcription.statusLines, id: \.self) { line in
                    Text(line)
                }
                if let failure = transcription.failure {
                    Text(failure)
                }
                Button("Transcripts…") { transcription.openTranscripts() }
                Button("Transcribe Folder…") { transcription.transcribeFolder() }
                if let openSpeakers = transcription.openSpeakers {
                    Button("Speakers…") { openSpeakers() }
                }
            }

            Divider()
            Button("Open Recordings Folder") { model.openRecordingsFolder() }
            SettingsLink { Text("Settings…") }

            if let updates {
                Divider()
                updateSection(updates)
            }

            Divider()
            Button("Quit Scribe") { model.quit() }
        }
        .onAppear { model.menuDidAppear() }
        .onDisappear { model.menuDidDisappear() }
    }

    @ViewBuilder
    private func updateSection(_ updates: UpdateMenuCommands) -> some View {
        switch updates.state {
        case .idle:
            Button("Check for Updates…") { updates.checkForUpdates() }
        case .checking:
            Text("Checking for updates…")
            Button("Check for Updates…") { updates.checkForUpdates() }
                .disabled(true)
        case .upToDate:
            Text("Scribe is up to date")
            Button("Check for Updates…") { updates.checkForUpdates() }
        case .updateAvailable(let version):
            Text("Scribe \(version) is available")
            Button("Download Update…") { updates.downloadUpdate() }
            Button("Check for Updates…") { updates.checkForUpdates() }
        case .downloading:
            Text("Downloading and verifying update…")
        case .readyToInstall(let version):
            Text("Scribe \(version) is ready to install")
            Button("Restart and Install") { updates.installUpdate() }
        case .installing:
            Text("Restarting to install update…")
        case .failed(let message):
            Text(message)
            Button("Check for Updates…") { updates.checkForUpdates() }
        }
    }
}
