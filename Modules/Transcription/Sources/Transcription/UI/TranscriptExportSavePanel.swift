import AppKit
import UniformTypeIdentifiers

/// The Save panel the review window uses to export a transcript.
///
/// This is a document export, not a folder picker: Settings still owns the
/// recordings location. The prompt is "Export" so the dialog cannot be mistaken
/// for choosing where Scribe stores transcripts.
enum TranscriptExportSavePanel {
    @MainActor
    static func pickFile(format: TranscriptExportFormat, suggestedBasename: String) -> URL? {
        run(
            message: "Save a \(format.rawValue.uppercased()) copy of this transcript. The recordings folder in Settings is unchanged.",
            suggestedBasename: suggestedBasename,
            contentTypes: [format.contentType]
        )
    }

    /// Asks for a name and folder; TXT, JSON, and SRT files are written beside each other.
    @MainActor
    static func pickSharedName(suggestedBasename: String) -> URL? {
        run(
            message: "TXT, JSON, and SRT copies will be saved using this name. The recordings folder in Settings is unchanged.",
            suggestedBasename: suggestedBasename,
            contentTypes: []
        )
    }

    @MainActor
    private static func run(
        message: String,
        suggestedBasename: String,
        contentTypes: [UTType]
    ) -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "Export Transcript"
        panel.message = message
        panel.prompt = "Export"
        panel.nameFieldLabel = "Export As:"
        panel.nameFieldStringValue = suggestedBasename
        if !contentTypes.isEmpty {
            panel.allowedContentTypes = contentTypes
        }
        return panel.runModal() == .OK ? panel.url : nil
    }
}
