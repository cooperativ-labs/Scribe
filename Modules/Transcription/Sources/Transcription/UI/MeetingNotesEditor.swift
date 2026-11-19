import AppKit
import SwiftUI

/// The meeting notes editor: one plain-text view with a gutter of recording
/// times, one per note.
///
/// A note is a paragraph — a run of non-empty lines — and a blank line starts
/// the next one. Each note's identity and stamp ride on its characters as a
/// text attribute, so typing, pasting, splitting, joining, undo and redo keep
/// stamps with the words they belong to (the rules are in
/// `MeetingNotesText`). Nothing here runs on a timer: the stamp for a new note
/// is read from `clock` when its first character is typed, so a ticking
/// recording clock elsewhere never touches the text or the caret.
///
/// Every change is reported with the draft ID the editor was opened for, so
/// switching rows while a write is in flight cannot redirect it.
public struct MeetingNotesEditor: NSViewRepresentable {
    public let draftID: UUID
    public let notes: [MeetingNote]
    public let isEditable: Bool
    public let placeholder: String
    public let clock: @MainActor () -> Int?
    public let canSeek: @MainActor (Int?) -> Bool
    public let onSeek: @MainActor (Int) -> Void
    public let onNotesChange: @MainActor (UUID, [MeetingNote]) -> Void
    public let onEndEditing: @MainActor (UUID) -> Void
    /// True while the notes have keyboard focus, so the window can stand its
    /// single-key shortcuts (Space plays) and its own undo aside.
    public let onFocusChange: @MainActor (Bool) -> Void

    public init(
        draftID: UUID,
        notes: [MeetingNote],
        isEditable: Bool = true,
        placeholder: String = "Write notes for the agent. Each paragraph is a note, stamped with the recording time.",
        clock: @escaping @MainActor () -> Int?,
        canSeek: @escaping @MainActor (Int?) -> Bool = { _ in false },
        onSeek: @escaping @MainActor (Int) -> Void = { _ in },
        onNotesChange: @escaping @MainActor (UUID, [MeetingNote]) -> Void,
        onEndEditing: @escaping @MainActor (UUID) -> Void = { _ in },
        onFocusChange: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        self.draftID = draftID
        self.notes = notes
        self.isEditable = isEditable
        self.placeholder = placeholder
        self.clock = clock
        self.canSeek = canSeek
        self.onSeek = onSeek
        self.onNotesChange = onNotesChange
        self.onEndEditing = onEndEditing
        self.onFocusChange = onFocusChange
    }

    public func makeNSView(context: Context) -> MeetingNotesEditorView {
        let view = MeetingNotesEditorView()
        view.configure(with: self)
        return view
    }

    public func updateNSView(_ view: MeetingNotesEditorView, context: Context) {
        view.configure(with: self)
    }

    public static func dismantleNSView(_ view: MeetingNotesEditorView, coordinator: ()) {
        view.dismantle()
    }
}

/// The attribute that carries a note's identity and stamp on its text.
final class MeetingNoteTagAttribute: NSObject {
    static let key = NSAttributedString.Key("ScribeMeetingNoteTag")
    let tag: MeetingNoteTag

    init(_ tag: MeetingNoteTag) { self.tag = tag }

    override func isEqual(_ object: Any?) -> Bool {
        (object as? MeetingNoteTagAttribute)?.tag == tag
    }

    override var hash: Int { tag.hashValue }
}

@MainActor
public final class MeetingNotesEditorView: NSView, NSTextViewDelegate {
    static let gutterWidth: CGFloat = 64
    static let bodyFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    static let stampFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)

    let scrollView = NSScrollView()
    let textView: NSTextView
    private let container = FlippedView()
    private let gutter = FlippedView()
    private let placeholderLabel = NSTextField(labelWithString: "")
    private var stampButtons: [StampButton] = []

    private var configuration: MeetingNotesEditor?
    private(set) var draftID: UUID?
    /// The notes last reported to, or received from, the owner. Incoming
    /// notes equal to these are the editor's own echo and change nothing.
    private(set) var publishedNotes: [MeetingNote] = []
    private var isNormalizing = false
    private var hasFocus = false
    /// Where the edit under way puts new text. Typed, pasted and dropped text
    /// arrives carrying the attributes of the text before it; it is cleared
    /// so it never silently joins that note's identity. Undo and redo keep
    /// theirs: that is how stamps come back.
    private var insertedRanges: [NSRange] = []

    override init(frame frameRect: NSRect) {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)
        textView = NotesTextView(frame: .zero, textContainer: textContainer)
        super.init(frame: frameRect)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func setUp() {
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        container.autoresizingMask = [.width]
        scrollView.documentView = container
        gutter.autoresizingMask = [.height]
        container.addSubview(gutter)

        textView.delegate = self
        (textView as? NotesTextView)?.focusDidChange = { [weak self] focused in
            self?.hasFocus = focused
            self?.configuration?.onFocusChange(focused)
        }
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 0, height: 10)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = Self.bodyFont
        textView.typingAttributes = Self.baseAttributes
        textView.setAccessibilityLabel("Meeting notes")
        textView.postsFrameChangedNotifications = true
        container.addSubview(textView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(textFrameDidChange), name: NSView.frameDidChangeNotification, object: textView
        )

        placeholderLabel.textColor = .placeholderTextColor
        placeholderLabel.font = Self.bodyFont
        placeholderLabel.lineBreakMode = .byWordWrapping
        placeholderLabel.maximumNumberOfLines = 3
        placeholderLabel.setAccessibilityElement(false)
        container.addSubview(placeholderLabel)

        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipFrameDidChange), name: NSView.frameDidChangeNotification, object: scrollView.contentView
        )
    }

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: NSColor.labelColor]
    }

    override public func layout() {
        super.layout()
        layoutDocument()
    }

    // MARK: - Configuration

    func configure(with editor: MeetingNotesEditor) {
        configuration = editor
        textView.isEditable = editor.isEditable
        textView.isSelectable = true
        placeholderLabel.stringValue = editor.isEditable ? editor.placeholder : ""
        if draftID != editor.draftID {
            if let previous = draftID { self.configuration?.onEndEditing(previous) }
            draftID = editor.draftID
            loadNotes(editor.notes, keepingSelection: false)
        } else if editor.notes != publishedNotes, !textView.hasMarkedText() {
            // Changed somewhere else (another window, a combine). The
            // caret stays where it was as far as the new text allows.
            loadNotes(editor.notes, keepingSelection: true)
        } else {
            updateStamps()
        }
    }

    /// Replaces the text with `notes`. Only ever called for a different
    /// draft or a change made elsewhere — never for the editor's own edits.
    private func loadNotes(_ notes: [MeetingNote], keepingSelection: Bool) {
        let selection = textView.selectedRange()
        let text = MeetingNotesText.text(for: notes)
        let attributed = NSMutableAttributedString(string: text, attributes: Self.baseAttributes)
        for (note, range) in zip(notes, MeetingNotesText.ranges(for: notes)) {
            let tag = MeetingNoteTag(id: note.id, recordingOffsetMilliseconds: note.recordingOffsetMilliseconds)
            attributed.addAttribute(MeetingNoteTagAttribute.key, value: MeetingNoteTagAttribute(tag), range: range)
        }
        isNormalizing = true
        textView.textStorage?.setAttributedString(attributed)
        isNormalizing = false
        // Undo steps recorded against the old text would replay into this one.
        if let undoManager = textView.undoManager {
            undoManager.removeAllActions(withTarget: textView)
            if let storage = textView.textStorage { undoManager.removeAllActions(withTarget: storage) }
        }
        textView.typingAttributes = Self.baseAttributes
        let length = (text as NSString).length
        if keepingSelection {
            let location = min(selection.location, length)
            textView.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
        } else {
            textView.setSelectedRange(NSRange(location: length, length: 0))
        }
        publishedNotes = notes
        layoutDocument()
    }

    func endEditingSession() {
        guard let draftID else { return }
        configuration?.onEndEditing(draftID)
    }

    /// The editor is leaving the screen: write the notes and give the
    /// window its shortcuts back.
    func dismantle() {
        endEditingSession()
        if hasFocus {
            hasFocus = false
            configuration?.onFocusChange(false)
        }
    }

    // MARK: - Editing

    public func textView(
        _ textView: NSTextView,
        shouldChangeTypingAttributes oldTypingAttributes: [String: Any] = [:],
        toAttributes newTypingAttributes: [NSAttributedString.Key: Any] = [:]
    ) -> [NSAttributedString.Key: Any] {
        // Typed and pasted text carries no note identity; `normalize` decides
        // whether it extends a note or starts one.
        var attributes = newTypingAttributes
        attributes[MeetingNoteTagAttribute.key] = nil
        return attributes
    }

    public func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard !isNormalizing else { return true }
        let restoring = textView.undoManager.map { $0.isUndoing || $0.isRedoing } ?? false
        if let replacementString, !restoring {
            insertedRanges.append(NSRange(location: affectedCharRange.location, length: (replacementString as NSString).length))
        }
        return true
    }

    public func textDidChange(_ notification: Notification) {
        guard !isNormalizing else { return }
        clearInsertedIdentity()
        // IME composition is not text yet: no note starts until it commits.
        guard !textView.hasMarkedText() else {
            layoutDocument()
            return
        }
        normalize()
    }

    public func textDidEndEditing(_ notification: Notification) {
        endEditingSession()
    }

    private func clearInsertedIdentity() {
        guard let storage = textView.textStorage else { return }
        let ranges = insertedRanges
        insertedRanges = []
        isNormalizing = true
        for range in ranges {
            let clamped = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
            if clamped.length > 0 { storage.removeAttribute(MeetingNoteTagAttribute.key, range: clamped) }
        }
        isNormalizing = false
    }

    /// Re-derives the notes after an edit, stamps any new ones, and reports
    /// the result. Attributes are set directly on the storage, outside the
    /// undo stack, so undo replays the person's edits and the stamps come
    /// back with the text they were on.
    func normalize() {
        guard let storage = textView.textStorage, let configuration, let draftID else { return }
        let text = storage.string
        let ranges = MeetingNotesText.groupRanges(in: text)
        let groups = ranges.map { range -> MeetingNotesText.Group in
            var group = MeetingNotesText.Group(range: range)
            storage.enumerateAttribute(MeetingNoteTagAttribute.key, in: range) { value, _, _ in
                if let tag = (value as? MeetingNoteTagAttribute)?.tag {
                    if !group.tags.contains(tag) { group.tags.append(tag) }
                } else {
                    group.hasUntaggedText = true
                }
            }
            return group
        }
        var clockReading: Int??
        let tags = MeetingNotesText.resolve(groups) {
            // One reading per edit: notes pasted together share the paste time.
            if let clockReading { return clockReading }
            let reading = configuration.clock()
            clockReading = .some(reading)
            return reading
        }

        isNormalizing = true
        storage.beginEditing()
        storage.removeAttribute(MeetingNoteTagAttribute.key, range: NSRange(location: 0, length: storage.length))
        for (range, tag) in zip(ranges, tags) {
            storage.addAttribute(MeetingNoteTagAttribute.key, value: MeetingNoteTagAttribute(tag), range: range)
        }
        storage.endEditing()
        isNormalizing = false

        let notes = MeetingNotesText.notes(in: text, ranges: ranges, tags: tags)
        layoutDocument()
        guard notes != publishedNotes else { return }
        publishedNotes = notes
        configuration.onNotesChange(draftID, notes)
    }

    // MARK: - Layout

    @objc private func clipFrameDidChange() { layoutDocument() }
    @objc private func textFrameDidChange() { layoutDocument() }

    private var isLayingOut = false

    /// Sizes the text beside the gutter, the document to the text, and puts
    /// each stamp beside its note's first line.
    func layoutDocument() {
        guard !isLayingOut else { return }
        isLayingOut = true
        defer { isLayingOut = false }
        let clip = scrollView.contentView.bounds.size
        let width = max(clip.width, Self.gutterWidth + 80)
        textView.minSize = NSSize(width: 0, height: clip.height)
        if textView.frame.origin.x != Self.gutterWidth || abs(textView.frame.width - (width - Self.gutterWidth)) > 0.5 {
            textView.frame = NSRect(x: Self.gutterWidth, y: 0, width: width - Self.gutterWidth, height: textView.frame.height)
        }
        if let layoutManager = textView.layoutManager, let textContainer = textView.textContainer {
            layoutManager.ensureLayout(for: textContainer)
        }
        textView.sizeToFit()
        let height = max(textView.frame.height, clip.height)
        container.frame = NSRect(x: 0, y: 0, width: width, height: height)
        gutter.frame = NSRect(x: 0, y: 0, width: Self.gutterWidth, height: height)

        let inset = textView.textContainerInset
        let padding = textView.textContainer?.lineFragmentPadding ?? 0
        placeholderLabel.isHidden = !textView.string.isEmpty || placeholderLabel.stringValue.isEmpty
        placeholderLabel.preferredMaxLayoutWidth = max(40, textView.frame.width - padding * 2 - 8)
        let size = placeholderLabel.sizeThatFits(NSSize(width: placeholderLabel.preferredMaxLayoutWidth, height: .greatestFiniteMagnitude))
        placeholderLabel.frame = NSRect(x: Self.gutterWidth + padding, y: inset.height, width: placeholderLabel.preferredMaxLayoutWidth, height: size.height)
        updateStamps()
    }

    /// One button per note: its time, moving playback there when the
    /// recording can be played.
    private func updateStamps() {
        guard let configuration, let storage = textView.textStorage,
              let layoutManager = textView.layoutManager else { return }
        let ranges = MeetingNotesText.groupRanges(in: storage.string)
        var placements: [(tag: MeetingNoteTag?, rect: NSRect)] = []
        for range in ranges {
            let tag = (storage.attribute(MeetingNoteTagAttribute.key, at: range.location, effectiveRange: nil) as? MeetingNoteTagAttribute)?.tag
            let glyph = layoutManager.glyphIndexForCharacter(at: range.location)
            guard glyph < layoutManager.numberOfGlyphs else { continue }
            var line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            line.origin.y += textView.textContainerOrigin.y + textView.frame.minY
            placements.append((tag, line))
        }
        while stampButtons.count > placements.count { stampButtons.removeLast().removeFromSuperview() }
        while stampButtons.count < placements.count {
            let button = StampButton()
            button.target = self
            button.action = #selector(seek(_:))
            gutter.addSubview(button)
            stampButtons.append(button)
        }
        for (button, placement) in zip(stampButtons, placements) {
            let offset = placement.tag?.recordingOffsetMilliseconds
            button.offsetMilliseconds = offset
            // A note still being composed has no tag until it commits.
            button.isHidden = placement.tag == nil
            button.isEnabled = configuration.canSeek(offset)
            button.setStamp(MeetingNotesText.stampText(offset), seekable: button.isEnabled)
            button.setAccessibilityLabel(MeetingNotesText.accessibilityLabel(offset))
            button.setAccessibilityHelp(button.isEnabled
                ? "Moves playback to this note\u{2019}s time."
                : (offset == nil ? "This note was written while nothing was being recorded." : "Playback is not available for this note."))
            let height: CGFloat = 18
            button.frame = NSRect(
                x: 6,
                y: placement.rect.minY + max(0, (placement.rect.height - height) / 2),
                width: Self.gutterWidth - 14,
                height: height
            )
        }
        // Stamps follow the text in the key view loop, so Control-Tab out of
        // the notes reaches them.
        var previous: NSView = textView
        for button in stampButtons where !button.isHidden && button.isEnabled {
            previous.nextKeyView = button
            previous = button
        }
    }

    @objc private func seek(_ sender: StampButton) {
        guard let offset = sender.offsetMilliseconds, configuration?.canSeek(offset) == true else { return }
        configuration?.onSeek(offset)
    }

    // MARK: - Test support

    /// The notes the editor holds now, as it would report them.
    var currentNotes: [MeetingNote] { publishedNotes }
    var stampButtonsForTesting: [NSButton] { stampButtons.filter { !$0.isHidden } }
    /// The stamps shown in the gutter, top to bottom.
    var visibleStamps: [(text: String, enabled: Bool, label: String)] {
        stampButtons.filter { !$0.isHidden }.map { ($0.title, $0.isEnabled, $0.accessibilityLabel() ?? "") }
    }
}

/// Reports keyboard focus, which `NSTextViewDelegate` does not.
final class NotesTextView: NSTextView {
    var focusDidChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { focusDidChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { focusDidChange?(false) }
        return resigned
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A note's time in the gutter: a borderless monospaced button.
final class StampButton: NSButton {
    var offsetMilliseconds: Int?

    init() {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .inline
        setButtonType(.momentaryPushIn)
        alignment = .right
        focusRingType = .default
        font = MeetingNotesEditorView.stampFont
        setAccessibilityRole(.button)
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        performClick(nil)
        return true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setStamp(_ text: String, seekable: Bool) {
        title = text
        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: MeetingNotesEditorView.stampFont,
            .foregroundColor: seekable ? NSColor.controlAccentColor : NSColor.secondaryLabelColor,
        ])
    }

    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }
}
