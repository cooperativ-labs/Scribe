import Dictation
import SwiftUI

/// A small, non-activating readout for the field that had focus at dictation start.
public struct DictationIndicatorView: View {
    @State private var shimmer = false
    public let livePreview: String?
    public let state: DictationState
    public let showsToggleControls: Bool
    public let showsTranscribingLabel: Bool
    /// The session is past its key: loading the model or transcribing can be
    /// abandoned with ✕. Off for the warm-up at launch, which is not a session.
    public let showsCancel: Bool
    /// Which mode the session belongs to; the assistant is labelled so the two
    /// gestures never look alike.
    public let intent: DictationIntent
    /// "Using copied text and what is on screen in Mail", once gathering finishes.
    public let assistantHint: String?
    public var stop: () -> Void = {}
    public var cancel: () -> Void = {}
    public var openSettings: () -> Void = {}

    public init(state: DictationState, livePreview: String? = nil, showsToggleControls: Bool = false,
                showsTranscribingLabel: Bool = false, showsCancel: Bool = false,
                intent: DictationIntent = .dictation,
                assistantHint: String? = nil,
                stop: @escaping () -> Void = {}, cancel: @escaping () -> Void = {},
                openSettings: @escaping () -> Void = {}) {
        self.livePreview = livePreview
        self.state = state
        self.showsToggleControls = showsToggleControls
        self.showsTranscribingLabel = showsTranscribingLabel
        self.showsCancel = showsCancel
        self.intent = intent
        self.assistantHint = assistantHint
        self.stop = stop
        self.cancel = cancel
        self.openSettings = openSettings
    }

    private var isAssistantListening: Bool {
        if intent == .assistant, case .listening = state { return true }
        return false
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            status
            if isAssistantListening, let assistantHint {
                Text(assistantHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 300, alignment: .leading)
            }
            if let livePreview {
                Text("Live Preview · Recent speech")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(livePreview)
                    .font(.system(size: 13))
                    .lineLimit(5)
                    .truncationMode(.head)
                    .frame(width: 320, height: 85, alignment: .topLeading)
                    .accessibilityLabel("Draft: \(livePreview)")
            }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.white.opacity(0.2)))
        .padding(9)
        .fixedSize()
    }

    private var cornerRadius: CGFloat {
        livePreview == nil && !(isAssistantListening && assistantHint != nil) ? 26 : 16
    }

    private var shimmerBar: some View {
        Capsule()
            .fill(LinearGradient(colors: [.secondary.opacity(0.25), .primary, .secondary.opacity(0.25)],
                                 startPoint: shimmer ? .trailing : .leading,
                                 endPoint: shimmer ? .leading : .trailing))
            .frame(width: 28, height: 5)
            .onAppear {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: true)) {
                    shimmer = true
                }
            }
    }

    private var cancelMark: some View {
        Image(systemName: "xmark")
            .foregroundStyle(.secondary)
            .onTapGesture(perform: cancel)
            .accessibilityLabel(intent == .assistant ? "Cancel assistant" : "Cancel dictation")
            .accessibilityAddTraits(.isButton)
    }

    private func link(_ title: String, action: @escaping () -> Void) -> some View {
        Text(title)
            .foregroundStyle(.tint)
            .onTapGesture(perform: action)
            .accessibilityAddTraits(.isButton)
    }

    private var status: some View {
        HStack(spacing: 9) {
            switch state {
            case .idle:
                EmptyView()
            case .warming:
                Image(systemName: "hourglass")
                    .symbolEffect(.pulse, options: .repeating)
                Text("Loading model…")
                if showsCancel { cancelMark }
            case .listening(let level):
                Image(systemName: "mic.fill").foregroundStyle(.red)
                    .symbolEffect(.pulse, options: .repeating)
                HStack(alignment: .center, spacing: 2) {
                    ForEach(0..<5) { index in
                        Capsule()
                            .fill(.primary)
                            .frame(width: 3, height: 5 + CGFloat(min(1, max(0, level)) * Float(10 + index * 3)))
                    }
                }.frame(height: 24)
                if intent == .assistant {
                    Text("Assistant").foregroundStyle(.secondary)
                }
                if showsToggleControls {
                    Text("Stop")
                        .foregroundStyle(.tint)
                        .onTapGesture(perform: stop)
                        .accessibilityAddTraits(.isButton)
                    cancelMark
                }
            case .transcribing:
                shimmerBar
                // Most transcriptions finish before the label; ✕ arrives with it.
                if showsTranscribingLabel {
                    Text("Transcribing…")
                    if showsCancel { cancelMark }
                }
            case .thinking(let assistant, let model):
                Image(systemName: "sparkles")
                    .symbolEffect(.pulse, options: .repeating)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Asking \(assistant)…")
                    if let model {
                        Text(model).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                cancelMark
            case .nothingToWorkWith(let application):
                Image(systemName: "text.badge.xmark").foregroundStyle(.secondary)
                Text(application.map { "Nothing to work with in \($0)" } ?? "Nothing to work with")
                    .lineLimit(1).frame(maxWidth: 280)
            case .signInRequired(let message):
                Image(systemName: "person.crop.circle.badge.exclamationmark").foregroundStyle(.orange)
                Text(message).lineLimit(1).frame(maxWidth: 280)
                link("Sign in", action: openSettings)
            case .inserted(let application):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                if let application { Text("Inserted in \(application)") }
            case .copied:
                Image(systemName: "doc.on.clipboard")
                Text("Copied. Press ⌘V")
            case .error(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).lineLimit(1).frame(maxWidth: 280)
                link("Settings", action: openSettings)
            }
        }
    }
}
