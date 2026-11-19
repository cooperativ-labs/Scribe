import Foundation
import Transcription
import UserNotifications

/// Tells the person what a queued send did when they are not looking at the
/// Transcripts window: sent (with Open), ready to send but held (with Send
/// and Cancel), or failed.
///
/// Notifications are a courtesy, never the record. If the person has turned
/// them off, or posting fails, nothing about the send changes: the tray and
/// the row already say what happened. Prompt, MCP URL and notes never appear
/// in a notification; only the meeting's title and where it went.
@MainActor
final class QueuedHandoffNotifications: NSObject, QueuedHandoffNotifying {
    private enum Category {
        static let held = "scribe.queued-send.held"
        static let sent = "scribe.queued-send.sent"
        static let failed = "scribe.queued-send.failed"
    }

    private enum Action {
        static let send = "scribe.queued-send.send"
        static let cancel = "scribe.queued-send.cancel"
        static let open = "scribe.queued-send.open"
    }

    private enum Key {
        static let draftID = "draftID"
        static let operationID = "operationID"
        static let sessionID = "latchSessionID"
    }

    /// What a notification's buttons ask for. Set by the host.
    var confirm: (@MainActor (_ draftID: UUID, _ operationID: UUID?) async -> Void)?
    var cancel: (@MainActor (_ draftID: UUID, _ operationID: UUID?) async -> Void)?
    var openSession: (@MainActor (_ sessionID: String) async -> Void)?
    /// Clicking the notification itself shows the meeting.
    var showMeeting: (@MainActor (_ draftID: UUID) -> Void)?

    private let center: UNUserNotificationCenter
    private var hasRequestedAuthorization = false

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Category.held,
                actions: [
                    UNNotificationAction(identifier: Action.send, title: "Send", options: []),
                    UNNotificationAction(identifier: Action.cancel, title: "Cancel", options: [.destructive]),
                ],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: Category.sent,
                actions: [UNNotificationAction(identifier: Action.open, title: "Open", options: [.foreground])],
                intentIdentifiers: []
            ),
            UNNotificationCategory(identifier: Category.failed, actions: [], intentIdentifiers: []),
        ])
    }

    /// Asked when the person first queues a send, so the question comes with
    /// a reason they can see.
    func prepare() {
        guard !hasRequestedAuthorization else { return }
        hasRequestedAuthorization = true
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ notice: QueuedHandoffNotice) {
        let content = UNMutableNotificationContent()
        var info: [String: String] = [:]
        let identifier: String
        switch notice {
        case let .sent(draftID, operationID, meetingTitle, destination, sessionID):
            content.title = "Sent to \(destination)"
            content.body = meetingTitle
            content.categoryIdentifier = Category.sent
            info = [Key.draftID: draftID.uuidString, Key.operationID: operationID.uuidString, Key.sessionID: sessionID]
            identifier = operationID.uuidString
        case let .held(draftID, operationID, meetingTitle, destination, reason):
            content.title = "Ready to send \u{2014} confirm"
            content.body = "\(meetingTitle) is ready to send to \(destination). \(reason.explanation)"
            content.categoryIdentifier = Category.held
            info = [Key.draftID: draftID.uuidString, Key.operationID: operationID.uuidString]
            identifier = operationID.uuidString
        case let .failed(draftID, operationID, meetingTitle, message):
            content.title = "Couldn\u{2019}t send \u{201C}\(meetingTitle)\u{201D}"
            content.body = message
            content.categoryIdentifier = Category.failed
            info = [Key.draftID: draftID.uuidString]
            if let operationID { info[Key.operationID] = operationID.uuidString }
            identifier = operationID?.uuidString ?? UUID().uuidString
        }
        content.userInfo = info
        // One notification per send: a later state replaces the earlier one.
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { _ in }
    }
}

extension QueuedHandoffNotifications: UNUserNotificationCenterDelegate {
    /// Shown even while Scribe is in front: the send may have fired from a
    /// window the person is not looking at.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        let draftID = (info[Key.draftID] as? String).flatMap(UUID.init(uuidString:))
        let operationID = (info[Key.operationID] as? String).flatMap(UUID.init(uuidString:))
        let sessionID = info[Key.sessionID] as? String
        await route(action: response.actionIdentifier, draftID: draftID, operationID: operationID, sessionID: sessionID)
    }

    private func route(action: String, draftID: UUID?, operationID: UUID?, sessionID: String?) async {
        guard let draftID else { return }
        switch action {
        case Action.send: await confirm?(draftID, operationID)
        case Action.cancel: await cancel?(draftID, operationID)
        case Action.open:
            if let sessionID, !sessionID.isEmpty { await openSession?(sessionID) }
        default: showMeeting?(draftID)
        }
    }
}
