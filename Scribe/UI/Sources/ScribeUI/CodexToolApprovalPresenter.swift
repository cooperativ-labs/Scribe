import AppKit
import Assist

/// The voice request pauses here when an installed Codex tool asks the person
/// to choose an action. A dismissed dialog never approves anything.
@MainActor
enum CodexToolApprovalPresenter {
    static func answer(_ questions: [CodexUserQuestion]) -> [String: String]? {
        var answers: [String: String] = [:]
        for question in questions {
            guard !question.options.isEmpty else { return nil }
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Codex needs your input"
            alert.informativeText = question.question
            for option in question.options { alert.addButton(withTitle: option) }
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            guard index >= 0, index < question.options.count else { return nil }
            answers[question.id] = question.options[index]
        }
        return answers
    }
}
