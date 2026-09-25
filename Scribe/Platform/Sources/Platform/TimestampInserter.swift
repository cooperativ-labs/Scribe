import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Puts text at the cursor of whichever app the person is typing in.
@MainActor
public protocol TextInserting: AnyObject {
    func insert(_ text: String)
}

/// Copies text and pastes it into the frontmost app with a keyboard event.
///
/// Posting events needs Accessibility access. The clipboard is updated even
/// without access, and macOS is asked once to show its Accessibility prompt.
@MainActor
public final class KeystrokeTextInserter: TextInserting {
    /// The shortcut fires on key-down, while its modifiers are still held.
    /// Wait for their release so they cannot alter the paste keystroke.
    private let modifierReleaseTimeout: Duration
    private let pollInterval: Duration
    private var hasRequestedAccess = false
    private var pending: Task<Void, Never>?

    public init(modifierReleaseTimeout: Duration = .seconds(5), pollInterval: Duration = .milliseconds(15)) {
        self.modifierReleaseTimeout = modifierReleaseTimeout
        self.pollInterval = pollInterval
    }

    public func insert(_ text: String) {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return }
        let pasteboardChangeCount = pasteboard.changeCount
        guard CGPreflightPostEventAccess() else {
            if !hasRequestedAccess {
                hasRequestedAccess = true
                _ = CGRequestPostEventAccess()
            }
            return
        }
        let previous = pending
        pending = Task { [modifierReleaseTimeout, pollInterval] in
            await previous?.value
            guard await Self.waitForModifierRelease(timeout: modifierReleaseTimeout, pollInterval: pollInterval) else { return }
            guard NSPasteboard.general.changeCount == pasteboardChangeCount else { return }
            Self.paste()
        }
    }

    private static let heldModifiers: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]

    private static func waitForModifierRelease(timeout: Duration, pollInterval: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while CGEventSource.flagsState(.combinedSessionState).intersection(heldModifiers) != [],
              ContinuousClock.now < deadline {
            try? await Task.sleep(for: pollInterval)
        }
        return CGEventSource.flagsState(.combinedSessionState).intersection(heldModifiers) == []
    }

    private static func paste() {
        let source = CGEventSource(stateID: .privateState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else { return }
        for event in [keyDown, keyUp] {
            event.flags = .maskCommand
            event.post(tap: .cghidEventTap)
        }
    }
}
