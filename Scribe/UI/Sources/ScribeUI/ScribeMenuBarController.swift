import AppKit
import Combine
import Platform

/// Owns the status item and its menu.
///
/// The menu is AppKit rather than SwiftUI for two reasons that are really one.
/// A `MenuBarExtra` rebuilds its whole `NSMenu` whenever the state behind it
/// changes, and this menu's state changes every second while a recording runs,
/// which closed the Application and Microphone submenus a moment after they
/// opened. And no SwiftUI menu can lay two buttons out side by side, which the
/// transport row needs.
///
/// So the split here is deliberate: structure is built once per opening, in
/// `menuNeedsUpdate`, and everything that changes while the menu is on screen —
/// the elapsed time, the transport row — is applied by editing the existing
/// items in place. Nothing is added or removed under an open menu, so a submenu
/// stays open exactly as long as the pointer is on it.
@MainActor
public final class ScribeMenuBarController: NSObject, NSMenuDelegate {
    private let model: RecorderMenuModel
    /// Read at every opening rather than captured: both sections are values the
    /// host recomputes, and a menu built from a stale copy would show a finished
    /// download as still running.
    private let transcription: () -> TranscriptionMenuCommands?
    private let updates: () -> UpdateMenuCommands?
    private let openSettings: () -> Void

    private let statusItem: NSStatusItem
    /// Internal, not private, so the menu a build produces can be inspected
    /// without a running status bar.
    let menu = NSMenu()
    private let transportView = RecordingTransportView()
    private let transportRow = NSMenuItem()
    private let statusItemRow = NSMenuItem()
    private let copyTimestampRow = NSMenuItem()
    let applicationMenu = NSMenu()
    let microphoneMenu = NSMenu()
    let recordingModeMenu = NSMenu()
    private var presentationObservation: AnyCancellable?

    public init(
        model: RecorderMenuModel,
        image: NSImage?,
        accessibilityLabel: String,
        transcription: @escaping () -> TranscriptionMenuCommands?,
        updates: @escaping () -> UpdateMenuCommands?,
        openSettings: @escaping () -> Void
    ) {
        self.model = model
        self.transcription = transcription
        self.updates = updates
        self.openSettings = openSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        // The catalog renders the logo as a template image, so the menu bar
        // tints the mark itself and it stays legible in both appearances.
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.setAccessibilityLabel(accessibilityLabel)

        for submenu in [menu, applicationMenu, microphoneMenu, recordingModeMenu] {
            // Rows are enabled from the presentation, not inferred from whether
            // something can respond to their action.
            submenu.autoenablesItems = false
            submenu.delegate = self
        }
        statusItem.menu = menu

        transportView.startAction = { [weak self] in self?.perform { $0.startRecording() } }
        transportView.pauseAction = { [weak self] in self?.perform { $0.pauseRecording() } }
        transportView.resumeAction = { [weak self] in self?.perform { $0.resumeRecording() } }
        transportView.stopAction = { [weak self] in self?.perform { $0.stopRecording() } }

        copyTimestampRow.target = self
        copyTimestampRow.action = #selector(copyTimestamp)

        presentationObservation = model.$presentation.sink { [weak self] presentation in
            self?.applyLiveState(presentation)
        }
    }

    /// Where the status item is on screen, for anything that has to appear
    /// under it. `nil` when the item is not on the menu bar — a bar with no
    /// room left hides items rather than shrinking them.
    public var statusItemAnchor: NSRect? {
        guard let button = statusItem.button, let window = button.window, statusItem.isVisible else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    // MARK: NSMenuDelegate

    public func menuNeedsUpdate(_ menu: NSMenu) {
        switch menu {
        case self.menu: rebuildRootMenu()
        case applicationMenu: rebuildApplicationMenu()
        case microphoneMenu: rebuildMicrophoneMenu()
        case recordingModeMenu: rebuildRecordingModeMenu()
        default: break
        }
    }

    /// Sources are re-enumerated at every opening so an application launched
    /// after Scribe still appears. The answer arrives after the menu is already
    /// on screen, which is why the two source submenus fill themselves in from
    /// their own `menuNeedsUpdate` instead of being built here.
    public func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        model.menuDidAppear()
    }

    public func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        model.menuDidDisappear()
    }

    // MARK: Live state

    /// The only updates allowed while the menu is open: no item is added or
    /// removed, so an open submenu is never torn out from under the pointer.
    private func applyLiveState(_ presentation: MenuPresentation) {
        transportView.apply(presentation)
        statusItemRow.title = presentation.statusTitle
        statusItemRow.image = NSImage(systemSymbolName: presentation.statusSymbol, accessibilityDescription: nil)
        applyCopyTimestampItem(copyTimestampRow, presentation: presentation)
    }

    private func perform(_ action: (RecorderMenuModel) -> Void) {
        action(model)
        // A transport button is a command like any menu item, so it dismisses
        // the menu; the status item's own icon reports what happened next.
        menu.cancelTracking()
    }

    // MARK: Menu construction

    private func rebuildRootMenu() {
        let presentation = model.presentation
        menu.removeAllItems()

        transportRow.view = transportView
        menu.addItem(transportRow)
        transportView.apply(presentation)

        statusItemRow.isEnabled = false
        applyLiveState(presentation)
        menu.addItem(statusItemRow)
        if let detail = presentation.statusDetail {
            menu.addItem(.disabled(detail))
        }

        applyCopyTimestampItem(copyTimestampRow, presentation: presentation)
        menu.addItem(copyTimestampRow)

        if let prompt = presentation.permissionPrompt {
            menu.addItem(.separator())
            menu.addItem(.disabled(prompt.title))
            if prompt.canRequestInApp {
                menu.addItem(ActionMenuItem(title: "Request Access…") { [model] in model.requestPermissions() })
            }
            for pane in prompt.settingsRoutes {
                menu.addItem(ActionMenuItem(title: "Open \(pane.displayName) Settings…") { [model] in
                    model.openSystemSettings(pane)
                })
            }
        }

        if presentation.recoveryNotice != nil || !presentation.processingLines.isEmpty {
            menu.addItem(.separator())
        }
        // Launch recovery, reported before background work: it explains why
        // there is processing to do that this session did not start.
        if let notice = presentation.recoveryNotice {
            menu.addItem(.disabled(notice))
        }
        // Background work is listed separately from capture: the recorder above
        // may already be idle and ready for the next meeting.
        for line in presentation.processingLines {
            menu.addItem(.disabled(line))
        }

        menu.addItem(.separator())
        menu.addItem(submenuItem(title: "Recording Mode", submenu: recordingModeMenu))
        if presentation.recordingMode == .systemAudioAndMicrophone {
            menu.addItem(submenuItem(title: "Application", submenu: applicationMenu))
        } else {
            menu.addItem(.disabled("Microphone-only recording — no application needed"))
        }
        menu.addItem(submenuItem(title: "Microphone", submenu: microphoneMenu))

        // Shortcut registration can fail without disabling anything here.
        if !presentation.shortcutIssues.isEmpty {
            menu.addItem(.separator())
            for issue in presentation.shortcutIssues {
                menu.addItem(.disabled(issue))
            }
        }

        if let transcription = transcription() {
            menu.addItem(.separator())
            // Transcription is reported separately from capture and from audio
            // cleanup: all three run independently and a person needs to see
            // which one is busy.
            for line in transcription.statusLines {
                menu.addItem(.disabled(line))
            }
            if let failure = transcription.failure {
                menu.addItem(.disabled(failure))
            }
            menu.addItem(ActionMenuItem(title: "Transcripts…", handler: transcription.openTranscripts))
            menu.addItem(ActionMenuItem(title: "Transcribe Folder…", handler: transcription.transcribeFolder))
            if let openSpeakers = transcription.openSpeakers {
                menu.addItem(ActionMenuItem(title: "Speakers…", handler: openSpeakers))
            }
        }

        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(title: "Open Recordings Folder") { [model] in model.openRecordingsFolder() })
        menu.addItem(ActionMenuItem(title: "Settings…", handler: openSettings))

        if let updates = updates() {
            menu.addItem(.separator())
            addUpdateItems(updates)
        }

        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(title: "Quit Scribe") { [model] in model.quit() })
    }

    private func addUpdateItems(_ updates: UpdateMenuCommands) {
        let check = ActionMenuItem(title: "Check for Updates…", handler: updates.checkForUpdates)
        switch updates.state {
        case .idle:
            menu.addItem(check)
        case .checking:
            menu.addItem(.disabled("Checking for updates…"))
            check.isEnabled = false
            menu.addItem(check)
        case .upToDate:
            menu.addItem(.disabled("Scribe is up to date"))
            menu.addItem(check)
        case .updateAvailable(let version):
            menu.addItem(.disabled("Scribe \(version) is available"))
            menu.addItem(ActionMenuItem(title: "Download Update…", handler: updates.downloadUpdate))
            menu.addItem(check)
        case .downloading:
            menu.addItem(.disabled("Downloading and verifying update…"))
        case .readyToInstall(let version):
            menu.addItem(.disabled("Scribe \(version) is ready to install"))
            menu.addItem(ActionMenuItem(title: "Restart and Install", handler: updates.installUpdate))
        case .installing:
            menu.addItem(.disabled("Restarting to install update…"))
        case .failed(let message):
            menu.addItem(.disabled(message))
            menu.addItem(check)
        }
    }

    @objc private func copyTimestamp() {
        model.copyTimestamp()
    }

    private func applyCopyTimestampItem(_ item: NSMenuItem, presentation: MenuPresentation) {
        item.title = "Copy Timestamp"
        item.isEnabled = presentation.isCopyTimestampEnabled
        let shortcut = presentation.copyTimestampShortcut
        item.keyEquivalent = shortcut.keyEquivalentCharacter
        item.keyEquivalentModifierMask = shortcut.menuModifierMask
    }

    private func submenuItem(title: String, submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func rebuildApplicationMenu() {
        let presentation = model.presentation
        applicationMenu.removeAllItems()
        applicationMenu.addItem(selection(
            title: "Choose…",
            isSelected: presentation.selectedApplicationID == nil
        ) { [model] in model.selectApplication(nil) })
        // A remembered application that is not running right now keeps its own
        // row rather than silently clearing the choice, since a meeting
        // application is usually launched after Scribe.
        if let unavailable = presentation.unavailableSelectedApplication {
            applicationMenu.addItem(selection(
                title: InstalledApplicationName.unavailableLabel(for: unavailable),
                isSelected: true
            ) { [model] in model.selectApplication(unavailable.id) })
        }
        for application in presentation.applications {
            applicationMenu.addItem(selection(
                title: application.name,
                isSelected: application.id == presentation.selectedApplicationID
            ) { [model] in model.selectApplication(application.id) })
        }
    }

    private func rebuildMicrophoneMenu() {
        let presentation = model.presentation
        microphoneMenu.removeAllItems()
        microphoneMenu.addItem(selection(
            title: presentation.systemDefaultMicrophoneLabel,
            isSelected: presentation.selectedMicrophoneID == nil
        ) { [model] in model.selectMicrophone(nil) })
        // Shown rather than substituted: capture binds the chosen device and
        // never falls back to another one, so the list must not pretend a
        // different device is chosen.
        if let unavailable = presentation.unavailableSelectedMicrophone {
            microphoneMenu.addItem(selection(title: unavailable.label, isSelected: true) { [model] in
                model.selectMicrophone(unavailable.id)
            })
        }
        for microphone in presentation.microphones {
            microphoneMenu.addItem(selection(
                title: microphone.name,
                isSelected: microphone.id == presentation.selectedMicrophoneID
            ) { [model] in model.selectMicrophone(microphone.id) })
        }
    }

    private func rebuildRecordingModeMenu() {
        let selected = model.presentation.recordingMode
        recordingModeMenu.removeAllItems()
        recordingModeMenu.addItem(selection(
            title: RecordingMode.systemAudioAndMicrophone.menuTitle,
            isSelected: selected == .systemAudioAndMicrophone
        ) { [weak self] in
            self?.perform { $0.selectRecordingMode(.systemAudioAndMicrophone) }
        })
        recordingModeMenu.addItem(selection(
            title: RecordingMode.microphoneOnly.menuTitle,
            isSelected: selected == .microphoneOnly
        ) { [weak self] in
            self?.perform { $0.selectRecordingMode(.microphoneOnly) }
        })
    }

    private func selection(title: String, isSelected: Bool, handler: @escaping () -> Void) -> NSMenuItem {
        let item = ActionMenuItem(title: title, handler: handler)
        item.state = isSelected ? .on : .off
        return item
    }
}

/// A menu item that carries its own action, so the whole menu can be described
/// where it is built instead of being spread across selectors and tags.
private final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { handler() }
}

private extension NSMenuItem {
    /// A row that states a fact. Menus have no other way to show one.
    static func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

private extension GlobalShortcut {
    var menuModifierMask: NSEvent.ModifierFlags {
        var mask: NSEvent.ModifierFlags = []
        if usesControl { mask.insert(.control) }
        if usesOption { mask.insert(.option) }
        if usesShift { mask.insert(.shift) }
        if usesCommand { mask.insert(.command) }
        return mask
    }
}
