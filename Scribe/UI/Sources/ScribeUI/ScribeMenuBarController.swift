import AppKit
import Combine
import Platform
import SwiftUI

/// Owns the status item and the panel it opens.
///
/// The panel is a window, not an `NSMenu`. Scribe is a regular app with a Dock
/// icon, and macOS does not show a regular app's status-item menu over another
/// app's full-screen Space — the click registers and nothing appears. A
/// non-activating panel that joins every Space, full-screen ones included, is
/// the supported way for such an app to put content under its status item
/// (SwiftUI's `MenuBarExtra` with the `.window` style is the same thing). It
/// also lays the transport buttons out side by side, and updates in place
/// while open, which the menu could only do by editing items under the pointer.
@MainActor
public final class ScribeMenuBarController: NSObject {
    private let model: RecorderMenuModel
    /// Read at every opening and on every recorder change while open, rather
    /// than captured: both sections are values the host recomputes.
    private let transcription: () -> TranscriptionMenuCommands?
    private let updates: () -> UpdateMenuCommands?
    private let openSettings: () -> Void
    /// The plain label for the status item, kept so the recording dot can be
    /// added to and taken off the end of it.
    private let accessibilityLabel: String
    private let normalImage: NSImage?
    public var dictationEnabled: (() -> Bool)?
    public var toggleDictation: (() -> Void)?
    public var openDictationSettings: (() -> Void)?
    public var dictationSecureInputBlocked: (() -> Bool)?
    public var isDictationListening = false {
        didSet { if oldValue != isDictationListening { applyRecordingIndicator() } }
    }

    private let statusItem: NSStatusItem
    private let panel: StatusMenuPanel
    /// Internal so tests can read what the panel lists without a status bar.
    let state: StatusMenuState
    private var presentationObservation: AnyCancellable?
    private var dismissalMonitors: [Any] = []
    private var spaceObservation: NSObjectProtocol?
    /// When the panel last closed because it lost key status. A click on the
    /// status item takes key from the panel before the item's action runs, so
    /// without this the click that should close the panel would reopen it.
    private var lastResignedKey: Date?
    /// A live session, from the recorder.
    private var isCapturing = false

    /// Whether the floating chip is on screen right now.
    ///
    /// The dot and the chip say the same thing, so only one of them says it:
    /// the chip withdraws a few seconds into a recording, and the dot is what
    /// carries that fact for the rest of it. Set from outside because the chip
    /// is a separate window that the menu bar knows nothing else about.
    public var isMeetingChipVisible = false {
        didSet {
            guard oldValue != isMeetingChipVisible else { return }
            applyRecordingIndicator()
        }
    }

    /// The red dot drawn beside the mark. A coloured attributed title rather
    /// than a second image: the mark itself is a template so the menu bar tints
    /// it with the appearance, and compositing a red dot into it would give
    /// that up for the whole icon.
    private static let recordingIndicator = NSAttributedString(
        string: " \u{25CF}",
        attributes: [
            .foregroundColor: NSColor.systemRed,
            .font: NSFont.systemFont(ofSize: 7),
            .baselineOffset: 2,
        ]
    )

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
        self.accessibilityLabel = accessibilityLabel
        self.normalImage = image
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        panel = StatusMenuPanel()
        state = StatusMenuState(
            presentation: model.presentation,
            content: StatusMenuContent(sections: [])
        )
        super.init()

        // The catalog renders the logo as a template image, so the menu bar
        // tints the mark itself and it stays legible in both appearances.
        image?.isTemplate = true
        statusItem.button?.image = image
        // The dot is the button's title, so it needs somewhere to go; the item
        // has variable length and grows by the few points it takes.
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.setAccessibilityLabel(accessibilityLabel)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        // On press, as a menu opens, rather than on release.
        statusItem.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])

        let transport = StatusMenuTransport(
            start: { [weak self] in self?.model.startRecording() },
            pause: { [weak self] in self?.model.pauseRecording() },
            resume: { [weak self] in self?.model.resumeRecording() },
            stop: { [weak self] in self?.model.stopRecording() }
        )
        let host = NSHostingController(rootView: StatusMenuPanelContent(
            menu: StatusMenuView(state: state, transport: transport) { [weak self] action in
                self?.perform(action)
            }
        ))
        // The panel resizes itself to the content, and `StatusMenuPanel`
        // keeps its top edge pinned under the status item as it does.
        host.sizingOptions = [.preferredContentSize]
        panel.contentViewController = host
        panel.onResignKey = { [weak self] in
            self?.lastResignedKey = Date()
            self?.closePanel()
        }
        panel.onCancel = { [weak self] in self?.closePanel() }

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

    /// True while the panel is on screen.
    var isPanelShown: Bool { panel.isVisible }

    // MARK: Opening and closing

    @objc private func statusItemClicked() {
        if panel.isVisible {
            closePanel()
        } else if let lastResignedKey, Date().timeIntervalSince(lastResignedKey) < 0.3 {
            // This click is what just closed the panel; it is not a request to
            // open it again.
            self.lastResignedKey = nil
        } else {
            showPanel()
        }
    }

    /// Opens the panel under the status item. Internal so tests can open it.
    func showPanel() {
        // Sources are re-enumerated at every opening, so an application
        // launched after Scribe still appears; the answer arrives a moment
        // later and the lists update in place.
        model.menuDidAppear()
        refreshContent(model.presentation)
        statusItem.button?.highlight(true)
        panel.anchor = statusItemAnchor
        // Key without activating Scribe: the app in front, full-screen or not,
        // stays in front, and the Space does not change.
        panel.orderFrontRegardless()
        panel.makeKey()
        installDismissalMonitors()
    }

    func closePanel() {
        guard panel.isVisible else { return }
        removeDismissalMonitors()
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        model.menuDidDisappear()
    }

    /// A menu closes on any click outside it, on Escape, and when the Space
    /// changes; the panel does the same.
    private func installDismissalMonitors() {
        removeDismissalMonitors()
        if let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
            handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.closePanel() }
            }
        ) {
            dismissalMonitors.append(monitor)
        }
        spaceObservation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePanel() }
        }
    }

    private func removeDismissalMonitors() {
        for monitor in dismissalMonitors { NSEvent.removeMonitor(monitor) }
        dismissalMonitors = []
        if let spaceObservation { NSWorkspace.shared.notificationCenter.removeObserver(spaceObservation) }
        spaceObservation = nil
    }

    /// A command closes the panel before it runs, as a menu item closes its
    /// menu, so a window it opens is not covered by the panel.
    private func perform(_ action: () -> Void) {
        closePanel()
        action()
    }

    // MARK: Live state

    private func applyLiveState(_ presentation: MenuPresentation) {
        isCapturing = presentation.isCapturing
        applyRecordingIndicator()
        // Nothing to draw while closed; the content is rebuilt when it opens.
        guard panel.isVisible else { return }
        refreshContent(presentation)
    }

    private func refreshContent(_ presentation: MenuPresentation) {
        state.presentation = presentation
        state.content = makeContent(presentation)
    }

    /// What the panel lists for this presentation. Internal for tests.
    func makeContent(_ presentation: MenuPresentation? = nil) -> StatusMenuContent {
        let dictation: DictationMenuInputs? = if let dictationEnabled, let toggleDictation {
            DictationMenuInputs(
                isEnabled: dictationEnabled(),
                isSecureInputBlocked: dictationSecureInputBlocked?() == true,
                toggle: toggleDictation,
                openSettings: openDictationSettings
            )
        } else {
            nil
        }
        return StatusMenuContent(
            presentation: presentation ?? model.presentation,
            model: model,
            dictation: dictation,
            transcription: transcription(),
            updates: updates(),
            openSettings: openSettings
        )
    }

    /// True while the status item is wearing the red dot.
    var showsRecordingIndicator: Bool { isCapturing && !isMeetingChipVisible }

    private func applyRecordingIndicator() {
        guard let button = statusItem.button else { return }
        button.image = isDictationListening
            ? NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Dictation listening")
            : normalImage
        let shows = showsRecordingIndicator
        button.attributedTitle = shows ? Self.recordingIndicator : NSAttributedString()
        // Read aloud too: the dot is the only thing that says a recording is
        // running once the chip has gone.
        button.setAccessibilityLabel(isDictationListening ? "\(accessibilityLabel) — dictation listening" :
            (shows ? "\(accessibilityLabel) — recording" : accessibilityLabel))
    }
}

/// The panel's backdrop: the material and shape of a menu.
private struct StatusMenuPanelContent: View {
    let menu: StatusMenuView

    var body: some View {
        menu
            .background(MenuMaterial())
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            )
    }
}

private struct MenuMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// The window the status item opens.
///
/// Non-activating, so opening it never brings Scribe forward or leaves a
/// full-screen Space; able to become key anyway, so its controls take clicks
/// and Escape; and joining every Space as an auxiliary of full-screen ones,
/// which is the whole reason it is a panel rather than a menu.
@MainActor
final class StatusMenuPanel: NSPanel {
    var onResignKey: () -> Void = {}
    var onCancel: () -> Void = {}
    /// The status item's frame on screen. The panel hangs from its bottom edge
    /// and keeps hanging from it as its content grows or shrinks.
    var anchor: NSRect? {
        didSet { reposition() }
    }

    /// Clear of the menu bar by the gap macOS leaves under a status menu.
    private static let gap: CGFloat = 4
    private static let screenMargin: CGFloat = 6

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: StatusMenuView.width, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        setAccessibilityLabel("Scribe")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        if isVisible { onResignKey() }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel()
    }

    override func setContentSize(_ size: NSSize) {
        super.setContentSize(size)
        reposition()
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        // Growing from the bottom-left origin would push the top of the panel
        // up over the menu bar; put it back under the status item.
        if anchor != nil, frame.origin != anchoredOrigin(for: frame.size) { reposition() }
    }

    private func reposition() {
        let origin = anchoredOrigin(for: frame.size)
        if frame.origin != origin { super.setFrameOrigin(origin) }
    }

    private func anchoredOrigin(for size: NSSize) -> NSPoint {
        guard let anchor else { return frame.origin }
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        var origin = NSPoint(x: anchor.minX, y: anchor.minY - Self.gap - size.height)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + Self.screenMargin), visible.maxX - size.width - Self.screenMargin)
            origin.y = max(origin.y, visible.minY + Self.screenMargin)
        }
        return origin
    }
}
