import Foundation

/// The system prompt and the delimited input blocks of proposal section 7.2.
///
/// Each source goes in its own tagged block so the model cannot mistake the
/// screen for the selection or the instruction for either; empty blocks are
/// left out rather than sent empty.
public enum AssistPrompt {
    /// Replaced with the frontmost app's name, or "an app" when it is unknown.
    public static let applicationPlaceholder = "{application}"

    public static let defaultSystemPrompt = """
    You are a writing assistant working inside a text field in {application}. \
    The user has spoken an instruction. You are given, when available, the text they selected, \
    text they just copied, and the text visible in the app's windows. Prefer the selection, \
    then the copied text, then the screen; treat the screen text as what the user is reading, \
    not as something to edit, unless the instruction says otherwise. Do exactly what the \
    instruction asks and return only the text to insert: no preamble, no explanation, no code \
    fences unless the user asked for code, no quoting of the original unless asked. If the \
    instruction asks for a reply, write the reply in the user's voice, in the language of the \
    instruction, without a subject line. If the instruction is not about any of the text, still \
    answer it.
    """

    /// The instructions sent with the request: `template` (the person's edited
    /// prompt, or the default when nil or blank) with the app name filled in.
    public static func system(template: String?, applicationName: String?) -> String {
        let trimmed = template?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base = trimmed.isEmpty ? defaultSystemPrompt : trimmed
        let name = applicationName.flatMap { $0.isEmpty ? nil : $0 } ?? "an app"
        return base.replacingOccurrences(of: applicationPlaceholder, with: name)
    }

    /// The user message: selection, copied text, screen text and instruction, in that order.
    public static func input(for request: AssistRequest) -> String {
        var blocks: [String] = []
        if let selected = nonEmpty(request.selectedText) {
            blocks.append(block("selected_text", body: selected))
        }
        if let copied = nonEmpty(request.copiedText) {
            blocks.append(block("copied_text", body: copied))
        }
        let windows = request.screenText.filter { nonEmpty($0.text) != nil }
        if !windows.isEmpty {
            var attributes = ""
            if let app = nonEmpty(request.applicationName) {
                attributes += " app=\"\(attribute(app))\""
            }
            attributes += " truncated=\"\(request.truncated)\""
            let inner = windows.map { window in
                var windowAttributes = ""
                if let title = nonEmpty(window.title) {
                    windowAttributes += " title=\"\(attribute(title))\""
                }
                if window.isFocused { windowAttributes += " focused=\"true\"" }
                return "<window\(windowAttributes)>\n\(neutralised(window.text))\n</window>"
            }
            blocks.append("<screen_text\(attributes)>\n\(inner.joined(separator: "\n"))\n</screen_text>")
        }
        blocks.append(block("instruction", body: request.instruction, attributes: " locale=\"\(attribute(request.locale))\""))
        return blocks.joined(separator: "\n\n")
    }

    private static let tags = ["selected_text", "copied_text", "screen_text", "window", "instruction"]

    private static func block(_ tag: String, body: String, attributes: String = "") -> String {
        "<\(tag)\(attributes)>\n\(neutralised(body))\n</\(tag)>"
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// Source text that happens to contain one of these closing tags (an email
    /// quoting a prompt, say) must not end its block early.
    private static func neutralised(_ text: String) -> String {
        var result = text
        for tag in tags where result.contains("</\(tag)") {
            result = result.replacingOccurrences(of: "</\(tag)", with: "<\\/\(tag)")
        }
        return result
    }

    private static func attribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
