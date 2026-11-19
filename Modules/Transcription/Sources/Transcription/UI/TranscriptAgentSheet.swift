import SwiftUI

/// Hands one transcript to a coding agent: the meeting's notes as they will
/// be sent, then the same handoff tray the meeting shows under its notes.
///
/// The sheet is bound to the row it was opened for, not to whatever is
/// selected later. Imports and pasted transcripts have no notes, so they get
/// the tray alone and send immediately, as before. A send keeps the sheet
/// open with its result: where it went (and Open in Latch), or why it did
/// not go, with every setting still in place to try again.
struct TranscriptAgentSheet: View {
    @Bindable var viewModel: TranscriptViewModel
    let target: AgentHandoffTarget
    let transcriptName: String
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let notes = viewModel.handoffNotes(for: target) {
                HandoffNotesPreview(content: notes)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)
            }
            AgentHandoffTray(viewModel: viewModel, target: target, style: .full, sendsOnReturn: true)
            footer
        }
        .frame(width: 600)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Send to Agent")
                .font(.title3.weight(.semibold))
            Text(transcriptName)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private var footer: some View {
        HStack {
            Text("The session opens in Latch.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(isSent ? "Done" : "Close", action: dismiss)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var isSent: Bool {
        if case .sent? = viewModel.handoffStatus(for: target) { return true }
        return false
    }
}

/// The notes exactly as they will travel: a stamp and the text, read-only.
/// Editing stays in the notes editor, where stamps are kept right.
struct HandoffNotesPreview: View {
    let content: MeetingNotesContent

    private func noteList(_ notes: [MeetingNote]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(notes) { note in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(MeetingNotesText.stampText(note.recordingOffsetMilliseconds))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .leading)
                        .accessibilityLabel(MeetingNotesText.accessibilityLabel(note.recordingOffsetMilliseconds))
                    Text(note.text)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Notes").font(.headline)
                if case .editable(let notes) = content, !notes.isEmpty {
                    Text("\(notes.count)").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                Text("Sent with the prompt, labelled as yours")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            switch content {
            case .unavailable(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .editable(let notes) where notes.isEmpty:
                Text("No notes were written for this meeting. Only the transcript and prompt are sent.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .editable(let notes) where notes.count <= 4:
                noteList(notes)
            case .editable(let notes):
                // A fixed height: a scroll view's ideal height would leave
                // the sheet to guess.
                ScrollView { noteList(notes) }
                    .frame(height: 150)
            }
        }
    }
}
