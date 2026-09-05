import AppKit
import Combine
import SwiftUI

/// Owns the floating panel the meeting chip lives in.
///
/// The chip is deliberately its own window rather than a row in the menu. A
/// menu only exists while it is open, and the whole point of the offer is that
/// it reaches a person who is not looking at Scribe — they are in a call. So
/// this is a non-activating panel that hangs under the status item: it appears
/// without stealing focus from the meeting, follows the app across Spaces and
/// over full-screen windows, and orders itself out the moment there is nothing
/// to say.
@MainActor
public final class MeetingChipController {
    /// The chip's view keeps a transparent margin around the capsule for its
    /// shadow, so the panel may overlap the menu bar by this much and what
    /// actually shows still hangs clear below it.
    private static let menuBarOverlap: CGFloat = 4
    /// Kept clear of the screen edges when the status item sits near one.
    private static let screenMargin: CGFloat = 8

    private let model: MeetingChipModel
    /// Where the status item is on screen, read fresh each time: the menu bar
    /// rearranges itself as other items come and go, and a chip anchored to a
    /// remembered position would drift away from its icon.
    private let anchor: @MainActor () -> NSRect?
    private let panel: NSPanel
    private let host: NSHostingController<MeetingChipHost>
    private var presentationObservation: AnyCancellable?
    /// Only ever touched on the main actor; marked so `deinit` may remove it.
    nonisolated(unsafe) private var resizeObservation: (any NSObjectProtocol)?

    public init(model: MeetingChipModel, anchor: @escaping @MainActor () -> NSRect?) {
        self.model = model
        self.anchor = anchor

        host = NSHostingController(rootView: MeetingChipHost(model: model))
        // The chip changes shape when the offer becomes a transport, so the
        // window is told to follow SwiftUI's own idea of the right size rather
        // than being given one here.
        host.sizingOptions = [.preferredContentSize]

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 72),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.contentViewController = host
        panel.isFloatingPanel = true
        // Above every ordinary window, at the height the menu bar's own menus
        // use, so the chip is not covered by the call it is about.
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // The glass draws its own shadow; a window shadow on top of it doubles
        // the edge and squares off the capsule's corners.
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.setAccessibilityLabel("Meeting recording")

        // `@Published` delivers the new value before the property is assigned,
        // so the incoming presentation is the one acted on.
        presentationObservation = model.$presentation.sink { [weak self] presentation in
            self?.apply(presentation)
        }
        // SwiftUI resizes the panel a beat after the presentation changes, which
        // is the moment the chip has to be moved back under its icon.
        resizeObservation = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
        apply(model.presentation)
    }

    deinit {
        if let resizeObservation {
            NotificationCenter.default.removeObserver(resizeObservation)
        }
    }

    /// The panel, so a test can assert what the chip did without a status bar.
    var window: NSPanel { panel }

    private func apply(_ presentation: MeetingChipPresentation) {
        guard presentation.isVisible else {
            panel.orderOut(nil)
            return
        }
        reposition()
        // Ordered *regardless*: Scribe has no Dock icon and is rarely the active
        // app, so an ordinary `orderFront` would put the chip behind the call.
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// Centres the chip under the status item, then keeps it on the screen.
    ///
    /// With no anchor — the status item can be hidden by a menu bar that has run
    /// out of room — the chip goes to the top-right corner instead of vanishing,
    /// which is the nearest place its icon would have been.
    private func reposition() {
        let size = panel.frame.size
        let anchorRect = anchor()
        // No screen at all is only reachable off a display, where there is
        // nothing to position against and nothing to see.
        guard let screen = screen(containing: anchorRect) else { return }
        let visible = screen.visibleFrame
        // `visibleFrame` stops below the menu bar, so the full frame is what the
        // chip is measured against: it hangs off the menu bar, not off the desktop.
        let ceiling = screen.frame.maxY

        var origin: NSPoint
        if let anchorRect {
            origin = NSPoint(
                x: anchorRect.midX - size.width / 2,
                y: anchorRect.minY - size.height + Self.menuBarOverlap
            )
        } else {
            origin = NSPoint(
                x: visible.maxX - size.width + Self.screenMargin,
                y: visible.maxY - size.height
            )
        }

        origin.x = min(max(origin.x, visible.minX - Self.screenMargin), visible.maxX - size.width + Self.screenMargin)
        origin.y = min(origin.y, ceiling - size.height)
        panel.setFrameOrigin(origin)
    }

    private func screen(containing rect: NSRect?) -> NSScreen? {
        guard let rect else { return NSScreen.main ?? NSScreen.screens.first }
        let point = NSPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens.first
    }
}
