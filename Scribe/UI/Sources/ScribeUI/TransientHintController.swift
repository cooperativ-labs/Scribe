import AppKit
import SwiftUI

/// A short line of text under the status item that goes away by itself.
///
/// Used where a global shortcut has nothing to act on — Meeting Notes with no
/// recording in progress — so the key press is answered rather than silently
/// ignored. It never takes focus or activates Scribe, joins every Space
/// (full-screen ones included), and is read aloud for VoiceOver.
@MainActor
public final class TransientHintController {
    /// How long a hint stays on screen.
    public nonisolated static let visibleDuration: Duration = .milliseconds(2_500)

    private static let menuBarGap: CGFloat = 6
    private static let screenMargin: CGFloat = 8

    private let anchor: @MainActor () -> NSRect?
    private let duration: Duration
    private let panel: NSPanel
    private let host: NSHostingController<TransientHintView>
    private var dismissal: Task<Void, Never>?

    /// The hint on screen, or nil.
    public private(set) var message: String?

    public init(anchor: @escaping @MainActor () -> NSRect?, duration: Duration = TransientHintController.visibleDuration) {
        self.anchor = anchor
        self.duration = duration
        host = NSHostingController(rootView: TransientHintView(message: ""))
        host.sizingOptions = []
        panel = HintPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.contentViewController = host
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.setAccessibilityLabel("Scribe")
    }

    /// The panel, for tests.
    var window: NSPanel { panel }

    /// Shows `message` for a moment, replacing any hint already showing.
    public func show(_ message: String) {
        self.message = message
        host.rootView = TransientHintView(message: message)
        let measured = host.sizeThatFits(in: NSSize(width: 420, height: 200))
        let size = NSSize(width: ceil(measured.width), height: ceil(measured.height))
        if size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite {
            panel.setContentSize(size)
        }
        reposition()
        panel.orderFrontRegardless()
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
        dismissal?.cancel()
        let duration = duration
        dismissal = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    public func hide() {
        dismissal?.cancel()
        dismissal = nil
        message = nil
        panel.orderOut(nil)
    }

    /// Centred under the status item, else in the top-right corner of the
    /// main screen.
    private func reposition() {
        let size = panel.frame.size
        let anchorRect = anchor()
        let screen: NSScreen? = anchorRect.flatMap { rect in
            NSScreen.screens.first { $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) }
        } ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        var origin = if let anchorRect {
            NSPoint(x: anchorRect.midX - size.width / 2, y: anchorRect.minY - Self.menuBarGap - size.height)
        } else {
            NSPoint(x: visible.maxX - size.width - Self.screenMargin, y: visible.maxY - size.height - Self.screenMargin)
        }
        origin.x = min(max(origin.x, visible.minX + Self.screenMargin), visible.maxX - size.width - Self.screenMargin)
        origin.y = max(origin.y, visible.minY + Self.screenMargin)
        panel.setFrameOrigin(origin)
    }
}

private final class HintPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct TransientHintView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 12, weight: .medium))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .frame(maxWidth: 360)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
            .padding(6)
            .fixedSize()
    }
}
