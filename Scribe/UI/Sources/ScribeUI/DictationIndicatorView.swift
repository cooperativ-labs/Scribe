import Dictation
import SwiftUI

/// A small, non-activating readout for the field that had focus at dictation start.
public struct DictationIndicatorView: View {
    @State private var shimmer = false
    public let livePreview: String?
    public let state: DictationState
    public let showsToggleControls: Bool
    public let showsTranscribingLabel: Bool
    public var stop: () -> Void = {}
    public var cancel: () -> Void = {}
    public var openSettings: () -> Void = {}

    public init(state: DictationState, livePreview: String? = nil, showsToggleControls: Bool = false,
                showsTranscribingLabel: Bool = false,
                stop: @escaping () -> Void = {}, cancel: @escaping () -> Void = {},
                openSettings: @escaping () -> Void = {}) {
        self.livePreview = livePreview
        self.state = state
        self.showsToggleControls = showsToggleControls
        self.showsTranscribingLabel = showsTranscribingLabel
        self.stop = stop
        self.cancel = cancel
        self.openSettings = openSettings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            status
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: livePreview == nil ? 26 : 16))
        .overlay(RoundedRectangle(cornerRadius: livePreview == nil ? 26 : 16).strokeBorder(.white.opacity(0.2)))
        .padding(9)
        .fixedSize()
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
                if showsToggleControls {
                    Text("Stop")
                        .foregroundStyle(.tint)
                        .onTapGesture(perform: stop)
                        .accessibilityAddTraits(.isButton)
                    Image(systemName: "xmark")
                        .foregroundStyle(.secondary)
                        .onTapGesture(perform: cancel)
                        .accessibilityLabel("Cancel dictation")
                        .accessibilityAddTraits(.isButton)
                }
            case .transcribing:
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
                if showsTranscribingLabel { Text("Transcribing…") }
            case .inserted(let application):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                if let application { Text("Inserted in \(application)") }
            case .copied:
                Image(systemName: "doc.on.clipboard")
                Text("Copied. Press ⌘V")
            case .error(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).lineLimit(1).frame(maxWidth: 280)
                Text("Settings")
                    .foregroundStyle(.tint)
                    .onTapGesture(perform: openSettings)
                    .accessibilityAddTraits(.isButton)
            }
        }
    }
}
