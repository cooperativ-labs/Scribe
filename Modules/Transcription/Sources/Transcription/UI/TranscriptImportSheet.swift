import SwiftUI

struct TranscriptImportSheet: View {
    let viewModel: TranscriptViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""
    @State private var format: TranscriptImportFormat = .fireflies
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import Transcript").font(.title2.weight(.semibold))
            TextField("Title", text: $title)
                .accessibilityLabel("Transcript title")
            Picker("Import format", selection: $format) {
                ForEach(TranscriptImportFormat.allCases) { format in
                    Text(format.displayName).tag(format)
                }
            }
            .pickerStyle(.menu)
            Text("Paste turns in the format: Speaker (01:35): Text. You can also use HH:MM:SS timestamps.")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body.monospaced())
                .accessibilityLabel("Transcript text")
                .border(.separator)
            Text("Imported transcripts support editing, export, and Send to Agent. No audio is imported. Turn end times and duration are estimated.")
                .font(.callout).foregroundStyle(.secondary)
            if let error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import Transcript") {
                    do {
                        try viewModel.importPastedTranscript(text, format: format, title: title)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 600, height: 540)
    }
}
