import AppKit
import Combine
import Dictation
import SwiftUI

private final class NonKeyDictationPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
public final class DictationIndicatorController {
    private let coordinator: DictationCoordinator
    private let locator = FocusedFieldLocator()
    private let position: () -> String
    private let stop: () -> Void
    private let cancel: () -> Void
    private let openSettings: () -> Void
    private let panel: NSPanel
    private let host: NSHostingController<DictationIndicatorView>
    private var observation: AnyCancellable?
    private var mode: DictationTriggerMode = .hold
    private var generation = 0
    private var anchor: NSPoint?
    private var targetScreen: NSScreen?
    private var showLabel = false
    private var visible = false
    private var delayTask: Task<Void, Never>?
    private var dismissalTask: Task<Void, Never>?

    public init(coordinator: DictationCoordinator, position: @escaping () -> String,
                stop: @escaping () -> Void, cancel: @escaping () -> Void,
                openSettings: @escaping () -> Void) {
        self.coordinator = coordinator
        self.position = position
        self.stop = stop
        self.cancel = cancel
        self.openSettings = openSettings
        host = NSHostingController(rootView: DictationIndicatorView(state: .idle))
        host.sizingOptions = []
        panel = NonKeyDictationPanel(contentRect: NSRect(x: 0, y: 0, width: 140, height: 52),
                                    styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: true)
        panel.contentViewController = host
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.setAccessibilityLabel("Dictation status")
        observation = coordinator.$state.sink { [weak self] state in self?.apply(state) }
    }

    public var window: NSPanel { panel }

    private func apply(_ state: DictationState) {
        switch state {
        case .listening:
            if !visible, dismissalTask != nil || delayTask == nil {
                beginSession()
            }
            if !visible { return }
        case .transcribing:
            delayTask?.cancel(); delayTask = nil
            showLabel = false
            scheduleLabel()
        case .inserted, .copied, .error:
            delayTask?.cancel(); delayTask = nil
            scheduleDismissal(for: state)
        case .idle:
            delayTask?.cancel(); delayTask = nil
            dismissalTask?.cancel(); dismissalTask = nil
            visible = false
            panel.orderOut(nil)
            return
        case .warming:
            break
        }
        render(state)
    }

    private func beginSession() {
        generation += 1
        let session = generation
        dismissalTask?.cancel(); dismissalTask = nil
        mode = coordinator.triggerMode
        showLabel = false
        anchor = nil
        targetScreen = nil
        visible = mode == .doubleTap
        let screenTop = NSScreen.screens.first?.frame.maxY ?? 0
        let screens = NSScreen.screens.map(\.frame)
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            Task { [weak self, locator] in
                let snapshot = await locator.locate(frontmostPID: pid, screenTop: screenTop, screens: screens)
                guard let self, self.generation == session else { return }
                self.lockAnchor(snapshot)
                if self.visible { self.render(self.coordinator.state) }
            }
        }
        if !visible {
            delayTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, !Task.isCancelled, self.generation == session,
                      case .listening = self.coordinator.state else { return }
                self.visible = true
                self.render(self.coordinator.state)
            }
        }
    }

    private func lockAnchor(_ snapshot: FocusedFieldSnapshot?) {
        guard anchor == nil else { return }
        if let rect = snapshot?.caretRect ?? snapshot?.elementFrame {
            anchor = NSPoint(x: rect.minX, y: rect.maxY + 8)
            targetScreen = NSScreen.screens.first {
                $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) || $0.frame.intersects(rect)
            }
        } else if let rect = snapshot?.windowFrame {
            anchor = NSPoint(x: rect.midX, y: rect.minY + 8)
            targetScreen = NSScreen.screens.first { $0.frame.intersects(rect) }
        }
    }

    private func scheduleLabel() {
        let session = generation
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard let self, self.generation == session,
                  case .transcribing = self.coordinator.state else { return }
            self.showLabel = true
            self.render(.transcribing)
        }
    }

    private func scheduleDismissal(for state: DictationState) {
        dismissalTask?.cancel()
        let duration: Int
        switch state {
        case .inserted: duration = 600
        case .copied: duration = 3_000
        default: duration = 4_000
        }
        let session = generation
        dismissalTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(duration))
            guard let self, !Task.isCancelled, self.generation == session else { return }
            self.panel.orderOut(nil)
            self.visible = false
            self.dismissalTask = nil
        }
    }

    private func render(_ state: DictationState) {
        guard position() != "off" else { panel.orderOut(nil); return }
        host.rootView = DictationIndicatorView(
            state: state, showsToggleControls: mode == .doubleTap, showsTranscribingLabel: showLabel,
            stop: stop, cancel: cancel, openSettings: openSettings
        )
        let fit = host.sizeThatFits(in: NSSize(width: 700, height: 100))
        guard fit.width.isFinite, fit.height.isFinite, fit.width > 0, fit.height > 0 else { return }
        let size = NSSize(width: ceil(fit.width), height: ceil(fit.height))
        panel.setContentSize(size)
        let mouse = NSEvent.mouseLocation
        guard let screen = targetScreen ?? NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        var origin: NSPoint
        if position() == "bottom" || anchor == nil {
            origin = NSPoint(x: visibleFrame.midX - size.width / 2, y: visibleFrame.minY + 20)
        } else {
            origin = NSPoint(x: anchor!.x, y: anchor!.y)
        }
        origin.x = min(max(origin.x, visibleFrame.minX), visibleFrame.maxX - size.width)
        origin.y = min(max(origin.y, visibleFrame.minY), visibleFrame.maxY - size.height)
        panel.setFrameOrigin(origin)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
}
