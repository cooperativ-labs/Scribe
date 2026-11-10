import AppKit
import SwiftUI

/// What the panel shows, republished whenever the recorder changes while the
/// panel is open, so the elapsed time and the source lists are always current.
@MainActor
final class StatusMenuState: ObservableObject {
    @Published var presentation: MenuPresentation
    @Published var content: StatusMenuContent

    init(presentation: MenuPresentation, content: StatusMenuContent) {
        self.presentation = presentation
        self.content = content
    }
}

/// The transport commands, kept apart from the rows because they are buttons
/// side by side rather than a list.
struct StatusMenuTransport {
    var start: () -> Void
    var pause: () -> Void
    var resume: () -> Void
    var stop: () -> Void
}

/// The status item's panel: the menu, drawn as a window.
///
/// A window rather than an `NSMenu` because macOS does not show a Dock app's
/// status-item menu over another app's full-screen Space, while a panel that
/// joins every Space it does show. The panel keeps the look of a menu: the
/// controls a person opens it for at the top, then rows that highlight under
/// the pointer.
struct StatusMenuView: View {
    @ObservedObject var state: StatusMenuState
    let transport: StatusMenuTransport
    /// Runs a command and closes the panel, the way a menu item closes its menu.
    let perform: (@escaping () -> Void) -> Void

    static let width: CGFloat = 280

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TransportRow(presentation: state.presentation, transport: transport, perform: perform)
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 6)
            ForEach(state.content.sections) { section in
                Divider().padding(.horizontal, 10).padding(.vertical, 4)
                ForEach(section.rows) { row in
                    StatusMenuRowView(row: row, perform: perform)
                }
            }
        }
        .padding(.bottom, 6)
        .frame(width: Self.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct TransportRow: View {
    let presentation: MenuPresentation
    let transport: StatusMenuTransport
    let perform: (@escaping () -> Void) -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Which controls are offered comes from `transport`, never from
            // whether an action is enabled: a disabled Record button and one
            // replaced by Pause and Stop mean different things.
            switch presentation.transport {
            case .idle:
                button("Record", symbol: "record.circle", tint: .red, enabled: presentation.isStartEnabled, action: transport.start)
            case .running:
                if presentation.isResumeEnabled {
                    button("Resume", symbol: "play.fill", tint: nil, enabled: true, action: transport.resume)
                } else {
                    button("Pause", symbol: "pause.fill", tint: nil, enabled: presentation.isPauseEnabled, action: transport.pause)
                }
                button("Stop", symbol: "stop.fill", tint: .red, enabled: presentation.isStopEnabled, action: transport.stop)
            }
        }
    }

    private func button(_ title: String, symbol: String, tint: Color?, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button { perform(action) } label: {
            // The glyph alone carries the tint: a red "Record" word reads as an error.
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol).foregroundStyle(tint ?? .primary)
            }
            .font(.system(size: 13, weight: .semibold))
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .disabled(!enabled)
        .help(title)
    }
}

private struct StatusMenuRowView: View {
    let row: StatusMenuRow
    let perform: (@escaping () -> Void) -> Void

    var body: some View {
        switch row {
        case .status(let title, let symbol):
            Label(title, systemImage: symbol)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .padding(.leading, MenuRowMetrics.textInset - 20)
                .padding(.trailing, MenuRowMetrics.inset)
                .padding(.vertical, 3)
        case .note(let text):
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, MenuRowMetrics.textInset)
                .padding(.trailing, MenuRowMetrics.inset)
                .padding(.vertical, 3)
        case .command(let command):
            MenuRowButton(isEnabled: command.isEnabled, action: { perform(command.perform) }) { highlighted in
                HStack(spacing: MenuRowMetrics.glyphSpacing) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .opacity(command.isOn == true ? 1 : 0)
                        .frame(width: MenuRowMetrics.glyphWidth)
                        .accessibilityHidden(true)
                    Text(command.title)
                    Spacer(minLength: 8)
                    if let shortcut = command.shortcut {
                        Text(shortcut).foregroundStyle(highlighted ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.tertiary))
                    }
                }
            }
            .accessibilityAddTraits(command.isOn == true ? .isSelected : [])
        case .choices(let choices):
            ChoicesRow(choices: choices)
        }
    }
}

/// A heading that folds open to its options in place.
private struct ChoicesRow: View {
    let choices: StatusMenuChoices
    @State private var isExpanded = false

    private static let optionHeight: CGFloat = 24
    /// Past this the options scroll, so a long application list cannot push
    /// the panel off the bottom of the screen.
    private static let maximumListHeight: CGFloat = 240

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuRowButton(isEnabled: true, action: { isExpanded.toggle() }) { highlighted in
                HStack(spacing: MenuRowMetrics.glyphSpacing) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: MenuRowMetrics.glyphWidth)
                        .accessibilityHidden(true)
                    Text(choices.title)
                    Spacer(minLength: 8)
                    if !isExpanded, let summary = choices.summary {
                        Text(summary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(highlighted ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                    }
                }
            }
            .accessibilityValue(choices.summary ?? "")
            .accessibilityHint(isExpanded ? "Hides the options" : "Shows the options")
            if isExpanded {
                let list = VStack(alignment: .leading, spacing: 0) {
                    ForEach(choices.options) { option in
                        MenuRowButton(isEnabled: true, action: option.select) { _ in
                            HStack(spacing: MenuRowMetrics.glyphSpacing) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .semibold))
                                    .opacity(option.isSelected ? 1 : 0)
                                    .frame(width: MenuRowMetrics.glyphWidth)
                                    .accessibilityHidden(true)
                                Text(option.title).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            .padding(.leading, 18)
                        }
                        .frame(height: Self.optionHeight)
                        .accessibilityAddTraits(option.isSelected ? .isSelected : [])
                    }
                }
                let height = CGFloat(choices.options.count) * Self.optionHeight
                if height > Self.maximumListHeight {
                    ScrollView { list }.frame(height: Self.maximumListHeight)
                } else {
                    list
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(choices.title)
    }
}

enum MenuRowMetrics {
    /// Matches the inset macOS gives a menu item's title.
    static let inset: CGFloat = 14
    /// Between the highlight and the panel edge.
    static let highlightInset: CGFloat = 5
    /// The checkmark or chevron column ahead of a row's title.
    static let glyphWidth: CGFloat = 12
    static let glyphSpacing: CGFloat = 6
    /// Where a row's title starts, so notes line up with the commands.
    static let textInset = highlightInset + (inset - 9) + glyphWidth + glyphSpacing
}

/// A full-width row that highlights under the pointer, as a menu item does.
private struct MenuRowButton<Label: View>: View {
    let isEnabled: Bool
    let action: () -> Void
    @ViewBuilder let label: (_ highlighted: Bool) -> Label
    @State private var isHovered = false

    var body: some View {
        let highlighted = isHovered && isEnabled
        Button(action: action) {
            label(highlighted)
                .font(.system(size: 13))
                .foregroundStyle(highlighted ? AnyShapeStyle(.white) : (isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary)))
                .padding(.horizontal, MenuRowMetrics.inset - 9)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(highlighted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .padding(.horizontal, MenuRowMetrics.highlightInset)
        .onHover { isHovered = $0 }
    }
}
