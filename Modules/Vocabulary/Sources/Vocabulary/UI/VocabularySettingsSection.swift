import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Vocabulary section of Scribe's Settings window.
///
/// It is a section rather than its own window because the thing being edited is
/// a list of words, and because the transcript window's "Vocabulary" button has
/// to land somewhere a person recognizes as the place this is configured.
public struct VocabularySettingsSection: View {
    @Bindable private var model: VocabularyViewModel
    @State private var isImporting = false
    @State private var isExporting = false
    @State private var isReplacingOnImport = false
    @State private var confirmingRemoveAll = false
    @FocusState private var isDraftFocused: Bool

    /// Set by the transcript window's button so the section says, on arrival,
    /// that this is the thing that was being looked for.
    private let isHighlighted: Bool

    public init(model: VocabularyViewModel, isHighlighted: Bool = false) {
        self.model = model
        self.isHighlighted = isHighlighted
    }

    public var body: some View {
        Section {
            Text("Names, companies, product spellings, and jargon Scribe should get right. One list, merged into every transcription — there is nothing to choose when a recording starts.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if model.personalTerms.count > 8 {
                searchField
            }
            termList
            addRow
            actionRow

            if let status = model.statusMessage {
                message(status, systemImage: "checkmark.circle.fill", tint: .green)
            }
            if let error = model.errorMessage {
                message(error, systemImage: "exclamationmark.triangle.fill", tint: .red)
            }

            Text("Applied to transcriptions that start from now on. Transcripts you already have keep their wording until you transcribe them again.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            storageFooter
        } header: {
            HStack {
                Text("Vocabulary")
                if isHighlighted {
                    Image(systemName: "arrow.left.circle.fill")
                        .foregroundStyle(.tint)
                        .transition(.opacity)
                }
                Spacer()
                if !model.summaryDescription.isEmpty {
                    Text(model.summaryDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .sheet(item: $model.editingTerm) { term in
            VocabularyTermEditor(term: term) { edited in
                model.save(edited, replacing: term)
            }
        }
        .onAppear { model.startWatching() }
        .onDisappear { model.stopWatching() }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.plainText, .text]) { result in
            switch result {
            case .success(let url): model.importGlossary(at: url, replacingExisting: isReplacingOnImport)
            case .failure(let error): model.importFailed(error)
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: VocabularyGlossaryDocument(text: VocabularyTextFormat.render(model.personalTerms)),
            contentType: .plainText,
            defaultFilename: "Scribe Vocabulary"
        ) { result in
            if case .failure(let error) = result { model.importFailed(error) }
        }
        .confirmationDialog(
            "Remove every term from the vocabulary?",
            isPresented: $confirmingRemoveAll,
            titleVisibility: .visible
        ) {
            Button("Remove All Terms", role: .destructive) { model.removeAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Existing transcripts are unaffected. Export first if you want a copy.")
        }
        .animation(.snappy, value: model.statusMessage)
    }

    // MARK: Pieces

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find a term", text: $model.searchText, prompt: Text("Find a term"))
                .labelsHidden()
                .textFieldStyle(.plain)
            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Clear search")
            }
        }
    }

    @ViewBuilder
    private var termList: some View {
        let terms = model.visibleTerms
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if terms.isEmpty {
                    emptyState
                } else {
                    ForEach(Array(terms.enumerated()), id: \.element.id) { index, term in
                        if index > 0 { Divider() }
                        VocabularyTermRow(
                            term: term,
                            edit: { model.editingTerm = term },
                            remove: { model.remove(term) }
                        )
                    }
                }
            }
            .padding(.vertical, 2)
        }
        // A window of the list, not the whole of it: a two-hundred-term
        // glossary must not push the rest of Settings off the screen.
        .frame(height: listHeight(for: terms))
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
    }

    /// Sized to the rows it has, up to a ceiling.
    ///
    /// A row with mishearings is a line taller than one without, so the height
    /// is summed rather than multiplied: a short list should end where its last
    /// row ends, not part-way through it.
    private func listHeight(for terms: [VocabularyTerm]) -> CGFloat {
        guard !terms.isEmpty else { return 76 }
        let content = terms.reduce(CGFloat(4)) { $0 + ($1.aliases.isEmpty ? 32 : 49) }
        return min(240, max(76, content))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.searchText.isEmpty ? "No terms yet" : "No term matches “\(model.searchText)”")
                .foregroundStyle(.secondary)
            if model.searchText.isEmpty {
                Text("Start with the names and product spellings that come out wrong today.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
    }

    /// Labels are hidden and the placeholders carry the meaning: a `Form` would
    /// otherwise render "Term" and "Also heard as" as left-hand labels, which
    /// turns a two-field row into two wrapped paragraphs.
    ///
    /// Return commits from either field through `onSubmit` rather than through a
    /// default-action shortcut, which would take Return from the rest of the
    /// settings window.
    private var addRow: some View {
        HStack(spacing: 8) {
            TextField("Term", text: $model.draftText, prompt: Text("Add a term"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .focused($isDraftFocused)
                .onSubmit(submitDraft)
            TextField("Also heard as", text: $model.draftAliases, prompt: Text("Also heard as, comma separated"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .onSubmit(submitDraft)
            Button("Add", action: submitDraft)
                .disabled(VocabularyText.sanitize(model.draftText).isEmpty)
        }
    }

    private var actionRow: some View {
        HStack {
            Button("Import…") {
                isReplacingOnImport = false
                isImporting = true
            }
            Button("Export…") { isExporting = true }
                .disabled(model.isEmpty)
            Spacer()
            Menu {
                Button("Replace with a File…") {
                    isReplacingOnImport = true
                    isImporting = true
                }
                Button("Reveal Vocabulary File in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.fileURL])
                }
                Divider()
                Button("Remove All Terms…", role: .destructive) { confirmingRemoveAll = true }
                    .disabled(model.isEmpty)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var storageFooter: some View {
        Text("A text file uses one term per line, as `Canonical: mishearing, other mishearing`. Agents and scripts can edit the same list with the `scribe-vocab` command.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }

    private func message(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(tint)
            .textSelection(.enabled)
    }

    private func submitDraft() {
        model.addDraftTerm()
        isDraftFocused = true
    }
}

/// One term as the list shows it: the spelling a person will read in the
/// transcript, then what it stands in for, then why it might not apply.
private struct VocabularyTermRow: View {
    let term: VocabularyTerm
    let edit: () -> Void
    let remove: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(term.text)
                        .fontWeight(.medium)
                        .foregroundStyle(term.isBoostable ? .primary : .secondary)
                    if !term.advisories.isEmpty {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help(term.advisories.map(\.message).joined(separator: "\n"))
                    }
                }
                if !term.aliases.isEmpty {
                    Text("heard as \(term.aliases.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            if isHovering {
                Button(action: edit) { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .help("Edit this term")
                    .accessibilityLabel("Edit \(term.text)")
                Button(action: remove) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Remove this term")
                    .accessibilityLabel("Remove \(term.text)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2, perform: edit)
        .contextMenu {
            Button("Edit…", action: edit)
            Button("Remove", role: .destructive, action: remove)
        }
    }
}

/// The full editor for one term, opened from a row.
private struct VocabularyTermEditor: View {
    @Environment(\.dismiss) private var dismiss

    let term: VocabularyTerm
    let save: (VocabularyTerm) -> Void

    @State private var text: String
    @State private var aliases: String
    @State private var notes: String

    init(term: VocabularyTerm, save: @escaping (VocabularyTerm) -> Void) {
        self.term = term
        self.save = save
        _text = State(initialValue: term.text)
        _aliases = State(initialValue: term.aliases.joined(separator: ", "))
        _notes = State(initialValue: term.notes ?? "")
    }

    private var edited: VocabularyTerm {
        term.updating(
            text: text,
            aliases: VocabularyText.splitAliases(aliases),
            notes: .some(notes)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Term", text: $text)
                    TextField("Also heard as", text: $aliases, prompt: Text("Liv Mali, Liv-Marli"))
                    TextField("Note", text: $notes, prompt: Text("Optional, for you only"))
                } footer: {
                    Text("Mishearings, not synonyms: list what the recognizer produces instead of this spelling. A synonym here will rewrite speech that was already correct.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if !edited.advisories.isEmpty {
                    Section {
                        ForEach(edited.advisories, id: \.self) { advisory in
                            Label(advisory.message, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    save(edited)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(VocabularyText.sanitize(text).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 420, height: 340)
    }
}

/// Carries the rendered glossary out through `fileExporter`.
private struct VocabularyGlossaryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }

    let text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        text = configuration.file.regularFileContents.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
