import AppKit
import Observation
import SwiftUI

// MARK: - Close policy

/// When the floating notes panel may close by itself (decision 13).
///
/// It never closes itself while it has focus (the panel, or a popover, sheet
/// or folder dialog opened from it), while text is being composed with an
/// input method, while an edit is not saved, or while the tray is showing a
/// send that is queued, held, under way or finished. Otherwise it may close
/// once the meeting's transcript is ready — and only a transcript that became
/// ready while the panel was open counts, so the panel never vanishes the
/// moment it is opened.
public enum MeetingNotesPanelClosePolicy {
    public struct Inputs: Equatable, Sendable {
        /// The panel, or a window it opened (popover, sheet, open dialog), is
        /// taking keyboard input.
        public var hasFocus: Bool
        /// The notes editor holds uncommitted input-method text.
        public var hasMarkedText: Bool
        /// An edit to the draft is not written yet, or its write failed.
        public var hasUnsavedEdits: Bool
        /// The meeting's transcript exists.
        public var isTranscriptReady: Bool
        /// The panel was showing this meeting before its transcript existed.
        public var wasOpenBeforeTranscript: Bool
        /// What the handoff tray's send controls show.
        public var trayState: AgentHandoffTrayState

        public init(
            hasFocus: Bool,
            hasMarkedText: Bool,
            hasUnsavedEdits: Bool,
            isTranscriptReady: Bool,
            wasOpenBeforeTranscript: Bool,
            trayState: AgentHandoffTrayState
        ) {
            self.hasFocus = hasFocus
            self.hasMarkedText = hasMarkedText
            self.hasUnsavedEdits = hasUnsavedEdits
            self.isTranscriptReady = isTranscriptReady
            self.wasOpenBeforeTranscript = wasOpenBeforeTranscript
            self.trayState = trayState
        }
    }

    public static func mayCloseAutomatically(_ inputs: Inputs) -> Bool {
        guard inputs.isTranscriptReady, inputs.wasOpenBeforeTranscript else { return false }
        guard !inputs.hasFocus, !inputs.hasMarkedText, !inputs.hasUnsavedEdits else { return false }
        // Nothing queued, held or being sent, and no Sent or Couldn't send
        // for the person to read.
        return inputs.trayState == .manual(nil)
    }
}

// MARK: - Panel window

/// The floating notes window.
///
/// Like the status-item panel it is non-activating (opening it, or typing in
/// it, never brings Scribe forward or leaves a full-screen meeting's Space),
/// can become key so it takes typing, and joins every Space as a full-screen
/// auxiliary. Unlike that panel it is a real window: it has a title bar to
/// move it by, it stays open when it loses key, and it remembers where it was
/// put. Nothing in it opens an `NSMenu`, which macOS will not show over
/// another app's full-screen Space for an app with a Dock icon; the tray's
/// pills use popovers.
@MainActor
final class MeetingNotesPanel: NSPanel {
    static let defaultContentSize = NSSize(width: 400, height: 540)
    static let minimumContentSize = NSSize(width: 340, height: 380)

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        title = "Meeting Notes"
        isFloatingPanel = true
        // Above ordinary windows, including a full-screen meeting's, but
        // below menus and the meeting chip.
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // A panel hides when its app deactivates by default; Scribe is
        // almost never the active app while this is in use.
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        animationBehavior = .utilityWindow
        contentMinSize = Self.minimumContentSize
        setAccessibilityLabel("Meeting Notes")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The editing commands normally come from the main menu, which is not
    /// consulted reliably while Scribe is not the active app; the panel
    /// sends them itself, along with ⌘W.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        guard event.type == .keyDown, let selector = Self.editingSelector(for: event) else { return false }
        return NSApp.sendAction(selector, to: nil, from: self)
    }

    static func editingSelector(for event: NSEvent) -> Selector? {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return nil }
        switch (flags, key) {
        case ([.command], "w"): return #selector(NSWindow.performClose(_:))
        case ([.command], "z"): return Selector(("undo:"))
        case ([.command, .shift], "z"): return Selector(("redo:"))
        case ([.command], "x"): return #selector(NSText.cut(_:))
        case ([.command], "c"): return #selector(NSText.copy(_:))
        case ([.command], "v"): return #selector(NSText.paste(_:))
        case ([.command], "a"): return #selector(NSResponder.selectAll(_:))
        default: return nil
        }
    }
}

// MARK: - Content

/// What the panel shows; changed by the controller, read by the view.
@MainActor
@Observable
final class MeetingNotesPanelState {
    var draftID: UUID?
    /// The notes editor has keyboard focus: the tray folds its prompt.
    var isEditingNotes = false
}

struct MeetingNotesPanelRoot: View {
    @Bindable var viewModel: TranscriptViewModel
    let state: MeetingNotesPanelState
    let openInTranscripts: @MainActor (UUID) -> Void

    var body: some View {
        Group {
            if let draftID = state.draftID {
                MeetingNotesPanelView(
                    viewModel: viewModel,
                    draftID: draftID,
                    isEditingNotes: Binding(get: { state.isEditingNotes }, set: { state.isEditingNotes = $0 }),
                    openInTranscripts: openInTranscripts
                )
            } else {
                Color.clear
            }
        }
        .frame(
            minWidth: MeetingNotesPanel.minimumContentSize.width,
            maxWidth: .infinity,
            minHeight: MeetingNotesPanel.minimumContentSize.height,
            maxHeight: .infinity
        )
    }
}

/// The meeting's name and state, its notes, and the handoff tray: the same
/// editor and tray as the Transcripts window, bound to the same draft.
struct MeetingNotesPanelView: View {
    @Bindable var viewModel: TranscriptViewModel
    let draftID: UUID
    @Binding var isEditingNotes: Bool
    let openInTranscripts: @MainActor (UUID) -> Void

    private var file: TranscriptReviewFile? {
        viewModel.files.first { $0.draft?.id == draftID }
    }

    var body: some View {
        if let file, let draft = file.draft {
            VStack(alignment: .leading, spacing: 0) {
                header(file: file)
                Divider()
                MeetingNotesEditorPane(
                    viewModel: viewModel,
                    draftID: draftID,
                    placeholder: "Write notes for the agent. Each paragraph is a note, stamped with the recording time.",
                    onFocusChange: { isEditingNotes = $0 }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if viewModel.canSendToAgent, !draft.isOrphaned {
                    AgentHandoffTray(
                        viewModel: viewModel,
                        target: .draft(draftID),
                        style: .full,
                        isPromptCollapsed: isEditingNotes
                    )
                }
            }
        } else {
            ContentUnavailableView(
                "Meeting not found",
                systemImage: "note.text",
                description: Text("This meeting\u{2019}s draft was deleted.")
            )
        }
    }

    /// Height-bounded: two single lines. Only the status line redraws every
    /// second, so the clock never touches the editor's text or caret.
    private func header(file: TranscriptReviewFile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(file.displayName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                RecordingControlButtons(viewModel: viewModel, file: file)
                    .controlSize(.small)
                Button {
                    openInTranscripts(draftID)
                } label: {
                    Label("Open in Transcripts", systemImage: "macwindow")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Show this meeting in the Transcripts window")
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Label(Self.statusText(for: file, now: context.date), systemImage: Self.statusSymbol(for: file))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .font(.callout)
            .foregroundStyle(file.isRecording ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func statusText(for file: TranscriptReviewFile, now: Date) -> String {
        if case .notSaved = file.draft?.saveState { return "Not saved" }
        if file.isRecording { return file.sidebarDetail(now: now) }
        if file.transcript != nil {
            return ["Transcript ready", file.draft?.noteCountText].compactMap { $0 }.joined(separator: " \u{00B7} ")
        }
        if file.isInProgress { return file.jobState.displayName }
        return file.draft?.status ?? file.jobState.displayName
    }

    static func statusSymbol(for file: TranscriptReviewFile) -> String {
        if case .notSaved = file.draft?.saveState { return "exclamationmark.triangle" }
        if file.isRecording { return "record.circle" }
        if file.transcript != nil { return "checkmark.circle" }
        if file.draft?.isOrphaned == true { return "note.text" }
        return "waveform"
    }
}

// MARK: - Controller

/// Owns the floating notes panel and decides when it may close.
///
/// It shows one meeting draft at a time, through the same
/// `TranscriptViewModel` as the Transcripts window: the editor and tray are
/// the window's own, bound to the same draft ID, so edits made in either
/// place go through the one draft session and show up in the other.
@MainActor
public final class MeetingNotesPanelController: NSObject, NSWindowDelegate {
    /// Where the panel's frame is remembered.
    public static let frameAutosaveName = "ScribeMeetingNotesPanel"

    /// Shows the draft's row in the Transcripts window.
    public var openInTranscripts: (@MainActor (UUID) -> Void)?

    public let viewModel: TranscriptViewModel
    let panel: MeetingNotesPanel
    let state = MeetingNotesPanelState()
    private var host: NSHostingController<MeetingNotesPanelRoot>?
    /// The draft's transcript did not exist yet while the panel showed it,
    /// which is what lets the panel close itself once it does.
    private var wasOpenBeforeTranscript = false
    private var isObserving = false
    private var closeCheck: Task<Void, Never>?

    public init(viewModel: TranscriptViewModel) {
        self.viewModel = viewModel
        panel = MeetingNotesPanel()
        super.init()
        let host = NSHostingController(rootView: MeetingNotesPanelRoot(
            viewModel: viewModel,
            state: state,
            openInTranscripts: { [weak self] draftID in self?.openInTranscripts?(draftID) }
        ))
        // The panel's size is the person's; the content fills it.
        host.sizingOptions = []
        self.host = host
        panel.contentViewController = host
        panel.setContentSize(MeetingNotesPanel.defaultContentSize)
        panel.delegate = self
    }

    /// The draft on screen, or nil while the panel is closed.
    public var draftID: UUID? { panel.isVisible ? state.draftID : nil }
    public var isVisible: Bool { panel.isVisible }

    /// Shows the notes of `draftID`, and puts the caret in them. A panel
    /// showing another meeting switches to this one, writing the other's
    /// notes first.
    public func show(draftID: UUID) {
        if let previous = state.draftID, previous != draftID {
            commitInput()
            viewModel.flushNotes(draftID: previous)
        }
        if state.draftID != draftID {
            state.draftID = draftID
            state.isEditingNotes = false
            wasOpenBeforeTranscript = viewModel.files.first { $0.draft?.id == draftID }?.transcript == nil
        }
        if !panel.isVisible {
            placeOnScreen()
            // Ordered regardless and made key without activating Scribe: the
            // meeting stays the active app and its Space does not change.
            panel.orderFrontRegardless()
        }
        panel.makeKey()
        observeModel()
        focusEditor()
    }

    /// Closes the panel, writing its notes first.
    public func close() {
        guard panel.isVisible else { return }
        panel.performClose(nil)
    }

    // MARK: Placement

    /// The remembered frame when it is still on a screen; otherwise the
    /// top-right corner of the screen the pointer is on.
    private func placeOnScreen() {
        if panel.setFrameUsingName(Self.frameAutosaveName),
           NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) {
            panel.setFrameAutosaveName(Self.frameAutosaveName)
            return
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
        if let visible = screen?.visibleFrame {
            let size = panel.frame.size
            let margin: CGFloat = 16
            panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - margin, y: visible.maxY - size.height - margin))
        }
        panel.setFrameAutosaveName(Self.frameAutosaveName)
    }

    // MARK: Focus

    /// Puts the caret at the end of the notes once SwiftUI has built them.
    private func focusEditor(attempt: Int = 0) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible else { return }
            guard let editor = Self.editorView(in: self.panel.contentView) else {
                if attempt < 5 { self.focusEditor(attempt: attempt + 1) }
                return
            }
            if self.panel.firstResponder !== editor.textView {
                self.panel.makeFirstResponder(editor.textView)
            }
        }
    }

    static func editorView(in view: NSView?) -> MeetingNotesEditorView? {
        guard let view else { return nil }
        if let editor = view as? MeetingNotesEditorView { return editor }
        for subview in view.subviews {
            if let editor = editorView(in: subview) { return editor }
        }
        return nil
    }

    /// Ends any input-method composition by committing it, so closing or
    /// switching meetings never drops typed text.
    private func commitInput() {
        if let textView = panel.firstResponder as? NSTextView, textView.hasMarkedText() {
            textView.unmarkText()
            textView.didChangeText()
        }
    }

    // MARK: Automatic close

    /// Re-checks the close policy whenever the rows or a send change.
    private func observeModel() {
        guard !isObserving else { return }
        isObserving = true
        withObservationTracking {
            _ = viewModel.files
            _ = viewModel.handoffStatuses
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isObserving = false
                guard self.panel.isVisible else { return }
                self.observeModel()
                self.considerClosing()
            }
        }
    }

    /// What the close policy is asked, for the draft on screen.
    func closeInputs() -> MeetingNotesPanelClosePolicy.Inputs? {
        guard panel.isVisible, let draftID = state.draftID,
              let file = viewModel.files.first(where: { $0.draft?.id == draftID }) else { return nil }
        let textView = panel.firstResponder as? NSTextView
        let hasFocus = panel.isKeyWindow
            || panel.attachedSheet != nil
            || panel.childWindows?.contains(where: \.isVisible) == true
            || NSApp.modalWindow != nil
        var unsaved = viewModel.hasUnsavedEdits(draftID: draftID)
        if case .notSaved = file.draft?.saveState { unsaved = true }
        return MeetingNotesPanelClosePolicy.Inputs(
            hasFocus: hasFocus,
            hasMarkedText: textView?.hasMarkedText() == true,
            hasUnsavedEdits: unsaved,
            isTranscriptReady: file.transcript != nil,
            wasOpenBeforeTranscript: wasOpenBeforeTranscript,
            trayState: viewModel.handoffTrayState(for: .draft(draftID))
        )
    }

    /// Closes the panel if the policy allows it, after writing the notes and
    /// asking again. Edits still on their way to disk are written first, so
    /// they hold the panel open only until they are saved; a write that
    /// fails keeps it open.
    func considerClosing() {
        guard var inputs = closeInputs(), let draftID = state.draftID else { return }
        inputs.hasUnsavedEdits = false
        guard MeetingNotesPanelClosePolicy.mayCloseAutomatically(inputs) else { return }
        closeCheck?.cancel()
        closeCheck = Task { @MainActor [weak self] in
            await self?.viewModel.draftEditor?.flushNotes(draftID: draftID)
            guard let self, !Task.isCancelled, self.state.draftID == draftID,
                  let inputs = self.closeInputs(),
                  MeetingNotesPanelClosePolicy.mayCloseAutomatically(inputs) else { return }
            self.close()
        }
    }

    // MARK: NSWindowDelegate

    public func windowDidResignKey(_ notification: Notification) {
        considerClosing()
    }

    public func windowWillClose(_ notification: Notification) {
        closeCheck?.cancel()
        closeCheck = nil
        commitInput()
        if let draftID = state.draftID {
            viewModel.flushNotes(draftID: draftID)
        }
        // Takes the editor down, which writes its notes too, and leaves
        // nothing bound to a meeting while the panel is closed.
        state.draftID = nil
        state.isEditingNotes = false
        wasOpenBeforeTranscript = false
    }
}

/// Pause/resume and stop for the recording in progress. Shown in the
/// transcript header and the floating notes panel; empty unless the file is
/// recording (or held) and the host supplied a recorder hook.
struct RecordingControlButtons: View {
    let viewModel: TranscriptViewModel
    let file: TranscriptReviewFile

    var body: some View {
        if case .recording(_, let isPaused) = file.jobState, let control = viewModel.recordingControl {
            HStack(spacing: 6) {
                Button {
                    control(isPaused ? .resume : .pause)
                } label: {
                    Label(isPaused ? "Resume" : "Pause", systemImage: isPaused ? "record.circle" : "pause.fill")
                }
                .help(isPaused ? "Resume recording" : "Pause recording")
                Button {
                    control(.stop)
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .help("Stop recording and finish this meeting")
            }
            .buttonStyle(.bordered)
        }
    }
}
