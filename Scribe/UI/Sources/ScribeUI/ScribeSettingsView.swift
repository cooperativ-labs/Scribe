import Platform
import SwiftUI

/// The compact settings pane used by the menu-bar app.
///
/// Source selection reads from and writes to the same `RecorderMenuModel` as
/// the menu, so the pickers here show the applications and microphones that
/// exist right now, by name, and a choice made in either place is the one that
/// gets remembered.
public struct ScribeSettingsView: View {
    @ObservedObject private var settings: ScribeSettings
    @ObservedObject private var sources: RecorderMenuModel
    /// Absent in a build without detection; the section is then not shown.
    private let meetingDetector: MeetingDetector?
    @State private var isChoosingRecordingsFolder = false
    @State private var folderSelectionError: String?

    public init(settings: ScribeSettings, sources: RecorderMenuModel, meetingDetector: MeetingDetector? = nil) {
        self.settings = settings
        self.sources = sources
        self.meetingDetector = meetingDetector
    }

    public var body: some View {
        let presentation = sources.presentation

        Form {
            Section("Recordings") {
                LabeledContent("Folder") {
                    Text(settings.recordingsFolderURL.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                Button("Choose Folder…") {
                    isChoosingRecordingsFolder = true
                }
                if let folderSelectionError {
                    Text(folderSelectionError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            TranscriptionModelSettingsView(settings: settings, installer: settings.modelInstaller)

            Section("Processing") {
                Toggle("Transcribe when the final recording is ready", isOn: $settings.transcribeWhenFinalRecordingIsReady)
            }

            Section {
                Picker("Application", selection: sources.selectedApplication) {
                    Text("None").tag(String?.none)
                    if let unavailable = presentation.unavailableSelectedApplication {
                        Text(InstalledApplicationName.unavailableLabel(for: unavailable)).tag(String?.some(unavailable.id))
                    }
                    ForEach(presentation.applications) { application in
                        Text(application.name).tag(String?.some(application.id))
                    }
                }
                Picker("Microphone", selection: sources.selectedMicrophone) {
                    Text(presentation.systemDefaultMicrophoneLabel).tag(String?.none)
                    if let unavailable = presentation.unavailableSelectedMicrophone {
                        Text(unavailable.label).tag(String?.some(unavailable.id))
                    }
                    ForEach(presentation.microphones) { microphone in
                        Text(microphone.name).tag(String?.some(microphone.id))
                    }
                }
                Text(sourcesFootnote(presentation))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                HStack {
                    Text("Sources")
                    Spacer()
                    Button("Refresh") { sources.refreshSources() }
                        .controlSize(.small)
                }
            }

            if let meetingDetector {
                MeetingDetectionSettingsView(settings: settings, detector: meetingDetector)
            }

            Section("Global shortcuts") {
                Picker("Start recording", selection: $settings.startShortcut) {
                    ForEach(GlobalShortcut.commonChoices) { shortcut in
                        Text(shortcut.displayName).tag(shortcut)
                    }
                }
                Picker("Stop recording", selection: $settings.stopShortcut) {
                    ForEach(GlobalShortcut.commonChoices) { shortcut in
                        Text(shortcut.displayName).tag(shortcut)
                    }
                }
                Text("Choose different shortcuts for starting and stopping. If another app already owns one, Scribe will show the conflict and keep its menu commands available.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
        .frame(width: 560, height: 820)
        // Enumerated on open, as the menu does, so an application launched after
        // Scribe and a microphone plugged in a moment ago both appear.
        .onAppear { sources.refreshSources() }
        .fileImporter(
            isPresented: $isChoosingRecordingsFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    try settings.setRecordingsFolder(url)
                    folderSelectionError = nil
                } catch {
                    folderSelectionError = error.localizedDescription
                }
            case .failure(let error):
                folderSelectionError = error.localizedDescription
            }
        }
    }

    private func sourcesFootnote(_ presentation: MenuPresentation) -> String {
        var lines = [
            "Scribe records one application's audio alongside the microphone. Only applications that are running now are listed; open the meeting application first if it is missing.",
        ]
        if presentation.applications.isEmpty, presentation.permissionPrompt != nil {
            lines.append("Applications appear once Screen & System Audio Recording access is granted.")
        }
        lines.append("System Default follows whichever input macOS has selected when the recording starts.")
        return lines.joined(separator: " ")
    }
}
