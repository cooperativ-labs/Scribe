import Foundation
import Observation

public struct TranscriptToast: Identifiable, Equatable {
    public enum Kind: Equatable { case result, failure, progress }
    public enum Action: Equatable { case undo, redo, showInFinder(URL) }

    public let id: UUID
    public var text: String
    public var kind: Kind
    public var action: Action?
    fileprivate var deadline: Date?
    fileprivate var remaining: TimeInterval?
    fileprivate var isHovered = false

    public init(id: UUID = UUID(), text: String, kind: Kind, action: Action? = nil) {
        self.id = id
        self.text = text
        self.kind = kind
        self.action = action
    }
}

/// The newest three notifications, ordered from top to bottom. A clock can be
/// supplied by tests; production schedules expiry without keeping a window alive.
@MainActor
@Observable
public final class TranscriptToastCenter {
    public private(set) var visible: [TranscriptToast] = []
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let schedulesExpiry: Bool

    public init(now: @escaping () -> Date = Date.init, schedulesExpiry: Bool = true) {
        self.now = now
        self.schedulesExpiry = schedulesExpiry
    }

    @discardableResult
    public func post(_ text: String, kind: TranscriptToast.Kind, action: TranscriptToast.Action? = nil) -> UUID {
        if action == .undo || action == .redo { clearReversibleActions() }
        var toast = TranscriptToast(text: text, kind: kind, action: action)
        if kind == .result { toast.deadline = now().addingTimeInterval(4) }
        visible.append(toast)
        if visible.count > 3 { visible.removeFirst(visible.count - 3) }
        scheduleExpiry(for: toast)
        return toast.id
    }

    public func finish(_ id: UUID, text: String, failure: Bool, action: TranscriptToast.Action? = nil) {
        guard let index = visible.firstIndex(where: { $0.id == id }) else {
            post(text, kind: failure ? .failure : .result, action: action)
            return
        }
        visible[index].text = text
        visible[index].kind = failure ? .failure : .result
        visible[index].action = action
        visible[index].deadline = failure ? nil : now().addingTimeInterval(4)
        visible[index].remaining = nil
        scheduleExpiry(for: visible[index])
    }

    public func dismiss(_ id: UUID) { visible.removeAll { $0.id == id } }

    public func clearReversibleActions() {
        for index in visible.indices where visible[index].action == .undo || visible[index].action == .redo {
            visible[index].action = nil
        }
    }

    public func setHovered(_ hovered: Bool, for id: UUID) {
        guard let index = visible.firstIndex(where: { $0.id == id }), visible[index].kind == .result else { return }
        if hovered && !visible[index].isHovered {
            visible[index].remaining = max(0, visible[index].deadline?.timeIntervalSince(now()) ?? 4)
            visible[index].deadline = nil
        } else if !hovered && visible[index].isHovered {
            visible[index].deadline = now().addingTimeInterval(visible[index].remaining ?? 4)
            visible[index].remaining = nil
            scheduleExpiry(for: visible[index])
        }
        visible[index].isHovered = hovered
    }

    public func expire() {
        let current = now()
        visible.removeAll { $0.kind == .result && !$0.isHovered && ($0.deadline.map { $0 <= current } ?? false) }
    }

    private func scheduleExpiry(for toast: TranscriptToast) {
        guard schedulesExpiry, toast.kind == .result, let deadline = toast.deadline else { return }
        Task { [weak self] in
            let interval = max(0, deadline.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(interval))
            self?.expire()
        }
    }
}
