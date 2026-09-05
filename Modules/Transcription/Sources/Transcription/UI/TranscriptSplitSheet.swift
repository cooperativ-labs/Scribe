import SwiftUI

/// Chooses where one turn becomes two.
///
/// The words are laid out as they read, and clicking a word puts the break in
/// front of it. The two halves are previewed with the times they will get, so
/// an estimated boundary is visible before it is committed.
struct TranscriptSplitSheet: View {
    let viewModel: TranscriptViewModel
    let segment: TranscriptSegment

    @State private var splitIndex: Int?
    @Environment(\.dismiss) private var dismiss

    private var tokens: [TranscriptSplitToken] { viewModel.splitTokens(for: segment) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Split this turn").font(.title3)
            Text(tokens.contains { !$0.isTimed }
                 ? "Click the first word of the second half. This turn has no word timings, so the boundary will be estimated from where the break falls in the text and both halves marked as estimated timing."
                 : "Click the first word of the second half. Each half keeps the recognizer's timing for its own words.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                TranscriptFlowLayout(spacing: 4) {
                    ForEach(tokens) { token in
                        Button {
                            splitIndex = token.index == 0 ? nil : token.index
                        } label: {
                            HStack(spacing: 0) {
                                if let splitIndex, splitIndex == token.index {
                                    Rectangle()
                                        .fill(Color.accentColor)
                                        .frame(width: 2, height: 18)
                                        .padding(.trailing, 3)
                                }
                                Text(token.text)
                                    .foregroundStyle(token.index == 0 ? Color.secondary : Color.primary)
                            }
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .background(background(for: token), in: RoundedRectangle(cornerRadius: 5))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(token.index == 0)
                        .help(token.index == 0 ? "The first word always starts the first half." : "Begin the second half here")
                    }
                }
                .padding(8)
            }
            .frame(minHeight: 120, maxHeight: 260)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

            if let splitIndex {
                let head = tokens[..<splitIndex]
                let tail = tokens[splitIndex...]
                VStack(alignment: .leading, spacing: 6) {
                    preview(number: 1, tokens: Array(head), startMs: segment.startMs, endMs: head.last?.endMs ?? segment.endMs)
                    preview(number: 2, tokens: Array(tail), startMs: tail.first?.startMs ?? segment.startMs, endMs: segment.endMs)
                }
            } else {
                Text("No break chosen yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Split") {
                    guard let splitIndex else { return }
                    viewModel.split(segmentID: segment.id, beforeToken: splitIndex)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(splitIndex == nil)
            }
        }
        .padding(16)
        .frame(width: 560)
    }

    private func background(for token: TranscriptSplitToken) -> Color {
        guard let splitIndex else { return .clear }
        return token.index >= splitIndex ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08)
    }

    @ViewBuilder
    private func preview(number: Int, tokens: [TranscriptSplitToken], startMs: Int, endMs: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(number). \(TranscriptTimecode.string(fromMilliseconds: startMs)) – \(TranscriptTimecode.string(fromMilliseconds: endMs)) · \(segment.speakerLabel)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(tokens.map(\.text).joined(separator: " "))
                .lineLimit(3)
        }
    }
}

/// Lays subviews out left to right, wrapping like words in a paragraph.
struct TranscriptFlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        return arrange(subviews: subviews, in: width).size
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let arrangement = arrange(subviews: subviews, in: bounds.width)
        for (index, origin) in arrangement.origins.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(subviews: Subviews, in width: CGFloat) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}
