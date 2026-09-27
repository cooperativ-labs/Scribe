import AppKit
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
    public static func shape(_ transcript: String, preceding: String?, fieldIsEmpty: Bool?, options: DictationTextOptions) -> String? {
        var text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2, text.unicodeScalars.contains(where: { CharacterSet.letters.union(.decimalDigits).contains($0) }) else { return nil }
        if let preceding, let last = preceding.last, ".!?".contains(last),
           let firstLetter = text.firstIndex(where: { $0.isLetter }) {
            text.replaceSubrange(firstLetter...firstLetter, with: String(text[firstLetter]).uppercased())
        }
        if options.leadingSpace, fieldIsEmpty != true,
           preceding?.last.map({ !$0.isWhitespace && !$0.isNewline }) ?? true { text = " " + text }
        if options.trailingSpace { text += " " }
        return text
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
    public var options: DictationTextOptions
    public init(locator: FocusedFieldLocator = FocusedFieldLocator(),
                paste: any DictationPasteClient = KeystrokeTextInserter(),
                options: DictationTextOptions = .init()) {
        self.locator = locator
        self.paste = paste
        self.options = options
    }
    public func insert(_ text: String) {
        Task { _ = await insertDictation(text) }
    }
    public func insertDictation(_ transcript: String) async -> DictationInsertionOutcome {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return .discarded }
        let screenTop = NSScreen.screens.first?.frame.maxY ?? 0
        let screens = NSScreen.screens.map(\.frame)
        return await insertDictation(transcript, frontmostPID: pid, screenTop: screenTop, screens: screens) {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
    }

    public func insertDictation(_ transcript: String, frontmostPID pid: pid_t,
                                screenTop: CGFloat, screens: [CGRect],
                                currentPID: () -> pid_t?) async -> DictationInsertionOutcome {
        await insert(frontmostPID: pid, screenTop: screenTop, screens: screens, currentPID: currentPID) { [options] preceding, fieldIsEmpty in
            DictationTextShaper.shape(transcript, preceding: preceding, fieldIsEmpty: fieldIsEmpty, options: options)
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
        return await insertGenerated(answer, copyOnly: copyOnly, frontmostPID: pid, screenTop: screenTop, screens: screens) {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
    }

    public func insertGenerated(_ answer: String, copyOnly: Bool = false, frontmostPID pid: pid_t,
                                screenTop: CGFloat, screens: [CGRect],
                                currentPID: () -> pid_t?) async -> DictationInsertionOutcome {
        if copyOnly { return copyGenerated(answer) }
        let outcome = await insert(frontmostPID: pid, screenTop: screenTop, screens: screens, currentPID: currentPID) { [options] preceding, _ in
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

    private func insert(frontmostPID pid: pid_t, screenTop: CGFloat, screens: [CGRect], currentPID: () -> pid_t?,
                        shape: (_ preceding: String?, _ fieldIsEmpty: Bool?) -> String?) async -> DictationInsertionOutcome {
        let snapshot = await locator.locate(frontmostPID: pid, screenTop: screenTop, screens: screens)
        guard let snapshot, !snapshot.isSecure else { return .discarded }
        guard snapshot.isTextRole else {
            guard let text = shape(nil, nil) else { return .discarded }
            paste.copyOnly(text)
            return .copied
        }
        let preceding = await locator.precedingCharacter(snapshot)
        guard let text = shape(preceding, snapshot.valueLength == 0) else { return .discarded }
        guard currentPID() == pid,
              await locator.stillFocused(snapshot, frontmostPID: pid) else { return .discarded }
        if snapshot.selectedTextSettable, await locator.insertDirect(text, into: snapshot) { return .accessibility }
        guard currentPID() == pid,
              await locator.stillFocused(snapshot, frontmostPID: pid) else { return .discarded }
        switch await paste.insertAndReport(text, restoreClipboard: options.restoreClipboard) {
        case .posted: return .pasted
        case .copied, .failed: return .copied
        }
    }
}
