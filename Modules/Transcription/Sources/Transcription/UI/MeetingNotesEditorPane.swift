import SwiftUI

/// One draft's notes editor, reading its notes through the review model.
///
/// Its own view so that only it redraws when the notes change: the
/// Transcripts window and the floating notes panel each show one, bound to
/// the same draft ID and the same `TranscriptViewModel`, so an edit in one
/// reaches the other at once (`MeetingNotesEditor` reloads text that changed
/// elsewhere, keeping the caret, and never while IME text is being composed).
struct MeetingNotesEditorPane: View {
    @Bindable var viewModel: TranscriptViewModel
    let draftID: UUID
    var placeholder = "Write notes for the agent. Each paragraph is a note, stamped with the recording time."
    /// Whether a stamp may move playback. The panel has no player, so it
    /// passes false; the window asks the model.
    var canSeek: @MainActor (Int?) -> Bool = { _ in false }
    var onSeek: @MainActor (Int) -> Void = { _ in }
    var onFocusChange: @MainActor (Bool) -> Void = { _ in }

    var body: some View {
        switch viewModel.notesContent(draftID: draftID) {
        case .editable(let notes)?:
            MeetingNotesEditor(
                draftID: draftID,
                notes: notes,
                placeholder: placeholder,
                clock: { [viewModel] in viewModel.noteClock(draftID: draftID) },
                canSeek: canSeek,
                onSeek: onSeek,
                onNotesChange: { [viewModel] draftID, notes in viewModel.setNotes(draftID: draftID, notes: notes) },
                onEndEditing: { [viewModel] draftID in viewModel.flushNotes(draftID: draftID) },
                // Focus can change while SwiftUI is tearing the editor down;
                // the state follows on the next turn of the run loop.
                onFocusChange: { focused in DispatchQueue.main.async { onFocusChange(focused) } }
            )
            .id(draftID)
        case .unavailable(let message)?:
            ContentUnavailableView("Notes unavailable", systemImage: "exclamationmark.triangle", description: Text(message))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case nil:
            EmptyView()
        }
    }
}
