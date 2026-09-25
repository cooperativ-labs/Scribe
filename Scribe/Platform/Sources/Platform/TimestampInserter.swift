import AppKit
import Carbon.HIToolbox
import CoreGraphics

@MainActor
public protocol TextInserting: AnyObject {
    func insert(_ text: String)
}

public enum PasteInsertionOutcome: Sendable { case posted, copied, failed }

/// Posts Cmd-V after a shortcut's modifiers are released and restores the
/// original pasteboard only if nobody else changed it in the meantime.
@MainActor
public final class KeystrokeTextInserter: TextInserting {
    private let modifierReleaseTimeout: Duration
    private let pollInterval: Duration
    private var hasRequestedAccess = false
    private var pending: Task<Void, Never>?

    public init(modifierReleaseTimeout: Duration = .seconds(5), pollInterval: Duration = .milliseconds(15)) {
        self.modifierReleaseTimeout = modifierReleaseTimeout
        self.pollInterval = pollInterval
    }

    public func insert(_ text: String) {
        let previous = pending
        pending = Task { [weak self] in
            await previous?.value
            _ = await self?.insertAndReport(text)
        }
    }

    public func copyOnly(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    public func insertAndReport(_ text: String, restoreClipboard: Bool = true) async -> PasteInsertionOutcome {
        guard !text.isEmpty else { return .failed }
        let pasteboard = NSPasteboard.general
        let saved = restoreClipboard ? Self.snapshot(pasteboard) : []
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string),
              item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType")),
              pasteboard.writeObjects([item]) else { return .failed }
        let changeCount = pasteboard.changeCount
        guard CGPreflightPostEventAccess() else {
            if !hasRequestedAccess {
                hasRequestedAccess = true
                _ = CGRequestPostEventAccess()
            }
            // The text remains available for a manual paste.
            return .copied
        }
        guard await Self.waitForModifierRelease(timeout: modifierReleaseTimeout, pollInterval: pollInterval),
              pasteboard.changeCount == changeCount else { return .copied }
        guard Self.paste() else { return .copied }
        if restoreClipboard {
            try? await Task.sleep(for: .milliseconds(300))
            if pasteboard.changeCount == changeCount { Self.restore(saved, to: pasteboard) }
        }
        return .posted
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
    }
    private static func restore(_ saved: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let items = saved.map { contents -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in contents { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
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
    private static func paste() -> Bool {
        let source = CGEventSource(stateID: .privateState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else { return false }
        for event in [keyDown, keyUp] {
            event.flags = .maskCommand
            event.post(tap: .cghidEventTap)
        }
        return true
    }
}
