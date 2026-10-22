import AppKit
import Carbon.HIToolbox
import Foundation
import Platform

public struct DictationTextOptions: Sendable {
    public var leadingSpace = true
    public var trailingSpace = false
    public var restoreClipboard = true
    public init(leadingSpace: Bool = true, trailingSpace: Bool = false, restoreClipboard: Bool = true) {
        self.leadingSpace = leadingSpace
        self.trailingSpace = trailingSpace
        self.restoreClipboard = restoreClipboard
    }
}

public enum DictationInsertionOutcome: Sendable, Equatable {
    case accessibility
    case pasted
    case unverifiedPaste
    case copied
    case discarded
}

@MainActor
public protocol DictationPasteClient: AnyObject {
    func copyOnly(_ text: String)
    func insertAndReport(_ text: String, restoreClipboard: Bool) async -> PasteInsertionOutcome
}

extension KeystrokeTextInserter: DictationPasteClient {}

public enum DictationTextShaper {
    public static func shape(_ transcript: String, preceding: String?, atFieldStart: Bool?, options: DictationTextOptions) -> String? {
        var text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2, text.unicodeScalars.contains(where: { CharacterSet.letters.union(.decimalDigits).contains($0) }) else { return nil }
        switch sentencePosition(preceding: preceding, atFieldStart: atFieldStart) {
        case .start:
            if let firstLetter = text.firstIndex(where: { $0.isLetter }) {
                text.replaceSubrange(firstLetter...firstLetter, with: String(text[firstLetter]).uppercased())
            }
        case .middle:
            text = lowercasingSentenceCapital(text)
        case .unknown:
            break
        }
        if options.leadingSpace, atFieldStart != true,
           preceding?.last.map({ !$0.isWhitespace && !$0.isNewline }) ?? true { text = " " + text }
        if options.trailingSpace { text += " " }
        return text
    }

    private enum SentencePosition { case start, middle, unknown }

    /// Reads the text before the caret, skipping spaces, to decide whether the
    /// dictation opens a sentence. Anything ambiguous (a colon, an opening
    /// quote, an ellipsis, a list hyphen, no context at all) leaves the transcript's own case.
    private static func sentencePosition(preceding: String?, atFieldStart: Bool?) -> SentencePosition {
        if atFieldStart == true { return .start }
        guard let preceding else { return .unknown }
        // A line break after the last word opens a new line, as does a window
        // of nothing but whitespace that contains one.
        let lastIndex = preceding.lastIndex(where: { !$0.isWhitespace })
        let gap = lastIndex.map { preceding[preceding.index(after: $0)...] } ?? preceding[...]
        if gap.contains(where: \.isNewline) { return .start }
        guard let lastIndex else { return .unknown }
        var body = preceding[...lastIndex]
        while let last = body.last, "\"'”’)]»".contains(last) { body = body.dropLast() }
        guard let last = body.last else { return .unknown }
        if last == "…" || body.hasSuffix("..") { return .unknown }
        if ".!?".contains(last) { return .start }
        if last.isLetter || last.isNumber || ",;–—".contains(last) { return .middle }
        return .unknown
    }

    /// Mid-sentence, the transcriber's sentence capital goes. Only a plain
    /// capitalised word is lowered: "I", its contractions and all-caps words
    /// such as acronyms keep their case.
    private static func lowercasingSentenceCapital(_ text: String) -> String {
        let word = text.prefix(while: { $0.isLetter || $0 == "'" || $0 == "’" })
        let letters = word.filter(\.isLetter)
        guard let first = letters.first, first.isUppercase,
              letters.dropFirst().allSatisfy({ !$0.isUppercase }),
              !(first == "I" && (word.count == 1 || "'’".contains(word[word.index(after: word.startIndex)])))
        else { return text }
        return first.lowercased() + text.dropFirst()
    }

    /// A model's answer keeps its own paragraphs and capitalisation. Only the
    /// outer whitespace goes, and a leading space is added only for a single
    /// line that follows a non-whitespace character.
    public static func shapeGenerated(_ answer: String, preceding: String?, options: DictationTextOptions) -> String? {
        var text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if options.leadingSpace, !text.contains(where: \.isNewline),
           let last = preceding?.last, !last.isWhitespace, !last.isNewline { text = " " + text }
        return text
    }
}

/// Coordinates AX work off the main actor and performs clipboard/event work on it.
@MainActor
public final class DictationTextInserter: TextInserting {
    private let locator: FocusedFieldLocator
    private let paste: any DictationPasteClient
    private let secureInputEnabled: @MainActor () -> Bool
    public var options: DictationTextOptions
    public convenience init(locator: FocusedFieldLocator = FocusedFieldLocator(),
                paste: any DictationPasteClient = KeystrokeTextInserter(),
                options: DictationTextOptions = .init()) {
        self.init(locator: locator, paste: paste, options: options,
                  secureInputEnabled: { IsSecureEventInputEnabled() })
    }

    init(locator: FocusedFieldLocator, paste: any DictationPasteClient,
         options: DictationTextOptions = .init(), secureInputEnabled: @escaping @MainActor () -> Bool) {
        self.locator = locator
        self.paste = paste
        self.options = options
        self.secureInputEnabled = secureInputEnabled
    }
    private static func allowsUnverifiedPaste(into pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.openai.codex"
    }
    public func insert(_ text: String) {
        Task { _ = await insertDictation(text) }
    }
    public func insertDictation(_ transcript: String) async -> DictationInsertionOutcome {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return .discarded }
        let screenTop = NSScreen.screens.first?.frame.maxY ?? 0
        let screens = NSScreen.screens.map(\.frame)
        let allowsUnverifiedPaste = Self.allowsUnverifiedPaste(into: pid)
        return await insertDictation(transcript, frontmostPID: pid, screenTop: screenTop, screens: screens,
                                    allowsUnverifiedPaste: allowsUnverifiedPaste) {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
    }

    public func insertDictation(_ transcript: String, frontmostPID pid: pid_t,
                                screenTop: CGFloat, screens: [CGRect],
                                allowsUnverifiedPaste: Bool = false,
                                currentPID: () -> pid_t?) async -> DictationInsertionOutcome {
        await insert(frontmostPID: pid, screenTop: screenTop, screens: screens,
                     allowsUnverifiedPaste: allowsUnverifiedPaste, currentPID: currentPID) { [options] preceding, atFieldStart in
            DictationTextShaper.shape(transcript, preceding: preceding, atFieldStart: atFieldStart, options: options)
        }
    }

    /// The assistant's answer: inserted once, replacing the selection when
    /// there is one (both `AXSelectedText` and a posted ⌘V replace it), or left
    /// on the clipboard when the person chose copy-only.
    public func insertGenerated(_ answer: String, copyOnly: Bool = false) async -> DictationInsertionOutcome {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return copyGenerated(answer)
        }
        let screenTop = NSScreen.screens.first?.frame.maxY ?? 0
        let screens = NSScreen.screens.map(\.frame)
        let allowsUnverifiedPaste = Self.allowsUnverifiedPaste(into: pid)
        return await insertGenerated(answer, copyOnly: copyOnly, frontmostPID: pid, screenTop: screenTop,
                                     screens: screens, allowsUnverifiedPaste: allowsUnverifiedPaste) {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
    }

    public func insertGenerated(_ answer: String, copyOnly: Bool = false, frontmostPID pid: pid_t,
                                screenTop: CGFloat, screens: [CGRect],
                                allowsUnverifiedPaste: Bool = false,
                                currentPID: () -> pid_t?) async -> DictationInsertionOutcome {
        if copyOnly { return copyGenerated(answer) }
        let outcome = await insert(frontmostPID: pid, screenTop: screenTop, screens: screens,
                                   allowsUnverifiedPaste: allowsUnverifiedPaste, currentPID: currentPID) { [options] preceding, _ in
            DictationTextShaper.shapeGenerated(answer, preceding: preceding, options: options)
        }
        // An answer the person waited for is never thrown away: when focus
        // moved or the field vanished it is left on the clipboard instead.
        return outcome == .discarded ? copyGenerated(answer) : outcome
    }

    private func copyGenerated(_ answer: String) -> DictationInsertionOutcome {
        guard let text = DictationTextShaper.shapeGenerated(answer, preceding: nil, options: options) else { return .discarded }
        paste.copyOnly(text)
        return .copied
    }

    private func insert(frontmostPID pid: pid_t, screenTop: CGFloat, screens: [CGRect],
                        allowsUnverifiedPaste: Bool, currentPID: () -> pid_t?,
                        shape: (_ preceding: String?, _ atFieldStart: Bool?) -> String?) async -> DictationInsertionOutcome {
        let snapshot = await locator.locate(frontmostPID: pid, screenTop: screenTop, screens: screens)
        guard snapshot?.isSecure != true else { return .discarded }
        if let snapshot, snapshot.isTextRole {
            let preceding = await locator.precedingText(snapshot)
            // A caret at location 0 has nothing before it, even when the field
            // reports a value (text after the caret, or a composer's "\n").
            let atFieldStart = snapshot.valueLength == 0 || snapshot.selectedRange?.location == 0
            guard let text = shape(preceding, atFieldStart) else { return .discarded }
            if currentPID() == pid, await locator.stillFocused(snapshot, frontmostPID: pid) {
                if snapshot.selectedTextSettable, await locator.insertDirect(text, into: snapshot) { return .accessibility }
                if currentPID() == pid, await locator.stillFocused(snapshot, frontmostPID: pid) {
                    switch await paste.insertAndReport(text, restoreClipboard: options.restoreClipboard) {
                    case .posted: return .pasted
                    case .copied, .failed: return .copied
                    }
                }
            }
        }
        guard let text = shape(nil, true) else { return .discarded }
        if allowsUnverifiedPaste, currentPID() == pid, !secureInputEnabled() {
            // This app may provide no AX field at all. Keep the transcript on
            // the clipboard because a posted Cmd-V cannot be verified here.
            switch await paste.insertAndReport(text, restoreClipboard: false) {
            case .posted: return .unverifiedPaste
            case .copied: return .copied
            case .failed:
                paste.copyOnly(text)
                return .copied
            }
        }
        if let snapshot, !snapshot.isTextRole {
            guard let copiedText = shape(nil, nil) else { return .discarded }
            paste.copyOnly(copiedText)
            return .copied
        }
        return .discarded
    }
}
