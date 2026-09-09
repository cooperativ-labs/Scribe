import SwiftUI

/// Confirms a speaker-count reprocess, then shows pipeline progress through completion.
///
/// Choosing a count from the toolbar opens this sheet before anything is queued.
/// After confirmation it stays open so the person can see stages finish rather than
/// only a banner that the run was queued.
struct TranscriptReprocessSheet: View {
    @Bindable var viewModel: TranscriptViewModel

    @Environment(\.dismiss) private var dismiss

    private var session: TranscriptReprocessSession? { viewModel.reprocessSession }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            footer
        }
        .frame(width: 440)
        .interactiveDismissDisabled(session?.phase.isInFlight == true)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title3.weight(.semibold))
            if let session {
                Text("\u{201C}\(session.displayName)\u{201D}")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var content: some View {
        switch session?.phase {
        case .confirming, nil:
            confirmationBody
        case .queued:
            progressBody(
                label: "Waiting in the transcription queue\u{2026}",
                progress: 0,
                detail: "This transcript and its edits stay on screen until the new run finishes."
            )
        case let .processing(stageLabel, progress):
            progressBody(
                label: stageLabel,
                progress: progress,
                detail: "Re-transcribing with \(session?.speakerCountDescription ?? "the chosen speaker count")."
            )
        case .complete:
            resultBody(
                systemImage: "checkmark.circle.fill",
                tint: .green,
                message: "Re-transcription finished. The new run is ready to review."
            )
        case let .failed(message):
            resultBody(
                systemImage: "exclamationmark.triangle.fill",
                tint: .red,
                message: message
            )
        }
    }

    private var confirmationBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(
                "Scribe will re-transcribe this recording with \(session?.speakerCountDescription ?? "the chosen speaker count"). Recognition and speaker separation run again from the retained audio."
            )
            .font(.body)
            .fixedSize(horizontal: false, vertical: true)
            Text("This transcript and its edits stay until the new run finishes. Exact counts can use FluidAudio\u{2019}s K-means fallback.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func progressBody(label: String, progress: Double, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(label)
                    .font(.body.weight(.medium))
            }
            ProgressView(value: progress)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func resultBody(systemImage: String, tint: Color, message: String) -> some View {
        Label(message, systemImage: systemImage)
            .font(.body)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .symbolRenderingMode(.hierarchical)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            switch session?.phase {
            case .confirming, nil:
                Button("Cancel", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Re-transcribe") {
                    Task { await viewModel.confirmReprocess() }
                }
                .keyboardShortcut(.defaultAction)
            case .queued, .processing:
                Button("Hide") { close() }
                    .help("The run keeps going. Open this transcript again when it finishes.")
            case .complete, .failed:
                Button("Done") { close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
    }

    private var title: String {
        switch session?.phase {
        case .confirming, nil: "Re-transcribe with chosen speakers?"
        case .queued, .processing: "Re-transcribing"
        case .complete: "Re-transcription complete"
        case .failed: "Re-transcription failed"
        }
    }

    private func close() {
        viewModel.dismissReprocessSession()
        dismiss()
    }
}
