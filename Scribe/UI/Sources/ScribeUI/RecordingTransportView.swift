import AppKit

/// The menu's top row: the controls a person opens the menu to use.
///
/// It is a custom view rather than menu items because the running controls sit
/// side by side, which no menu item can express, and because the row has to be
/// the first thing the eye lands on rather than a command to be found among the
/// others. The view is stateless: `apply(_:)` is the only way its appearance
/// changes, so the row and the rest of the menu always describe one snapshot.
@MainActor
final class RecordingTransportView: NSView {
    var startAction: () -> Void = {}
    var pauseAction: () -> Void = {}
    var resumeAction: () -> Void = {}
    var stopAction: () -> Void = {}

    private let stack = NSStackView()
    private let recordButton = NSButton()
    /// Pause while recording, Resume while paused. One button, because the two
    /// are the same control in opposite positions and swapping the label keeps
    /// Stop in the same place under the pointer.
    private let holdButton = NSButton()
    private let stopButton = NSButton()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 44))
        // The menu sizes itself to its widest item and stretches this row to
        // match, so the buttons stay flush with the rows beneath them.
        autoresizingMask = [.width]

        configure(recordButton, title: "Record", symbol: "record.circle", tint: .systemRed, action: #selector(record))
        configure(holdButton, title: "Pause", symbol: "pause.fill", tint: nil, action: #selector(hold))
        configure(stopButton, title: "Stop", symbol: "stop.fill", tint: .systemRed, action: #selector(stop))

        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        for button in [recordButton, holdButton, stopButton] { stack.addArrangedSubview(button) }
        addSubview(stack)

        NSLayoutConstraint.activate([
            // Matches the horizontal inset macOS gives a menu item's title, so
            // the row lines up with the text below it rather than floating.
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Renders one snapshot. Which pair of controls is shown comes from
    /// `transport`, never from whether an action happens to be enabled: a
    /// disabled Record button and a Record button replaced by Pause and Stop
    /// mean different things.
    func apply(_ presentation: MenuPresentation) {
        switch presentation.transport {
        case .idle:
            recordButton.isHidden = false
            holdButton.isHidden = true
            stopButton.isHidden = true
            recordButton.isEnabled = presentation.isStartEnabled
        case .running:
            recordButton.isHidden = true
            holdButton.isHidden = false
            stopButton.isHidden = false
            if presentation.isResumeEnabled {
                apply(title: "Resume", symbol: "play.fill", tint: nil, to: holdButton)
                holdButton.isEnabled = true
            } else {
                apply(title: "Pause", symbol: "pause.fill", tint: nil, to: holdButton)
                holdButton.isEnabled = presentation.isPauseEnabled
            }
            stopButton.isEnabled = presentation.isStopEnabled
        }
    }

    // MARK: Actions

    @objc private func record() { startAction() }
    @objc private func stop() { stopAction() }

    @objc private func hold() {
        // The button's own label is the intent: it was rendered from the same
        // snapshot the click is acting on.
        if holdButton.title == "Resume" { resumeAction() } else { pauseAction() }
    }

    // MARK: Appearance

    private func configure(_ button: NSButton, title: String, symbol: String, tint: NSColor?, action: Selector) {
        button.bezelStyle = .push
        button.controlSize = .large
        button.imagePosition = .imageLeading
        button.target = self
        button.action = action
        apply(title: title, symbol: symbol, tint: tint, to: button)
    }

    private func apply(title: String, symbol: String, tint: NSColor?, to button: NSButton) {
        button.title = title
        button.image = Self.symbol(symbol, tint: tint)
        button.setAccessibilityLabel(title)
        button.toolTip = title
    }

    private static func symbol(_ name: String, tint: NSColor?) -> NSImage? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        var configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        if let tint {
            // A palette colour tints the glyph alone. `contentTintColor` would
            // take the label with it, and a red "Record" word reads as an error.
            configuration = configuration.applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        }
        return image.withSymbolConfiguration(configuration)
    }
}
