import Platform
import SwiftUI
import Vocabulary

/// The compact settings pane used by the menu-bar app, split into General,
/// Recording, Transcription, and Dictation tabs.
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
    private let permissions: PermissionService?
    /// Requests from elsewhere in the app to open Settings at one section.
    @ObservedObject private var focus: SettingsFocusModel
    @State private var isChoosingRecordingsFolder = false
    @State private var folderSelectionError: String?
    @State private var highlightedSection: SettingsSection?
    @State private var selectedTab: SettingsTab = .general
    @State private var dictationAccess = DictationAccess.current()
    @ObservedObject private var modelInstaller: TranscriptionModelInstaller
    @StateObject private var shortcutCapture: ShortcutCaptureModel

    /// `onShortcutCaptureChange` is called with `true` while a shortcut field is
    /// listening for keys and `false` when it stops, so the owner can take the
    /// registered global shortcuts down and reapply them afterwards.
    public init(
        settings: ScribeSettings,
        sources: RecorderMenuModel,
        meetingDetector: MeetingDetector? = nil,
        calendar: CalendarMeetingService? = nil,
        vocabulary: VocabularyViewModel? = nil,
        permissions: PermissionService? = nil,
        focus: SettingsFocusModel = SettingsFocusModel(),
        onShortcutCaptureChange: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        self.settings = settings
        self.modelInstaller = settings.modelInstaller
        self.sources = sources
        self.meetingDetector = meetingDetector
        self.calendar = calendar
        self.vocabulary = vocabulary
        self.permissions = permissions
        self.focus = focus
        _shortcutCapture = StateObject(wrappedValue: ShortcutCaptureModel(onCaptureChange: onShortcutCaptureChange))
    }

    public var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    ForEach(SettingsTab.allCases, id: \.self) { tab in
                        settingsTabButton(tab)
                    }
                }
                .padding(.top, 14)
                .padding(.bottom, 8)

                selectedTabContent
            }
            .onChange(of: focus.requestCount) { showRequestedSection(with: proxy) }
            .onAppear { showRequestedSection(with: proxy) }
        }
        .frame(width: 560, height: 640)
        .animation(.snappy, value: highlightedSection)
        // Enumerated on open, as the menu does, so an application launched after
        // Scribe and a microphone plugged in a moment ago both appear.
        .onAppear { sources.refreshSources() }
        .onAppear { settings.refreshLaunchAtLoginStatus() }
        .onChange(of: selectedTab) { shortcutCapture.stop() }
        .onDisappear { shortcutCapture.stop() }
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

    private var selectedTabContent: some View {
        Group {
            switch selectedTab {
            case .general: generalTab
            case .recording: recordingTab
            case .transcription: transcriptionTab
            case .dictation: dictationTab
            }
        }
    }

    private func settingsTabButton(_ tab: SettingsTab) -> some View {
        let isSelected = selectedTab == tab

        return Button {
            withAnimation(.snappy) { selectedTab = tab }
        } label: {
            Label(tab.title, systemImage: tab.symbol)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    isSelected ? Color.accentColor.opacity(0.14) : .clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityValue(isSelected ? "Selected" : "")
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section("Startup") {
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

            Section("Global shortcuts") {
                shortcutField("Start recording", $settings.startShortcut, default: .defaultStart, action: .start)
                shortcutField("Stop recording", $settings.stopShortcut, default: .defaultStop, action: .stop)
                shortcutField(
                    "Paste timestamp",
                    $settings.pasteTimestampShortcut,
                    default: .defaultPasteTimestamp,
                    action: .pasteTimestamp
                )
                Text("Click a shortcut, then press the keys you want; Escape cancels. Include ⌘, ⌃, or ⌥ (function keys work alone). Paste timestamp copies text such as “at 01:23” and pastes it at the cursor in your active app. Pasting needs Accessibility access; until that is granted, the text is still on the clipboard. If another app already owns a shortcut, Scribe will show the conflict and keep its menu commands available.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func shortcutField(
        _ title: String,
        _ binding: Binding<GlobalShortcut>,
        default defaultShortcut: GlobalShortcut,
        action: HotkeyAction
    ) -> some View {
        ShortcutRecorderField(
            title: title,
            shortcut: binding,
            defaultShortcut: defaultShortcut,
            owner: { candidate in
                assignedShortcuts.first { $0.action != action && $0.shortcut == candidate }?.title
            },
            capture: shortcutCapture
        )
    }

    private var assignedShortcuts: [(action: HotkeyAction, title: String, shortcut: GlobalShortcut)] {
        [
            (.start, "Start recording", settings.startShortcut),
            (.stop, "Stop recording", settings.stopShortcut),
            (.pasteTimestamp, "Paste timestamp", settings.pasteTimestampShortcut)
        ]
    }

    // MARK: - Recording

    private var recordingTab: some View {
        let presentation = sources.presentation

        return Form {
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
                Toggle("Keep recording files for debugging", isOn: $settings.keepRecordingFilesForDebugging)
                Text("By default, Scribe deletes the meeting folder and its component audio after the final recording has been safely copied into Transcriptions. Turn this on to retain those files for debugging and reprocessing.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let meetingDetector {
                MeetingDetectionSettingsView(settings: settings, detector: meetingDetector)
            }

            if let calendar {
                CalendarSettingsView(settings: settings, calendar: calendar)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Transcription

    private var transcriptionTab: some View {
        Form {
            Section("Processing") {
                Toggle("Transcribe when the final recording is ready", isOn: $settings.transcribeWhenFinalRecordingIsReady)
                Toggle("Identify me from my microphone", isOn: $settings.microphoneSpeakerPrior)
                Text("For remote calls with separate microphone and system tracks. Keep this off for in-room meetings: your microphone may capture other people. Labels are applied only when source evidence is clear.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Picker("Speakers", selection: $settings.transcriptionSpeakerCount) {
                    Text("Automatic").tag(RecorderSpeakerCountPreference.automatic)
                    ForEach(1...8, id: \.self) { count in
                        Text("Exactly \(count)").tag(RecorderSpeakerCountPreference.known(count))
                    }
                }
                Text("Automatic lets diarization choose. An exact count is for meetings you know were captured with that many speakers; it may use FluidAudio’s K-means fallback.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            TranscriptionModelSettingsView(settings: settings, installer: settings.modelInstaller)

            if let vocabulary {
                VocabularySettingsSection(
                    model: vocabulary,
                    isHighlighted: highlightedSection == .vocabulary
                )
                .id(SettingsSection.vocabulary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Dictation

    private var dictationTab: some View {
        Form {
            Section("Dictation") {
                Toggle("Enable dictation", isOn: $settings.dictationEnabled)
                    .disabled(modelInstaller.state != .installed)
                    .onChange(of: settings.dictationEnabled) {
                        guard settings.dictationEnabled else { return }
                        Task { dictationAccess = await permissions?.requestDictationAccess() ?? DictationAccess.current() }
                    }
                Text("Requires Microphone and Accessibility access. Your speech stays on this Mac.")
                    .font(.footnote).foregroundStyle(.secondary)
                permissionRow("Microphone", allowed: dictationAccess.microphone == .granted, pane: .microphone)
                permissionRow("Accessibility", allowed: dictationAccess.accessibility, pane: .accessibility)
                if !dictationAccess.keyboardListening {
                    permissionRow("Keyboard monitoring", allowed: false, pane: .inputMonitoring)
                    Text("On macOS 27 this access may appear with Accessibility under Device Control and Data Access.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !dictationAccess.isReady && settings.dictationEnabled {
                    Text("Dictation will start when access is granted.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if settings.dictationEnabled && settings.dictationSecureInputBlocked {
                    Text("Dictation is paused while Secure Keyboard Entry is on")
                        .foregroundStyle(.orange)
                }
                if settings.dictationEnabled && !settings.dictationRightCommandObserved {
                    Text("No right Command key event has been detected. If you remapped that key, restore its right Command mapping to use dictation.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if modelInstaller.state != .installed {
                    Text("Download the transcription model below to enable dictation.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .id(SettingsSection.dictation)

            TranscriptionModelSettingsView(settings: settings, installer: settings.modelInstaller)

            Section("How it works") {
                Text("Hold right ⌘ and speak; release to insert. Double-tap right ⌘ to keep listening; tap again to insert. Escape cancels.")
                    .foregroundStyle(.secondary)
            }
            Section("Insertion") {
                Toggle("Add a space before dictated text when needed", isOn: $settings.dictationLeadingSpace)
                Toggle("Add a space after dictated text", isOn: $settings.dictationTrailingSpace)
                Toggle("Restore clipboard after pasting", isOn: $settings.dictationRestoreClipboard)
            }
            Section("Indicator") {
                Picker("Position", selection: $settings.dictationIndicatorPosition) {
                    Text("Near the text cursor").tag("caret")
                    Text("Bottom center").tag("bottom")
                    Text("Off").tag("off")
                }
                Toggle("Play a sound when listening starts and stops", isOn: $settings.dictationPlaySounds)
            }
            Section("Language") {
                Picker("Language", selection: $settings.dictationLanguage) {
                    Text("Automatic").tag("automatic")
                    Text("English").tag("en")
                }
            }
            Section("Advanced") {
                Toggle("Keep model loaded while dictation is on", isOn: $settings.dictationKeepModelLoaded)
                if !settings.dictationKeepModelLoaded {
                    Stepper("Unload after \(settings.dictationIdleUnloadMinutes) minutes idle", value: $settings.dictationIdleUnloadMinutes, in: 1...60)
                }
                Stepper("Double-tap speed: \(settings.dictationDoubleTapMs) ms", value: $settings.dictationDoubleTapMs, in: 250...700, step: 25)
                Stepper("Hold threshold: \(settings.dictationHoldThresholdMs) ms", value: $settings.dictationHoldThresholdMs, in: 200...600, step: 25)
                Stepper("Maximum dictation: \(settings.dictationMaxDictationMinutes) minutes", value: $settings.dictationMaxDictationMinutes, in: 1...5)
                Toggle("Stop after 3 seconds of silence", isOn: $settings.dictationSilenceAutoStop)
            }
        }
        .formStyle(.grouped)
        .task {
            while !Task.isCancelled {
                dictationAccess = permissions?.dictationAccess() ?? DictationAccess.current()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func permissionRow(_ name: String, allowed: Bool, pane: SystemSettingsPane) -> some View {
        HStack {
            Label("\(name): \(allowed ? "Allowed" : "Not allowed")", systemImage: allowed ? "checkmark.circle.fill" : "exclamationmark.circle")
            Spacer()
            if !allowed {
                Button("Open System Settings") { permissions?.openSystemSettings(pane) }
            }
        }
    }

    /// Scrolls to whatever asked to be shown and marks it briefly.
    ///
    /// The mark matters more than the scroll: a person who pressed "Vocabulary"
    /// in the transcript window arrives on a tab of several sections and needs
    /// to be told which one answered them.
    private func showRequestedSection(with proxy: ScrollViewProxy) {
        guard let section = focus.section else { return }
        focus.clear()
        let tab = SettingsTab(containing: section)
        let switchesTab = selectedTab != tab
        selectedTab = tab
        highlightedSection = section
        Task {
            // A tab that was not showing has to lay out before its rows exist
            // to scroll to.
            if switchesTab { try? await Task.sleep(for: .milliseconds(100)) }
            withAnimation(.snappy) { proxy.scrollTo(section, anchor: .top) }
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

/// The tabs Settings is split into: the app itself, capturing audio, and
/// turning that audio into a transcript.
enum SettingsTab: Hashable, CaseIterable {
    case general
    case recording
    case transcription
    case dictation

    var title: String {
        switch self {
        case .general: "General"
        case .recording: "Recording"
        case .transcription: "Transcription"
        case .dictation: "Dictation"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .recording: "record.circle"
        case .transcription: "text.quote"
        case .dictation: "waveform"
        }
    }

    init(containing section: SettingsSection) {
        switch section {
        case .vocabulary: self = .transcription
        case .dictation: self = .dictation
        }
    }
}
