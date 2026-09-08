import Platform
import SwiftUI
import Vocabulary

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
    /// Absent in a build without calendar naming; the section is then not shown.
    private let calendar: CalendarMeetingService?
    /// Absent only when the vocabulary store could not be opened; Settings then
    /// hides the section rather than showing an editor that can save nothing.
    private let vocabulary: VocabularyViewModel?
    /// Requests from elsewhere in the app to open Settings at one section.
    @ObservedObject private var focus: SettingsFocusModel
    @State private var isChoosingRecordingsFolder = false
    @State private var folderSelectionError: String?
    @State private var highlightedSection: SettingsSection?

    public init(
        settings: ScribeSettings,
        sources: RecorderMenuModel,
        meetingDetector: MeetingDetector? = nil,
        calendar: CalendarMeetingService? = nil,
        vocabulary: VocabularyViewModel? = nil,
        focus: SettingsFocusModel = SettingsFocusModel()
    ) {
        self.settings = settings
        self.sources = sources
        self.meetingDetector = meetingDetector
        self.calendar = calendar
        self.vocabulary = vocabulary
        self.focus = focus
    }

    public var body: some View {
        ScrollViewReader { proxy in
            settingsForm
                .onChange(of: focus.requestCount) { showRequestedSection(with: proxy) }
                .onAppear { showRequestedSection(with: proxy) }
        }
    }

    private var settingsForm: some View {
        let presentation = sources.presentation

        return Form {
            Section("General") {
                Toggle(
                    "Launch Scribe at login",
                    isOn: Binding(
                        get: { settings.launchAtLogin },
                        set: { settings.setLaunchAtLogin($0) }
                    )
                )
                if let launchAtLoginError = settings.launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else {
                    Text("Start Scribe automatically when you sign in to your Mac.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

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

            if let vocabulary {
                VocabularySettingsSection(
                    model: vocabulary,
                    isHighlighted: highlightedSection == .vocabulary
                )
                .id(SettingsSection.vocabulary)
            }

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

            if let calendar {
                CalendarSettingsView(settings: settings, calendar: calendar)
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
                Picker("Copy timestamp", selection: $settings.copyTimestampShortcut) {
                    ForEach(GlobalShortcut.commonChoices) { shortcut in
                        Text(shortcut.displayName).tag(shortcut)
                    }
                }
                Text("Choose a different shortcut for each action. Copy timestamp puts the recording's elapsed time on the clipboard so it can be pasted into notes. If another app already owns one, Scribe will show the conflict and keep its menu commands available.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
        .frame(width: 560, height: 820)
        .animation(.snappy, value: highlightedSection)
        // Enumerated on open, as the menu does, so an application launched after
        // Scribe and a microphone plugged in a moment ago both appear.
        .onAppear { sources.refreshSources() }
        .onAppear { settings.refreshLaunchAtLoginStatus() }
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

    /// Scrolls to whatever asked to be shown and marks it briefly.
    ///
    /// The mark matters more than the scroll: a person who pressed "Vocabulary"
    /// in the transcript window arrives in a window of eight sections and needs
    /// to be told which one answered them.
    private func showRequestedSection(with proxy: ScrollViewProxy) {
        guard let section = focus.section else { return }
        focus.clear()
        withAnimation(.snappy) { proxy.scrollTo(section, anchor: .top) }
        highlightedSection = section
        Task {
            try? await Task.sleep(for: .seconds(3))
            if highlightedSection == section { highlightedSection = nil }
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
