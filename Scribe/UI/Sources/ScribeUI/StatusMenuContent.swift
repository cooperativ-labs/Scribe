import Foundation
import Platform

/// Everything the status-item panel lists below its transport row, as plain
/// values.
///
/// The panel is SwiftUI, but what it says is decided here, so every state can
/// be built and asserted without putting a window on screen — the same reason
/// `MenuPresentation` exists for the recorder's own rows.
struct StatusMenuContent {
    var sections: [StatusMenuSection]

    /// Every row, in order, for code that only cares what is listed.
    var rows: [StatusMenuRow] { sections.flatMap(\.rows) }

    /// The command with this title, if one is listed.
    func command(titled title: String) -> StatusMenuCommand? {
        for row in rows {
            if case .command(let command) = row, command.title == title { return command }
        }
        return nil
    }

    /// The choice list with this title, if one is listed.
    func choices(titled title: String) -> StatusMenuChoices? {
        for row in rows {
            if case .choices(let choices) = row, choices.title == title { return choices }
        }
        return nil
    }

    /// The text of every row, commands and notes alike.
    var titles: [String] {
        rows.map { row in
            switch row {
            case .status(let title, _): title
            case .note(let text): text
            case .command(let command): command.title
            case .choices(let choices): choices.title
            }
        }
    }
}

/// A group of rows; the panel draws a divider between groups.
struct StatusMenuSection: Identifiable {
    let id: String
    var rows: [StatusMenuRow]
}

enum StatusMenuRow: Identifiable {
    /// What the recorder is doing, with its symbol.
    case status(title: String, symbol: String)
    /// A fact, not a control. Wraps rather than widening the panel.
    case note(String)
    case command(StatusMenuCommand)
    /// A single choice from a list, shown in place: a pop-up menu would be an
    /// `NSMenu`, which macOS will not show over another app's full-screen
    /// Space while Scribe has a Dock icon.
    case choices(StatusMenuChoices)

    var id: String {
        switch self {
        case .status: "status"
        case .note(let text): "note-\(text)"
        case .command(let command): "command-\(command.title)"
        case .choices(let choices): "choices-\(choices.title)"
        }
    }
}

/// A row that does something. Choosing one closes the panel, as a menu item
/// closes its menu.
struct StatusMenuCommand {
    let title: String
    var isEnabled = true
    /// The key that does the same thing, shown at the trailing edge.
    var shortcut: String?
    /// `nil` for an ordinary command; on or off for a setting the row toggles.
    var isOn: Bool?
    let perform: () -> Void
}

/// A list of mutually exclusive options under one heading.
///
/// Choosing an option leaves the panel open: it is a setting, and the person
/// can see it took effect in the summary beside the heading.
struct StatusMenuChoices {
    let title: String
    let options: [StatusMenuChoice]

    /// What is chosen now, shown beside the heading while the list is folded.
    var summary: String? { options.first(where: \.isSelected)?.title }
}

struct StatusMenuChoice: Identifiable {
    let id: String
    let title: String
    let isSelected: Bool
    let select: () -> Void
}

/// The dictation rows, when the host offers dictation at all.
struct DictationMenuInputs {
    let isEnabled: Bool
    let isSecureInputBlocked: Bool
    let toggle: () -> Void
    let openSettings: (() -> Void)?
}

extension StatusMenuContent {
    /// The rows under the transport controls, in the order the old menu used.
    @MainActor
    init(
        presentation: MenuPresentation,
        model: RecorderMenuModel,
        dictation: DictationMenuInputs?,
        transcription: TranscriptionMenuCommands?,
        updates: UpdateMenuCommands?,
        openSettings: @escaping () -> Void
    ) {
        var sections: [StatusMenuSection] = []

        var recorder: [StatusMenuRow] = []
        // The Record button already says the recorder is ready; an "Idle" row
        // would only repeat it.
        if presentation.statusTitle != "Idle" {
            recorder.append(.status(title: presentation.statusTitle, symbol: presentation.statusSymbol))
        }
        if let detail = presentation.statusDetail {
            recorder.append(.note(detail))
        }
        recorder.append(.command(StatusMenuCommand(
            title: "Paste Timestamp",
            isEnabled: presentation.isPasteTimestampEnabled,
            shortcut: presentation.pasteTimestampShortcut.displayName
        ) { model.pasteTimestamp() }))
        sections.append(StatusMenuSection(id: "recorder", rows: recorder))

        if let prompt = presentation.permissionPrompt {
            var rows: [StatusMenuRow] = [.note(prompt.title)]
            if prompt.canRequestInApp {
                rows.append(.command(StatusMenuCommand(title: "Request Access…") { model.requestPermissions() }))
            }
            for pane in prompt.settingsRoutes {
                rows.append(.command(StatusMenuCommand(title: "Open \(pane.displayName) Settings…") {
                    model.openSystemSettings(pane)
                }))
            }
            sections.append(StatusMenuSection(id: "permissions", rows: rows))
        }

        // Launch recovery comes before background work: it explains why there
        // is processing to do that this session did not start. Background work
        // is listed apart from capture, since the recorder may already be idle.
        let background = (presentation.recoveryNotice.map { [$0] } ?? []) + presentation.processingLines
        if !background.isEmpty {
            sections.append(StatusMenuSection(id: "background", rows: background.map(StatusMenuRow.note)))
        }

        var sources: [StatusMenuRow] = [.choices(Self.recordingModeChoices(presentation, model: model))]
        if presentation.recordingMode == .systemAudioAndMicrophone {
            sources.append(.choices(Self.applicationChoices(presentation, model: model)))
        } else {
            sources.append(.note("Microphone-only recording — no application needed"))
        }
        sources.append(.choices(Self.microphoneChoices(presentation, model: model)))
        sections.append(StatusMenuSection(id: "sources", rows: sources))

        if let dictation {
            var rows: [StatusMenuRow] = []
            if dictation.isEnabled, dictation.isSecureInputBlocked {
                rows.append(.note("Dictation is paused while Secure Keyboard Entry is on"))
            }
            rows.append(.command(StatusMenuCommand(
                title: dictation.isEnabled ? "Dictation: On" : "Dictation: Off",
                isOn: dictation.isEnabled,
                perform: dictation.toggle
            )))
            if let openSettings = dictation.openSettings {
                rows.append(.command(StatusMenuCommand(title: "Dictation Settings…", perform: openSettings)))
            }
            sections.append(StatusMenuSection(id: "dictation", rows: rows))
        }

        // Shortcut registration can fail without disabling anything here.
        if !presentation.shortcutIssues.isEmpty {
            sections.append(StatusMenuSection(id: "shortcuts", rows: presentation.shortcutIssues.map(StatusMenuRow.note)))
        }

        if let transcription {
            // Transcription is reported apart from capture and from audio
            // cleanup: all three run independently. Failure detail stays out.
            var rows = transcription.statusLines.map(StatusMenuRow.note)
            rows.append(.command(StatusMenuCommand(title: "Transcripts…", perform: transcription.openTranscripts)))
            rows.append(.command(StatusMenuCommand(title: "Transcribe Folder…", perform: transcription.transcribeFolder)))
            if let openSpeakers = transcription.openSpeakers {
                rows.append(.command(StatusMenuCommand(title: "Speakers…", perform: openSpeakers)))
            }
            sections.append(StatusMenuSection(id: "transcription", rows: rows))
        }

        var folders: [StatusMenuRow] = []
        if let transcription {
            folders.append(.command(StatusMenuCommand(
                title: "Open Transcriptions Folder",
                perform: transcription.openTranscriptionsFolder
            )))
        }
        folders.append(.command(StatusMenuCommand(title: "Open Recordings Folder") { model.openRecordingsFolder() }))
        folders.append(.command(StatusMenuCommand(title: "Settings…", perform: openSettings)))
        sections.append(StatusMenuSection(id: "folders", rows: folders))

        if let updates {
            sections.append(StatusMenuSection(id: "updates", rows: Self.updateRows(updates)))
        }

        sections.append(StatusMenuSection(id: "quit", rows: [
            .command(StatusMenuCommand(title: "Quit Scribe") { model.quit() }),
        ]))
        self.sections = sections
    }

    @MainActor
    private static func recordingModeChoices(_ presentation: MenuPresentation, model: RecorderMenuModel) -> StatusMenuChoices {
        StatusMenuChoices(title: "Recording Mode", options: [RecordingMode.systemAudioAndMicrophone, .microphoneOnly].map { mode in
            StatusMenuChoice(id: mode.menuTitle, title: mode.menuTitle, isSelected: presentation.recordingMode == mode) {
                model.selectRecordingMode(mode)
            }
        })
    }

    @MainActor
    private static func applicationChoices(_ presentation: MenuPresentation, model: RecorderMenuModel) -> StatusMenuChoices {
        var options = [StatusMenuChoice(id: "choose", title: "Choose…", isSelected: presentation.selectedApplicationID == nil) {
            model.selectApplication(nil)
        }]
        // A remembered application that is not running keeps its own row
        // rather than silently clearing the choice: a meeting application is
        // usually launched after Scribe.
        if let unavailable = presentation.unavailableSelectedApplication {
            options.append(StatusMenuChoice(
                id: unavailable.id,
                title: InstalledApplicationName.unavailableLabel(for: unavailable),
                isSelected: true
            ) { model.selectApplication(unavailable.id) })
        }
        for application in presentation.applications {
            options.append(StatusMenuChoice(
                id: application.id,
                title: application.name,
                isSelected: application.id == presentation.selectedApplicationID
            ) { model.selectApplication(application.id) })
        }
        return StatusMenuChoices(title: "Application", options: options)
    }

    @MainActor
    private static func microphoneChoices(_ presentation: MenuPresentation, model: RecorderMenuModel) -> StatusMenuChoices {
        var options = [StatusMenuChoice(
            id: "system-default",
            title: presentation.systemDefaultMicrophoneLabel,
            isSelected: presentation.selectedMicrophoneID == nil
        ) { model.selectMicrophone(nil) }]
        // Shown rather than substituted: capture binds the chosen device and
        // never falls back to another one.
        if let unavailable = presentation.unavailableSelectedMicrophone {
            options.append(StatusMenuChoice(id: unavailable.id, title: unavailable.label, isSelected: true) {
                model.selectMicrophone(unavailable.id)
            })
        }
        for microphone in presentation.microphones {
            options.append(StatusMenuChoice(
                id: microphone.id,
                title: microphone.name,
                isSelected: microphone.id == presentation.selectedMicrophoneID
            ) { model.selectMicrophone(microphone.id) })
        }
        return StatusMenuChoices(title: "Microphone", options: options)
    }

    private static func updateRows(_ updates: UpdateMenuCommands) -> [StatusMenuRow] {
        let check = StatusMenuCommand(title: "Check for Updates…", perform: updates.checkForUpdates)
        switch updates.state {
        case .idle:
            return [.command(check)]
        case .checking:
            var disabled = check
            disabled.isEnabled = false
            return [.note("Checking for updates…"), .command(disabled)]
        case .upToDate:
            return [.note("Scribe is up to date"), .command(check)]
        case .updateAvailable(let version):
            return [
                .note("Scribe \(version) is available"),
                .command(StatusMenuCommand(title: "Download Update…", perform: updates.downloadUpdate)),
                .command(check),
            ]
        case .downloading:
            return [.note("Downloading and verifying update…")]
        case .readyToInstall(let version):
            return [
                .note("Scribe \(version) is ready to install"),
                .command(StatusMenuCommand(title: "Restart and Install", perform: updates.installUpdate)),
            ]
        case .installing:
            return [.note("Restarting to install update…")]
        case .failed:
            // No diagnostic text: the Check row is the recovery path.
            return [.note("Update failed"), .command(check)]
        }
    }
}
