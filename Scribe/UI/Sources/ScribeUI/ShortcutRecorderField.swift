import AppKit
import Carbon.HIToolbox
import Platform
import SwiftUI

/// A settings row that records a global shortcut by listening for it.
///
/// Click the field, press the combination, and it is saved. Escape or clicking
/// the field again cancels. Only one field records at a time: starting a second
/// one ends the first, because both would otherwise claim the same keystroke.
///
/// Scribe's own global shortcuts are registered with Carbon, which sees a
/// keystroke before this window does, so pressing the current Start shortcut
/// here would start a recording instead of being captured. `onCaptureChange`
/// tells the owner when capture begins and ends so it can take those
/// registrations down for the duration.
struct ShortcutRecorderField: View {
    let title: String
    @Binding var shortcut: GlobalShortcut
    let defaultShortcut: GlobalShortcut
    /// The action already using a shortcut, if any, so a duplicate can be
    /// refused with a reason instead of silently disabling both.
    let owner: (GlobalShortcut) -> String?
    @ObservedObject var capture: ShortcutCaptureModel

    private var isRecording: Bool { capture.activeField == title }

    var body: some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 6) {
                    Button(action: toggleRecording) {
                        Text(isRecording ? "Type shortcut…" : shortcut.displayName)
                            .monospaced(!isRecording)
                            .foregroundStyle(isRecording ? .secondary : .primary)
                            .frame(minWidth: 110)
                    }
                    .buttonStyle(.bordered)
                    .tint(isRecording ? .accentColor : nil)
                    .help(isRecording ? "Press the new shortcut, or Escape to cancel." : "Click, then press the shortcut you want.")
                    .accessibilityLabel("\(title) shortcut")
                    .accessibilityValue(isRecording ? "Recording" : shortcut.displayName)

                    Button {
                        capture.stop()
                        shortcut = defaultShortcut
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .disabled(shortcut == defaultShortcut)
                    .help("Restore \(defaultShortcut.displayName)")
                    .accessibilityLabel("Restore default \(title) shortcut")
                }
                if isRecording, let message = capture.message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func toggleRecording() {
        if isRecording {
            capture.stop()
        } else {
            capture.start(field: title) { recorded in
                if recorded == shortcut { return nil }
                if let owner = owner(recorded) {
                    return "\(recorded.displayName) is already used for \(owner)."
                }
                shortcut = recorded
                return nil
            }
        }
    }
}

/// Owns the one keyboard monitor all shortcut fields share.
@MainActor
final class ShortcutCaptureModel: ObservableObject {
    /// The field currently listening, by title.
    @Published private(set) var activeField: String?
    /// Why the last keystroke was not accepted; capture continues.
    @Published private(set) var message: String?

    private var monitor: Any?
    /// Returns a refusal message, or nil once the shortcut has been taken.
    private var accept: ((GlobalShortcut) -> String?)?
    private let onCaptureChange: (Bool) -> Void

    init(onCaptureChange: @escaping (Bool) -> Void) {
        self.onCaptureChange = onCaptureChange
    }

    func start(field: String, accept: @escaping (GlobalShortcut) -> String?) {
        let wasCapturing = activeField != nil
        removeMonitor()
        activeField = field
        message = nil
        self.accept = accept
        if !wasCapturing { onCaptureChange(true) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            self.handle(event)
            return nil
        }
    }

    func stop() {
        guard activeField != nil else { return }
        removeMonitor()
        activeField = nil
        message = nil
        accept = nil
        onCaptureChange(false)
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let recorded = GlobalShortcut(keyCode: UInt32(event.keyCode), modifiers: Self.carbonModifiers(flags))

        if recorded.keyCode == UInt32(kVK_Escape), recorded.modifiers == 0 {
            stop()
            return
        }
        guard recorded.isAcceptableGlobalShortcut else {
            message = recorded.modifiers == 0 || recorded.modifiers == UInt32(shiftKey)
                ? "Include ⌘, ⌃, or ⌥ so the shortcut doesn't interfere with typing."
                : "\(recorded.displayName) can't be used as a shortcut."
            NSSound.beep()
            return
        }
        if let refusal = accept?(recorded) {
            message = refusal
            NSSound.beep()
            return
        }
        stop()
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        return modifiers
    }
}
