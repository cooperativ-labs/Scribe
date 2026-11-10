import SwiftUI

/// Joins a recording with another part of the same call.
///
/// For a meeting whose recording was cut off and restarted: the person picks
/// the other part, checks which one came first, and confirms. Because the two
/// originals are replaced, the sheet says so before anything happens.
struct TranscriptCombineSheet: View {
    let viewModel: TranscriptViewModel
    let file: TranscriptReviewFile

    @State private var partnerID: TranscriptReviewFile.ID?
    /// Whether `file` plays first. Starts from the transcripts' dates.
    @State private var fileFirst = true
    @Environment(\.dismiss) private var dismiss

    private var candidates: [TranscriptReviewFile] { viewModel.combineCandidates(for: file) }
    private var partner: TranscriptReviewFile? { candidates.first { $0.id == partnerID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Combine Recordings").font(.title3)
            Text("For one call recorded in two parts. The second recording is added to the end of the first and their transcripts are joined, keeping your edits. Nothing is transcribed again.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if candidates.isEmpty {
                Text("No other recording can be combined with this one. Both need a finished transcript and their audio.")
                    .font(.callout)
            } else {
                Picker("Combine with", selection: $partnerID) {
                    Text("Choose a recording").tag(TranscriptReviewFile.ID?.none)
                    ForEach(candidates) { candidate in
                        Text("\(candidate.displayName) · \(candidate.sidebarDetail())")
                            .tag(Optional(candidate.id))
                    }
                }
                .onChange(of: partnerID) { orderByDate() }

                if let partner {
                    order(partner: partner)
                }
            }

            Label {
                Text("This cannot be undone. The two recordings and their transcripts are replaced by the combined one, and their earlier transcription runs are removed. People recognised as the same speaker in both parts are joined; anyone else stays a separate speaker you can merge afterwards. The original files you imported are left alone.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .font(.callout)
            .padding(10)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                if viewModel.isCombining {
                    ProgressView().controlSize(.small)
                    Text("Combining…").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(viewModel.isCombining)
                Button("Combine", role: .destructive) {
                    guard let partner else { return }
                    let (first, second) = fileFirst ? (file, partner) : (partner, file)
                    Task {
                        await viewModel.combine(firstFileID: first.id, secondFileID: second.id)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(partner == nil || viewModel.isCombining)
            }
        }
        .padding(16)
        .frame(width: 520)
        .onAppear {
            if partnerID == nil { partnerID = candidates.first?.id }
            orderByDate()
        }
    }

    @ViewBuilder
    private func order(partner: TranscriptReviewFile) -> some View {
        let parts = fileFirst ? [file, partner] : [partner, file]
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(parts.enumerated()), id: \.element.id) { index, part in
                    HStack(spacing: 6) {
                        Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                        Text(part.displayName).lineLimit(1)
                        Text(part.sidebarDetail()).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button("Swap Order", systemImage: "arrow.up.arrow.down") { fileFirst.toggle() }
                .help("Choose which recording plays first")
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    /// The earlier transcript goes first, the usual order for a restarted call.
    private func orderByDate() {
        guard let partner, let mine = file.createdDate, let theirs = partner.createdDate else { return }
        fileFirst = mine <= theirs
    }
}
