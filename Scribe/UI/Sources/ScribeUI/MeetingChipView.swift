import SwiftUI

/// What the chip's buttons do. A struct rather than a pile of parameters so the view
/// can be rendered from a plain presentation in a preview or a test without a
/// coordinator behind it.
struct MeetingChipActions {
    var record: @MainActor () -> Void = {}
    var dismiss: @MainActor () -> Void = {}
    var hold: @MainActor () -> Void = {}
    var stop: @MainActor () -> Void = {}
    var copyTimestamp: @MainActor () -> Void = {}
}

/// The floating chip that appears under the menu bar icon.
///
/// It is a capsule of Liquid Glass rather than a panel or a notification for a
/// reason: it arrives unasked, over whatever the person is doing, and it has to
/// read as part of the menu bar it hangs from rather than as a window competing
/// with the call. Glass keeps the material of the desktop underneath visible,
/// so it sits on the screen instead of covering it.
///
/// `glassEffect` needs macOS 26; on macOS 15 the same shapes are drawn in the
/// system material, which is the closest thing the older system has.
struct MeetingChipView: View {
    let presentation: MeetingChipPresentation
    var actions = MeetingChipActions()

    var body: some View {
        chipContent
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .frame(minHeight: 48)
            .chipGlass()
            // The panel is transparent and borderless, so the shadow needs room
            // that is not painted; without it the glass is clipped square.
            .padding(12)
            .fixedSize()
    }

    @ViewBuilder
    private var chipContent: some View {
        switch presentation {
        case .hidden:
            // The panel is ordered out in this state; an empty body keeps the
            // hosting view from reporting a stale size on the way there.
            EmptyView()
        case .offer(let offer):
            offerRow(offer)
        case .session(let session):
            sessionRow(session)
        }
    }

    // MARK: Offer

    private func offerRow(_ offer: MeetingChipPresentation.Offer) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(offer.question)
                    .font(.system(size: 13, weight: .medium))
                // The website is the useful half of a browser call: it says
                // which of the open tabs Scribe means.
                if let domain = offer.domain {
                    Text(domain)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: true, vertical: false)

            HStack(spacing: 6) {
                Button(action: actions.record) {
                    Label("Record", systemImage: "record.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 4)
                }
                .chipProminentButton()
                .help("Start recording this meeting")

                circleButton(
                    symbol: "xmark",
                    label: "Dismiss",
                    help: "Do not record this meeting",
                    action: actions.dismiss
                )
            }
        }
    }

    // MARK: Session

    private func sessionRow(_ session: MeetingChipPresentation.Session) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                // Steady while recording, hollow while held: the dot is the only
                // thing on the chip that says which of the two is happening,
                // since the clock keeps advancing either way.
                Image(systemName: session.isPaused ? "circle" : "circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(session.isPaused ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.red))
                    .accessibilityLabel(session.isPaused ? "Paused" : "Recording")
                ElapsedTimestampButton(elapsedText: session.elapsedText, copy: actions.copyTimestamp)
            }

            Spacer(minLength: 16)

            HStack(spacing: 6) {
                circleButton(
                    symbol: session.isPaused ? "play.fill" : "pause.fill",
                    label: session.isPaused ? "Resume" : "Pause",
                    help: session.isPaused ? "Resume recording" : "Pause recording",
                    action: actions.hold
                )
                .disabled(!session.isHoldEnabled)

                circleButton(
                    symbol: "stop.fill",
                    label: "Stop",
                    help: "Stop and save this recording",
                    tint: .red,
                    action: actions.stop
                )
                .disabled(!session.isStopEnabled)
            }
        }
        // Wide enough that Pause and Stop do not slide sideways when the clock
        // passes an hour and grows a digit.
        .frame(minWidth: 190, alignment: .leading)
    }

    // MARK: Buttons

    /// Icon only, and round: the transport is the same three controls a person
    /// already knows, and at this size a label would be the whole chip.
    private func circleButton(
        symbol: String,
        label: String,
        help: String,
        tint: Color? = nil,
        action: @escaping @MainActor () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint ?? .primary)
                .frame(width: 30, height: 30)
                .contentShape(.circle)
        }
        .chipCircleButton()
        .accessibilityLabel(label)
        .help(help)
    }
}

/// The elapsed clock is also the copy control: notes taken during a meeting
/// need the current time, and the figure itself is the thing a person looks at
/// to get it.
private struct ElapsedTimestampButton: View {
    let elapsedText: String
    var copy: @MainActor () -> Void

    @State private var didCopy = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button(action: copyAndAcknowledge) {
            Text(didCopy ? "Copied" : elapsedText)
                .font(.system(size: 14, weight: .medium))
                .monospacedDigit()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy timestamp")
        .accessibilityLabel(didCopy ? "Timestamp copied" : "Copy timestamp \(elapsedText)")
        .accessibilityHint("Copies the current recording time for notes")
        .onDisappear { resetTask?.cancel() }
    }

    private func copyAndAcknowledge() {
        copy()
        didCopy = true
        resetTask?.cancel()
        resetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            didCopy = false
        }
    }
}

// MARK: - Liquid Glass

private extension View {
    /// The chip's own surface.
    @ViewBuilder
    func chipGlass() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: .capsule)
        } else {
            background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        }
    }

    /// Record: the one thing the chip is asking for, so it is the one filled
    /// control on it.
    @ViewBuilder
    func chipProminentButton() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent).tint(.red).controlSize(.regular)
        } else {
            buttonStyle(.borderedProminent).tint(.red).controlSize(.regular)
        }
    }

    @ViewBuilder
    func chipCircleButton() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass).buttonBorderShape(.circle)
        } else {
            buttonStyle(.bordered).buttonBorderShape(.circle)
        }
    }
}

// MARK: - Hosting

/// Redraws the chip as the model publishes. Kept apart from `MeetingChipView`
/// so the view itself stays a function of one presentation value.
struct MeetingChipHost: View {
    @ObservedObject var model: MeetingChipModel

    var body: some View {
        MeetingChipView(
            presentation: model.presentation,
            actions: MeetingChipActions(
                record: { model.record() },
                dismiss: { model.dismiss() },
                hold: { model.toggleHold() },
                stop: { model.stop() },
                copyTimestamp: { model.copyTimestamp() }
            )
        )
    }
}
