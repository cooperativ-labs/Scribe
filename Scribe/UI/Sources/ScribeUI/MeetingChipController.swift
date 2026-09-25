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
    private let host: NSHostingController<MeetingChipView>
    private var presentationObservation: AnyCancellable?

    public init(model: MeetingChipModel, anchor: @escaping @MainActor () -> NSRect?) {
        self.model = model
        self.anchor = anchor

        host = NSHostingController(rootView: MeetingChipView(presentation: model.presentation))
        // This controller owns window geometry. Letting the hosting view resize
        // the window during windowDidLayout can re-enter AppKit layout when the
        // offer becomes a recording transport (including during menu tracking).
        host.sizingOptions = []

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
    }

    /// The panel, so a test can assert what the chip did without a status bar.
    var window: NSPanel { panel }

    private func apply(_ presentation: MeetingChipPresentation) {
        guard presentation.isVisible else {
            panel.orderOut(nil)
            return
        }
        // Render and measure the incoming snapshot, not the model's old value:
        // @Published sends before assignment. Keep hidden content out of this
        // path so it cannot collapse the panel to an empty view's ideal size.
        host.rootView = MeetingChipView(
            presentation: presentation,
            actions: MeetingChipActions(
                record: { [model] in model.record() },
                dismiss: { [model] in model.dismiss() },
                hold: { [model] in model.toggleHold() },
                stop: { [model] in model.stop() }
            )
        )
        let measured = host.sizeThatFits(in: NSSize(width: 1_000, height: 200))
        let size = NSSize(width: ceil(measured.width), height: ceil(measured.height))
        if size.width > 0, size.height > 0,
           size.width.isFinite, size.height.isFinite,
           panel.contentView?.frame.size != size {
            panel.setContentSize(size)
        }
        reposition()
        // Ordered *regardless*: Scribe is rarely the active
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
        if panel.frame.origin != origin {
            panel.setFrameOrigin(origin)
        }
    }

    private func screen(containing rect: NSRect?) -> NSScreen? {
        guard let rect else { return NSScreen.main ?? NSScreen.screens.first }
        let point = NSPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens.first
    }
}
