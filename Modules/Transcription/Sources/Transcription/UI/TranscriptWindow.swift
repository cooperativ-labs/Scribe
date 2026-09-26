import AppKit
import Speakers
import SwiftUI
import UniformTypeIdentifiers

/// A macOS review window. The host supplies files as jobs complete; this view does not own jobs.
public struct TranscriptWindow: View {
    @Bindable private var viewModel: TranscriptViewModel
    @State private var fileAwaitingDeletion: TranscriptReviewFile?
    @State private var fileAwaitingRetranscription: TranscriptReviewFile?
    @State private var fileFilter = ""

    @State private var isRenaming = false
    @State private var draftTitle = ""
    @State private var editingSegmentID: TranscriptSegment.ID?
    @State private var draftText = ""
    @State private var splitSegment: TranscriptSegment?
    @State private var newPersonScope: TranscriptSpeakerScope?
    @State private var isShowingShortcuts = false
    @State private var isShowingAgentSheet = false
    @State private var isDropTargeted = false
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isTitleFocused: Bool

    public init(viewModel: TranscriptViewModel) {
        self.viewModel = viewModel
    }

    /// While words are being typed the unmodified shortcuts (space, arrows)
    /// must reach the field, not the transport.
    private var isTyping: Bool { isSearchFocused || isTitleFocused || editingSegmentID != nil }

    private var toastStack: some View {
        TranscriptToastStack(center: viewModel.toastCenter) { action in
            switch action {
            case .undo: viewModel.undo()
            case .redo: viewModel.redo()
            case let .showInFinder(url): NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            ZStack(alignment: .bottomTrailing) {
                if let file = viewModel.selectedFile, let transcript = file.transcript {
                    transcriptDetail(file: file, transcript: transcript)
                } else if let file = viewModel.selectedFile {
                    ContentUnavailableView(file.jobState.displayName, systemImage: "waveform", description: Text(file.processingError ?? "A transcript will appear here when processing is complete."))
                } else {
                    ContentUnavailableView("No file selected", systemImage: "text.bubble")
                }
                if viewModel.selectedTranscript?.segments.isEmpty != false {
                    toastStack
                        .padding(.trailing, 16)
                        .padding(.bottom, 12)
                }
            }
        }
        // A floor only: the window, not the transcript's length, decides the size.
        .frame(minWidth: 820, minHeight: 600)
        .task { await viewModel.loadPeople() }
        .onChange(of: viewModel.selectedFileID) {
            isRenaming = false
            editingSegmentID = nil
            splitSegment = nil
            newPersonScope = nil
            Task { await viewModel.loadPeople() }
        }
        .onChange(of: viewModel.reviewLayout) {
            editingSegmentID = nil
            splitSegment = nil
            newPersonScope = nil
        }
        .sheet(
            isPresented: Binding(
                get: { viewModel.reprocessSession != nil },
                set: { if !$0 { viewModel.dismissReprocessSession() } }
            )
        ) {
            TranscriptReprocessSheet(viewModel: viewModel)
        }
    }

    // MARK: - Sidebar

    private var filteredFiles: [TranscriptReviewFile] {
        let query = TranscriptViewModel.normalizedSearch(fileFilter)
        guard !query.isEmpty else { return viewModel.files }
        return viewModel.files.filter {
            TranscriptViewModel.normalizedSearch($0.displayName).contains(query)
                || TranscriptViewModel.normalizedSearch($0.filename).contains(query)
        }
    }

    private var sidebar: some View {
        fileList
            .overlay { if isDropTargeted { dropHighlight } }
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                guard viewModel.canImportFiles else { return false }
                Task { await viewModel.importFiles(at: await Self.fileURLs(from: providers)) }
                return true
            }
            .animation(.snappy(duration: 0.15), value: isDropTargeted)
    }

    /// The drop shows what is about to happen: a file becomes a transcript in
    /// this list, not somewhere else.
    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color.accentColor, lineWidth: 2)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
            .overlay {
                Label("Drop to transcribe", systemImage: "waveform.badge.plus")
                    .font(.headline)
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(6)
            .allowsHitTesting(false)
    }

    /// The same import path as a drop, for people who would rather browse.
    private func chooseFilesToImport() {
        guard viewModel.canImportFiles else { return }
        let panel = NSOpenPanel()
        panel.title = "Add Recordings"
        panel.prompt = "Transcribe"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audiovisualContent]
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls.map(MediaSourceURL.resolvedFileURL(for:))
        Task { await viewModel.importFiles(at: urls) }
    }

    /// Resolves every dropped item that is a file URL. Anything else on the
    /// pasteboard is left out rather than failing the whole drop.
    private static func fileURLs(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let url: URL? = await withCheckedContinuation { continuation in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    if let data = item as? Data {
                        continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                    } else if let url = item as? URL {
                        continuation.resume(returning: url)
                    } else if let path = item as? String {
                        continuation.resume(returning: URL(fileURLWithPath: path))
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
            if let url { urls.append(MediaSourceURL.resolvedFileURL(for: url)) }
        }
        return urls
    }

    private var fileList: some View {
        List(selection: $viewModel.selectedFileID) {
            ForEach(filteredFiles) { file in
                TranscriptFileRow(file: file, canDelete: viewModel.canDelete(file)) {
                    fileAwaitingDeletion = file
                }
                .tag(file.id)
                .contextMenu {
                    Button("Open in Finder") {
                        openTranscriptFolder(for: file)
                    }
                    Button("Retranscribe…") { fileAwaitingRetranscription = file }
                        .disabled(!viewModel.canRetranscribe(file))
                    Divider()
                    Button("Rename…") { beginRenaming(file) }
                        .disabled(file.transcript == nil)
                    Button("Delete…", role: .destructive) { fileAwaitingDeletion = file }
                        .disabled(!viewModel.canDelete(file))
                }
            }
        }
        .searchable(text: $fileFilter, placement: .sidebar, prompt: "Filter transcripts")
        .navigationTitle("Transcripts")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: chooseFilesToImport) {
                    Label("Add Recordings", systemImage: "plus")
                }
                .disabled(!viewModel.canImportFiles)
                .help("Choose audio or video files to transcribe. You can also drop them on this list.")
            }
        }
        .frame(minWidth: 230)
        .confirmationDialog(
            "Delete \u{201C}\(fileAwaitingDeletion?.displayName ?? "")\u{201D}?",
            isPresented: Binding(
                get: { fileAwaitingDeletion != nil },
                set: { if !$0 { fileAwaitingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: fileAwaitingDeletion
        ) { file in
            Button("Delete", role: .destructive) { viewModel.delete(fileID: file.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The transcript and the copy of the recording kept beside it are removed. Exported files are left alone.")
        }
        .confirmationDialog(
            "Retranscribe \u{201C}\(fileAwaitingRetranscription?.displayName ?? "")\u{201D}?",
            isPresented: Binding(
                get: { fileAwaitingRetranscription != nil },
                set: { if !$0 { fileAwaitingRetranscription = nil } }
            ),
            titleVisibility: .visible,
            presenting: fileAwaitingRetranscription
        ) { file in
            Button("Retranscribe") {
                if viewModel.selectedFileID != file.id { viewModel.selectedFileID = file.id }
                Task { await viewModel.retranscribe(fileID: file.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Scribe will run recognition and speaker separation again with the models and settings currently in use. This transcript and its edits stay until the new run finishes.")
        }
    }

    /// Opens the meeting folder that holds the retained source and run history.
    private func openTranscriptFolder(for file: TranscriptReviewFile) {
        let folderURL = file.sourceSnapshotURL.deletingLastPathComponent()
        NSWorkspace.shared.open(folderURL)
    }

    private func beginRenaming(_ file: TranscriptReviewFile) {
        guard file.transcript != nil else { return }
        if viewModel.selectedFileID != file.id { viewModel.selectedFileID = file.id }
        draftTitle = file.displayName
        isRenaming = true
        isTitleFocused = true
    }

    private func commitRename() {
        guard isRenaming else { return }
        isRenaming = false
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let file = viewModel.selectedFile else { return }
        if title.isEmpty || title == file.filename {
            if file.transcript?.title != nil { viewModel.rename(to: nil) }
        } else if title != file.transcript?.title {
            viewModel.rename(to: title)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private func transcriptDetail(file: TranscriptReviewFile, transcript: CanonicalTranscript) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                titleHeader(file: file)
                if !viewModel.speakerRows.isEmpty {
                    TranscriptSpeakerChips(viewModel: viewModel)
                }
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 10)
            Divider()
            transcriptList(transcript: transcript)
        }
        .navigationTitle(file.displayName)
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom) {
            if !transcript.segments.isEmpty {
                TranscriptGlassEffectContainer(spacing: TranscriptDesign.Spacing.toastGap) {
                    TranscriptTransportBar(viewModel: viewModel, shortcutsEnabled: !isTyping)
                        .overlay(alignment: .topTrailing) {
                            toastStack
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.trailing, 16)
                                .alignmentGuide(.top) { $0[.bottom] + TranscriptDesign.Spacing.toastGap }
                        }
                }
            }
        }
        .sheet(item: $splitSegment) { segment in
            TranscriptSplitSheet(viewModel: viewModel, segment: segment)
        }
        .sheet(isPresented: $isShowingAgentSheet) {
            TranscriptAgentSheet(viewModel: viewModel, transcriptName: file.displayName) {
                isShowingAgentSheet = false
            }
        }
        .background { keyboardShortcuts }
    }

    @ViewBuilder
    private func titleHeader(file: TranscriptReviewFile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if isRenaming {
                    TextField("Transcript name", text: $draftTitle)
                        .textFieldStyle(.plain)
                        .font(.title2)
                        .focused($isTitleFocused)
                        .onAppear { isTitleFocused = true }
                        .onSubmit(commitRename)
                        .onExitCommand { isRenaming = false }
                        .onChange(of: isTitleFocused) { if !isTitleFocused { commitRename() } }
                    Button("Done", action: commitRename)
                        .controlSize(.small)
                } else {
                    TranscriptTitle(file: file) { beginRenaming(file) }
                }
            }
            TranscriptMetadataChips(viewModel: viewModel)
        }
    }

    @ViewBuilder
    private func transcriptList(transcript: CanonicalTranscript) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: viewModel.reviewLayout == .paragraphs ? 12 : 8) {
                    if transcript.segments.isEmpty {
                        ContentUnavailableView("No speech detected", systemImage: "waveform.slash", description: Text("This source completed without recognized speech."))
                            .frame(maxWidth: .infinity, minHeight: 240)
                    } else if viewModel.reviewLayout == .paragraphs {
                        if viewModel.visibleParagraphs.isEmpty {
                            ContentUnavailableView.search(text: viewModel.searchText)
                                .frame(maxWidth: .infinity, minHeight: 240)
                        }
                        ForEach(viewModel.visibleParagraphs) { paragraph in
                            paragraphRow(paragraph)
                                .id(paragraph.id)
                        }
                    } else if viewModel.visibleSegments.isEmpty {
                        ContentUnavailableView.search(text: viewModel.searchText)
                            .frame(maxWidth: .infinity, minHeight: 240)
                    } else {
                        ForEach(viewModel.visibleSegments) { segment in
                            segmentRow(segment, in: transcript)
                                .id(segment.id)
                        }
                    }
                }
                .padding()
            }
            .onChange(of: viewModel.playingRowID) { _, playing in
                guard viewModel.followsPlayback, let playing else { return }
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(playing, anchor: .center) }
            }
            .onChange(of: viewModel.selectedRowID) { _, selected in
                guard let selected, !viewModel.isPlaying else { return }
                proxy.scrollTo(selected)
            }
            .onChange(of: viewModel.reviewLayout) {
                if viewModel.followsPlayback, let playing = viewModel.playingRowID {
                    proxy.scrollTo(playing, anchor: .center)
                } else if let selected = viewModel.selectedRowID {
                    proxy.scrollTo(selected)
                }
            }
        }
    }

    @ViewBuilder
    private func paragraphRow(_ paragraph: TranscriptParagraph) -> some View {
        let primary = viewModel.primarySegment(for: paragraph)
        TranscriptParagraphRow(
            viewModel: viewModel,
            paragraph: paragraph,
            isSelected: paragraph.id == viewModel.selectedParagraphID,
            isPlaying: viewModel.isPlaying && paragraph.id == viewModel.playingParagraphID,
            onSelect: { viewModel.select(paragraph: paragraph) },
            onPlay: { viewModel.play(paragraph: paragraph) },
            onNewPerson: {
                if let primary { newPersonScope = .turn(segmentID: primary.id) }
            }
        )
        .popover(
            isPresented: Binding(
                get: { primary.map { newPersonScope == .turn(segmentID: $0.id) } ?? false },
                set: { if !$0, let primary, newPersonScope == .turn(segmentID: primary.id) { newPersonScope = nil } }
            ),
            arrowEdge: .bottom
        ) {
            if let primary {
                TranscriptNewPersonPopover(viewModel: viewModel, scope: .turn(segmentID: primary.id))
            }
        }
        .contextMenu {
            Button("Play from Here", systemImage: "play.fill") { viewModel.play(paragraph: paragraph) }
            if let primary {
                Menu("Speaker") {
                    TranscriptSpeakerMenuItems(viewModel: viewModel, scope: .turn(segmentID: primary.id)) {
                        newPersonScope = .turn(segmentID: primary.id)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func segmentRow(_ segment: TranscriptSegment, in transcript: CanonicalTranscript) -> some View {
        TranscriptSegmentRow(
            viewModel: viewModel,
            segment: segment,
            isSelected: segment.id == viewModel.selectedSegmentID,
            isPlaying: viewModel.isPlaying && segment.id == viewModel.playingSegmentID,
            isEditing: editingSegmentID == segment.id,
            draftText: $draftText,
            onSelect: { viewModel.select(segment: segment) },
            onPlay: { viewModel.play(segment: segment) },
            onBeginEditing: { beginEditing(segment) },
            onCommitEditing: commitEditing,
            onCancelEditing: { editingSegmentID = nil },
            onSplit: { splitSegment = segment },
            onNewPerson: { newPersonScope = .turn(segmentID: segment.id) }
        )
        .popover(
            isPresented: Binding(
                get: { newPersonScope == .turn(segmentID: segment.id) },
                set: { if !$0, newPersonScope == .turn(segmentID: segment.id) { newPersonScope = nil } }
            ),
            arrowEdge: .bottom
        ) {
            TranscriptNewPersonPopover(viewModel: viewModel, scope: .turn(segmentID: segment.id))
        }
        .contextMenu {
            Button("Play from Here", systemImage: "play.fill") { viewModel.play(segment: segment) }
            Menu("Speaker") {
                TranscriptSpeakerMenuItems(viewModel: viewModel, scope: .turn(segmentID: segment.id)) {
                    newPersonScope = .turn(segmentID: segment.id)
                }
            }
            Divider()
            Button("Edit Words…", systemImage: "pencil") { beginEditing(segment) }
            Button("Split…", systemImage: "scissors") { splitSegment = segment }
                .disabled(viewModel.splitTokens(for: segment).count < 2)
            Button("Combine with Previous", systemImage: "arrow.up.to.line") { viewModel.merge(segmentID: segment.id, withNext: false) }
                .disabled(viewModel.segment(before: segment.id) == nil)
            Button("Combine with Next", systemImage: "arrow.down.to.line") { viewModel.merge(segmentID: segment.id, withNext: true) }
                .disabled(viewModel.segment(after: segment.id) == nil)
        }
    }

    private func beginEditing(_ segment: TranscriptSegment) {
        viewModel.select(segment: segment)
        draftText = segment.text
        editingSegmentID = segment.id
    }

    private func commitEditing() {
        guard let editingSegmentID else { return }
        self.editingSegmentID = nil
        viewModel.replaceText(of: editingSegmentID, with: draftText)
    }

    // MARK: - Toolbar and shortcuts

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            Picker("View", selection: $viewModel.reviewLayout) {
                ForEach(TranscriptReviewLayout.allCases) { layout in
                    Text(layout.displayName).tag(layout)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .glassSurface(shape: .capsule)
            .help("Segments shows each canonical turn. Paragraphs groups consecutive same-speaker turns for reading without changing the saved transcript.")
            .accessibilityLabel("Transcript view")
            TranscriptToolbarSearch(viewModel: viewModel, isSearchFocused: $isSearchFocused)
            filterMenu
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu("Export", systemImage: "square.and.arrow.up") {
                Button("Export TXT") { exportTranscript(formats: [.plainText]) }
                Button("Export JSON") { exportTranscript(formats: [.json]) }
                Button("Export for Knowledgebase") { exportTranscript(formats: [.knowledgebase]) }
                Button("Copy for Knowledgebase") {
                    Task { await viewModel.copyKnowledgebaseToClipboard() }
                }
                Button("Export SRT") { exportTranscript(formats: [.subtitles]) }
                Divider()
                Button("Export All") { exportTranscript(formats: Set(TranscriptExportFormat.allCases)) }
            }
            .disabled(viewModel.selectedTranscript == nil)
            .help("Save a copy of this transcript as TXT, Scribe JSON, Knowledgebase JSON, or SRT, or copy Knowledgebase JSON to the clipboard. This does not change the recordings folder in Settings.")
            .transcriptToolbarGlassStyle()
            if viewModel.canSendToAgent {
                Button("Send to Agent", systemImage: "paperplane") { isShowingAgentSheet = true }
                    .disabled(viewModel.selectedTranscript == nil)
                    .help("Hand this transcript to a coding agent working in a folder you have connected. The session opens in Latch.")
                    .transcriptToolbarGlassStyle()
            }
            moreMenu
        }
    }

    private var filterMenu: some View {
        Menu {
            Text("\(viewModel.visibleSegments.count) of \(viewModel.chronologicalSegments.count) turns")
            Divider()
            ForEach(TranscriptReviewFilter.allCases) { filter in
                Button {
                    viewModel.reviewFilter = filter
                } label: {
                    if viewModel.reviewFilter == filter {
                        Label(filter.displayName, systemImage: "checkmark")
                    } else {
                        Text(filter.displayName)
                    }
                }
            }
            if let speakerFilterID = viewModel.speakerFilterID {
                Divider()
                let label = viewModel.recordingSpeakers.first { $0.id == speakerFilterID }?.labelSnapshot ?? speakerFilterID
                Text("Speaker: \(label)")
                Button("Clear speaker filter") { viewModel.speakerFilterID = nil }
            }
            Divider()
            Button("Next to Review") { viewModel.selectNextSegmentNeedingReview() }
                .disabled(viewModel.segmentsNeedingReviewCount == 0)
        } label: {
            // A toolbar menu keeps only its label's image, so the badge is
            // drawn into the image rather than overlaid as a view.
            if viewModel.isFiltering {
                Image(nsImage: TranscriptFilterBadgeImage.make(count: viewModel.visibleSegments.count))
            } else {
                Image(systemName: "line.3.horizontal.decrease")
            }
        }
        .accessibilityLabel("Filter turns")
        .accessibilityValue(viewModel.isFiltering ? "\(viewModel.visibleSegments.count) of \(viewModel.chronologicalSegments.count) turns" : "All turns")
        .help("Filter turns and jump to the next turn needing review (⌘J)")
        .transcriptToolbarGlassStyle()
    }

    private var moreMenu: some View {
        Menu("More", systemImage: "ellipsis.circle") {
            Button("Rename") {
                if let file = viewModel.selectedFile { beginRenaming(file) }
            }
            .disabled(viewModel.selectedTranscript == nil)
            Button("Refresh Labels") {
                Task { await viewModel.refreshLabelsFromLibrary() }
            }
            .disabled(viewModel.selectedTranscript == nil)
            Menu("Reprocess") {
                Button("Automatic speaker count") {
                    viewModel.presentReprocessConfirmation(speakerCount: .automatic)
                }
                Divider()
                Menu("Up to") {
                    ForEach(1...8, id: \.self) { count in
                        Button("Up to \(count) speaker\(count == 1 ? "" : "s")") {
                            viewModel.presentReprocessConfirmation(speakerCount: .upTo(count))
                        }
                    }
                }
                ForEach(1...8, id: \.self) { count in
                    Button("Exactly \(count) speaker\(count == 1 ? "" : "s")") {
                        viewModel.presentReprocessConfirmation(speakerCount: .known(count))
                    }
                }
                Divider()
                Text("Creates a new run and keeps this transcript’s edits. A maximum lets Scribe detect fewer speakers.")
            }
            .disabled(!viewModel.canReprocess)
            if viewModel.canOpenVocabularySettings {
                Button("Vocabulary") { viewModel.openVocabulary() }
            }
            Divider()
            Button("Keyboard Shortcuts") { isShowingShortcuts = true }
        }
        .popover(isPresented: $isShowingShortcuts, arrowEdge: .bottom) { TranscriptShortcutsHelp() }
        .help("More transcript actions")
        .transcriptToolbarGlassStyle()
    }

    /// Invisible buttons that carry the window's key equivalents. They stay in
    /// the hierarchy at zero size so the shortcuts fire; `hidden()` would
    /// remove them from key handling too.
    private var keyboardShortcuts: some View {
        Group {
            Button("Undo") { viewModel.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!viewModel.canUndo || isTyping)
            Button("Redo") { viewModel.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!viewModel.canRedo || isTyping)
            Button("Rename") {
                if let file = viewModel.selectedFile { beginRenaming(file) }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(viewModel.selectedTranscript == nil || isTyping)
            Button("Play or Pause") { viewModel.playSelectedOrToggle() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(isTyping)
            // Plain arrows stay with whichever list has focus, so the sidebar
            // can still walk transcripts; the turns take the option key.
            Button("Previous Turn") { viewModel.selectNeighbouringSegment(offset: -1) }
                .keyboardShortcut(.upArrow, modifiers: .option)
                .disabled(isTyping)
            Button("Next Turn") { viewModel.selectNeighbouringSegment(offset: 1) }
                .keyboardShortcut(.downArrow, modifiers: .option)
                .disabled(isTyping)
            Button("Back 5 Seconds") { viewModel.skip(byMilliseconds: -5_000) }
                .keyboardShortcut(.leftArrow, modifiers: .option)
            Button("Forward 5 Seconds") { viewModel.skip(byMilliseconds: 5_000) }
                .keyboardShortcut(.rightArrow, modifiers: .option)
            Button("Find") { isSearchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
            Button("Next Turn Needing Review") { viewModel.selectNextSegmentNeedingReview() }
                .keyboardShortcut("j", modifiers: .command)
            Button("Segments View") { viewModel.reviewLayout = .segments }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(isTyping)
            Button("Paragraphs View") { viewModel.reviewLayout = .paragraphs }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(isTyping)
            Button("Edit Words") {
                if let segment = selectedSegment { beginEditing(segment) }
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(isTyping || selectedSegment == nil || viewModel.reviewLayout != .segments)
            Button("Split") {
                if let segment = selectedSegment, viewModel.splitTokens(for: segment).count > 1 { splitSegment = segment }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(isTyping || selectedSegment == nil || viewModel.reviewLayout != .segments)
            Button("Combine with Previous") {
                if let segment = selectedSegment { viewModel.merge(segmentID: segment.id, withNext: false) }
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            .disabled(isTyping || selectedSegment == nil || viewModel.reviewLayout != .segments)
            Button("Combine with Next") {
                if let segment = selectedSegment { viewModel.merge(segmentID: segment.id, withNext: true) }
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            .disabled(isTyping || selectedSegment == nil || viewModel.reviewLayout != .segments)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private var selectedSegment: TranscriptSegment? {
        viewModel.chronologicalSegments.first { $0.id == viewModel.selectedSegmentID }
    }

    /// Opens a Save panel for the chosen formats. A cancelled panel writes nothing.
    private func exportTranscript(formats: Set<TranscriptExportFormat>) {
        guard let transcript = viewModel.selectedTranscript else { return }
        let suggestedBasename = FileTranscriptExportWriter.basename(for: transcript)
        let destinationURL: URL?
        if formats.count == 1, let format = formats.first {
            destinationURL = TranscriptExportSavePanel.pickFile(format: format, suggestedBasename: suggestedBasename)
        } else {
            destinationURL = TranscriptExportSavePanel.pickSharedName(suggestedBasename: suggestedBasename)
        }
        guard let destinationURL else { return }
        Task {
            let granted = destinationURL.startAccessingSecurityScopedResource()
            defer { if granted { destinationURL.stopAccessingSecurityScopedResource() } }
            // Labels are brought up to date as a new revision first, so the
            // exported files carry the names the library holds now.
            if formats.count == 1, let format = formats.first {
                await viewModel.exportRefreshingLabels(format, toFile: destinationURL)
            } else {
                let destination = TranscriptExportDestination.fromSaveURL(destinationURL)
                let directoryGranted = destination.directoryURL.startAccessingSecurityScopedResource()
                defer { if directoryGranted { destination.directoryURL.stopAccessingSecurityScopedResource() } }
                await viewModel.exportRefreshingLabels(
                    formats,
                    to: destination.directoryURL,
                    basename: destination.basename
                )
            }
        }
    }
}

// MARK: - Header

/// The transcript's name. Clicking the pencil, or double-clicking the name,
/// renames it; a renamed transcript keeps its source filename in the tooltip.
private struct TranscriptTitle: View {
    let file: TranscriptReviewFile
    let rename: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(file.displayName)
                .font(.title2)
                .lineLimit(1)
                .onTapGesture(count: 2, perform: rename)
                .help(file.transcript?.title == nil ? "Double-click to rename" : file.filename)
            Button(action: rename) {
                Image(systemName: "pencil")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(isHovering ? 1 : 0)
            .help("Rename this transcript (⇧⌘R)")
            .accessibilityLabel("Rename")
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.snappy(duration: 0.12), value: isHovering)
    }
}

/// One row of facts about the recording. Neutral chips describe it; tinted
/// chips need attention and act when clicked.
private struct TranscriptMetadataChips: View {
    @Bindable var viewModel: TranscriptViewModel
    @State private var isShowingWarnings = false

    var body: some View {
        HStack(spacing: TranscriptDesign.Spacing.chipSpacing) {
            if let length = viewModel.lengthText {
                TranscriptChip(length, systemImage: "clock")
                    .accessibilityLabel("Length \(length)")
            }
            if let speakers = viewModel.speakerCountText {
                TranscriptChip(speakers, systemImage: "person.2")
            }
            if let language = viewModel.languageName {
                TranscriptChip(language, systemImage: "globe")
                    .help(viewModel.languageHelp ?? "")
                    .accessibilityLabel("Language \(language)")
                    .accessibilityHint(viewModel.languageHelp ?? "")
            }
            if viewModel.segmentsNeedingReviewCount > 0 {
                Button(action: viewModel.showTurnsNeedingReview) {
                    TranscriptChip("\(viewModel.segmentsNeedingReviewCount) to review", tint: TranscriptDesign.reviewUncertain)
                }
                .buttonStyle(.plain)
                .help("Show only the turns that need review")
            }
            if let timingLimitation = viewModel.timingLimitation {
                TranscriptChip("\u{2248}")
                    .help(timingLimitation)
                    .accessibilityLabel("Estimated timing")
                    .accessibilityHint(timingLimitation)
            }
            let warnings = viewModel.processingMessages
            if !warnings.isEmpty {
                Button { isShowingWarnings.toggle() } label: {
                    TranscriptChip(
                        "\(warnings.count) warning\(warnings.count == 1 ? "" : "s")",
                        systemImage: "exclamationmark.triangle.fill",
                        tint: TranscriptDesign.reviewOverlap
                    )
                }
                .buttonStyle(.plain)
                .help("Show processing warnings")
                .popover(isPresented: $isShowingWarnings, arrowEdge: .bottom) {
                    TranscriptWarningsList(messages: warnings)
                }
            }
        }
    }
}

private struct TranscriptWarningsList: View {
    let messages: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Processing warnings").font(.headline)
            ForEach(messages, id: \.self) { message in
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(TranscriptWarningLabelStyle())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }
}

private struct TranscriptWarningLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.foregroundStyle(TranscriptDesign.reviewOverlap)
            configuration.title
        }
    }
}

// MARK: - Sidebar row

private struct TranscriptFileRow: View {
    let file: TranscriptReviewFile
    let canDelete: Bool
    let requestDeletion: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(file.displayName).lineLimit(1)
                if file.isInProgress {
                    Text("Transcribing")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                    ProgressView(value: file.jobState.progress ?? 0)
                        .progressViewStyle(.linear)
                        .controlSize(.mini)
                        .tint(.accentColor)
                        .accessibilityLabel("Transcription progress")
                } else {
                    Text(file.jobState.isFailure ? file.jobState.displayName : file.sidebarDetail())
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(file.jobState.isFailure ? .red : .secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            // Hidden until hover; the row's context menu still offers Delete.
            if isHovering, canDelete {
                Button(action: requestDeletion) {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Delete this transcript")
                .accessibilityLabel("Delete \(file.displayName)")
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}

// MARK: - Search and filters

/// The detail search field stays in the toolbar so ⌘F can focus the same field.
private struct TranscriptToolbarSearch: View {
    @Bindable var viewModel: TranscriptViewModel
    var isSearchFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find words or a speaker", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .focused(isSearchFocused)
                .onExitCommand { viewModel.searchText = ""; isSearchFocused.wrappedValue = false }
            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassSurface(shape: .capsule)
        .frame(width: 230)
        .accessibilityLabel("Find words or a speaker")
    }
}

/// The filter icon with the visible-turn count as a badge, in one image,
/// because `NSMenuToolbarItem` shows nothing of a label but its image and
/// draws that image as a tinted mask.
enum TranscriptFilterBadgeImage {
    static func make(count: Int) -> NSImage {
        // 18 pt square: the toolbar item crops anything larger than its icon box.
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { bounds in
            let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            if let symbol = NSImage(systemSymbolName: "line.3.horizontal.decrease", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) {
                let symbolRect = NSRect(x: 0, y: 0, width: symbol.size.width, height: symbol.size.height)
                symbol.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 1)
                NSColor.labelColor.set()
                symbolRect.fill(using: .sourceAtop)
            }
            let text = count > 99 ? "99+" : "\(count)"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 7.5, weight: .heavy),
                .foregroundColor: NSColor.white,
            ]
            let textSize = (text as NSString).size(withAttributes: attributes)
            let badgeHeight: CGFloat = 11
            let badgeWidth = min(bounds.width, max(badgeHeight, textSize.width + 5))
            let badge = NSRect(x: bounds.width - badgeWidth, y: bounds.height - badgeHeight, width: badgeWidth, height: badgeHeight)
            guard let context = NSGraphicsContext.current?.cgContext else { return true }
            // A knocked-out ring separates the badge from the funnel beneath it,
            // and the digits are cut out of the badge rather than painted on it:
            // the toolbar tints the whole image as a mask.
            context.saveGState()
            context.setBlendMode(.clear)
            NSBezierPath(roundedRect: badge.insetBy(dx: -1.25, dy: -1.25), xRadius: badgeHeight / 2 + 1.25, yRadius: badgeHeight / 2 + 1.25).fill()
            context.restoreGState()
            NSColor.labelColor.setFill()
            NSBezierPath(roundedRect: badge, xRadius: badgeHeight / 2, yRadius: badgeHeight / 2).fill()
            context.saveGState()
            context.setBlendMode(.clear)
            (text as NSString).draw(
                at: NSPoint(x: badge.midX - textSize.width / 2, y: badge.midY - textSize.height / 2),
                withAttributes: attributes
            )
            context.restoreGState()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Filter turns, \(count) shown"
        return image
    }
}

private struct TranscriptToolbarGlassStyle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .glassSurface(shape: .capsule)
        }
    }
}

private extension View {
    func transcriptToolbarGlassStyle() -> some View {
        modifier(TranscriptToolbarGlassStyle())
    }
}

// MARK: - Transport

/// Playback controls and a speaker timeline over the whole source.
///
/// Always present once a transcript has speech, so a person can scrub to any
/// point before pressing play rather than having to start from a turn.
private struct TranscriptTransportBar: View {
    @Bindable var viewModel: TranscriptViewModel
    let shortcutsEnabled: Bool

    private static let rates: [Float] = [0.75, 1, 1.25, 1.5, 2]

    var body: some View {
        let status = viewModel.playbackStatus
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                transportButton("gobackward.5", help: "Back 5 seconds (⌥←)") { viewModel.skip(byMilliseconds: -5_000) }
                Button {
                    if NSEvent.modifierFlags.contains(.option) {
                        viewModel.stopPlayback()
                    } else {
                        viewModel.playSelectedOrToggle()
                    }
                } label: {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        .frame(width: 32, height: 32)
                        .background(Color.primary, in: Circle())
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .help(viewModel.isPlaying ? "Pause (Space) · Option-click to stop" : "Play (Space) · Option-click to stop")
                .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")
                transportButton("goforward.5", help: "Forward 5 seconds (⌥→)") { viewModel.skip(byMilliseconds: 5_000) }
            }

            VStack(spacing: 3) {
                speakerTimeline
                HStack {
                    if viewModel.isPlaying, let status {
                        Text(status.speakerLabel)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    let duration = viewModel.sourceDurationMilliseconds
                    Text("\(TranscriptSpeakerTimeline.timeLabel(viewModel.playheadMilliseconds, includeHours: duration >= 3_600_000)) / \(TranscriptSpeakerTimeline.timeLabel(duration, includeHours: duration >= 3_600_000))")
                        .font(TranscriptDesign.TypeRole.timecode)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)

            Menu {
                ForEach(Self.rates, id: \.self) { rate in
                    Toggle(isOn: Binding(get: { viewModel.playbackRate == rate }, set: { if $0 { viewModel.setPlaybackRate(rate) } })) {
                        Text(Self.rateLabel(rate))
                    }
                }
            } label: {
                Text(Self.rateLabel(viewModel.playbackRate))
                    .font(.caption.monospacedDigit().weight(.semibold))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Playback speed")

            Toggle(isOn: $viewModel.followsPlayback) {
                Image(systemName: "text.line.first.and.arrowtriangle.forward")
            }
            .toggleStyle(.button)
            .buttonStyle(.plain)
            .foregroundStyle(viewModel.followsPlayback ? Color.accentColor : Color.secondary)
            .help(viewModel.followsPlayback ? "The list follows playback; click to stop following" : "Scroll the list to keep up with playback")
            .accessibilityLabel("Follow playback")

        }
        .padding(.horizontal, TranscriptDesign.Spacing.transportHorizontalPadding)
        .padding(.vertical, TranscriptDesign.Spacing.transportVerticalPadding)
        .glassSurface(shape: TranscriptDesign.Surface.transport, interactive: true)
        .contextMenu {
            Button("Stop") { viewModel.stopPlayback() }
                .disabled(status == nil)
        }
        .padding(.horizontal)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .animation(.snappy, value: viewModel.isPlaying)
    }

    private var speakerTimeline: some View {
        let duration = max(1, viewModel.sourceDurationMilliseconds)
        let spans = TranscriptSpeakerTimeline.spans(
            durationMs: viewModel.sourceDurationMilliseconds,
            segments: viewModel.chronologicalSegments
        )
        return GeometryReader { geometry in
            ZStack {
                Capsule()
                    .fill(Color.secondary.opacity(0.16))
                    .frame(height: 7)
                HStack(spacing: 0) {
                    ForEach(Array(spans.enumerated()), id: \.offset) { _, span in
                        Rectangle()
                            .fill(viewModel.color(forSpeakerID: span.speakerID) ?? .secondary.opacity(0.27))
                            .frame(width: geometry.size.width * CGFloat(span.durationMs) / CGFloat(duration))
                    }
                }
                .clipShape(Capsule())
                .frame(height: 7)
                Circle()
                    .fill(Color.primary)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                    .position(
                        x: 6 + (geometry.size.width - 12) * CGFloat(max(0, min(viewModel.playheadMilliseconds, duration))) / CGFloat(duration),
                        y: geometry.size.height / 2
                    )
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .allowsHitTesting(false)
            Slider(
                value: Binding(
                    get: { Double(viewModel.playheadMilliseconds) },
                    set: { viewModel.seek(toMilliseconds: Int($0.rounded())) }
                ),
                in: 0...Double(duration)
            )
            .controlSize(.small)
            .opacity(0.015)
            .accessibilityLabel("Play head")
        }
        .frame(height: 20)
    }

    private func transportButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle(.primary)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private static func rateLabel(_ rate: Float) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : String(format: "%.2g×", rate)
    }
}

// MARK: - Segment row

/// One turn, with a fixed start-time gutter and a readable text measure.
///
/// Click to select, double-click or use the play icon to listen. The speaker
/// is a dropdown, so correcting who spoke is one click on the name.
private struct TranscriptSegmentRow: View {
    let viewModel: TranscriptViewModel
    let segment: TranscriptSegment
    let isSelected: Bool
    let isPlaying: Bool
    let isEditing: Bool
    @Binding var draftText: String
    let onSelect: () -> Void
    let onPlay: () -> Void
    let onBeginEditing: () -> Void
    let onCommitEditing: () -> Void
    let onCancelEditing: () -> Void
    let onSplit: () -> Void
    let onNewPerson: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TranscriptRowStartTime(milliseconds: segment.startMs, viewModel: viewModel)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    TranscriptSpeakerMenu(viewModel: viewModel, scope: .turn(segmentID: segment.id), onNewPerson: onNewPerson) {
                        HStack(spacing: 6) {
                            TranscriptSpeakerDot(viewModel.speakerSwatch(forSpeakerID: segment.effectiveSpeakerID))
                            Text(displayedSpeakerName)
                                .font(TranscriptDesign.TypeRole.speakerName)
                                .foregroundStyle(viewModel.color(forSpeakerID: segment.effectiveSpeakerID) ?? .secondary)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .help(segment.hasInferredSpeaker
                        ? "Inferred from diarization timing. Original speaker is still unknown; a manual label takes precedence."
                        : "Change who is speaking in this turn")
                    if let flag = reviewFlag {
                        TranscriptFlagDot(flag)
                            .help(reviewDescription)
                    }
                    Spacer(minLength: 0)
                }
                if isEditing {
                    TextEditor(text: $draftText)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 60)
                        .padding(4)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(0.6)))
                    HStack {
                        Text("Word timings for this turn are dropped when its words change.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel", action: onCancelEditing)
                            .keyboardShortcut(.cancelAction)
                        Button("Save", action: onCommitEditing)
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .help("Save (⌘⏎)")
                    }
                } else {
                    Text(TranscriptSearchHighlighter.highlight(segment.text, query: viewModel.searchText))
                        .font(TranscriptDesign.TypeRole.turn)
                        .lineSpacing(TranscriptDesign.TypeRole.turnLineSpacing)
                        .frame(maxWidth: turnMeasure, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, TranscriptDesign.Spacing.rowHorizontalPadding)
        .padding(.vertical, TranscriptDesign.Spacing.rowVerticalPadding)
        .background(rowBackground(isPlaying: isPlaying, isSelected: isSelected), in: TranscriptDesign.Surface.row.anyShape)
        .overlay(TranscriptDesign.Surface.row.anyShape.stroke(isSelected && !isPlaying ? Color.primary.opacity(TranscriptDesign.Tint.hairline) : .clear, lineWidth: 0.5))
        .overlay(alignment: .leading) { playingRail(isPlaying: isPlaying) }
        .overlay(alignment: .topTrailing) {
            if isHovering && !isEditing {
                HStack(spacing: TranscriptDesign.Spacing.hoverPillSpacing) {
                    rowTool("pencil", help: "Edit words (⌘E)", action: onBeginEditing)
                    rowTool("scissors", help: "Split this turn (⇧⌘S)", action: onSplit)
                        .disabled(viewModel.splitTokens(for: segment).count < 2)
                    rowTool("arrow.up.to.line", help: "Combine with previous (⌥⌘↑)") { viewModel.merge(segmentID: segment.id, withNext: false) }
                        .disabled(viewModel.segment(before: segment.id) == nil)
                    rowTool("arrow.down.to.line", help: "Combine with next (⌥⌘↓)") { viewModel.merge(segmentID: segment.id, withNext: true) }
                        .disabled(viewModel.segment(after: segment.id) == nil)
                }
                .padding(TranscriptDesign.Spacing.hoverPillPadding)
                .glassSurface(shape: TranscriptDesign.Surface.hoverPill, interactive: true)
                .padding(4)
                .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onPlay)
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(displayedSpeakerName), \(segment.text)\(reviewDescription.isEmpty ? "" : ", \(reviewDescription)")")
        .accessibilityHint("Double-click to play from \(TranscriptTimecode.string(fromMilliseconds: segment.startMs)) through the turns that follow")
    }

    private var reviewDescription: String { TranscriptRowReview.description(for: segment) }

    private var displayedSpeakerName: String {
        segment.hasInferredSpeaker ? (segment.speakerInference?.speakerLabel ?? segment.speakerLabel) : segment.speakerLabel
    }

    private var reviewFlag: TranscriptDesign.ReviewFlag? { TranscriptRowReview.flag(for: segment) }

    private var turnMeasure: CGFloat { CGFloat(TranscriptDesign.Spacing.turnMeasureCharacters) * TranscriptDesign.TypeRole.turnFontSize * 0.52 }

    private func playingRail(isPlaying: Bool) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(isPlaying ? Color.accentColor : .clear)
            .frame(width: TranscriptDesign.Spacing.rowPlayingRailWidth)
    }

    private func rowTool(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// One reading paragraph: consecutive same-speaker canonical turns grouped
/// without rewriting the saved transcript. Precise split, merge, and word
/// edits stay in Segments view.
private struct TranscriptParagraphRow: View {
    let viewModel: TranscriptViewModel
    let paragraph: TranscriptParagraph
    let isSelected: Bool
    let isPlaying: Bool
    let onSelect: () -> Void
    let onPlay: () -> Void
    let onNewPerson: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TranscriptRowStartTime(milliseconds: paragraph.startMs, viewModel: viewModel)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    if let primary = viewModel.primarySegment(for: paragraph) {
                        TranscriptSpeakerMenu(viewModel: viewModel, scope: .turn(segmentID: primary.id), onNewPerson: onNewPerson) {
                            speakerName(for: paragraph)
                        }
                        .menuStyle(.borderlessButton)
                        .help("Change who is speaking in the selected source turn")
                    } else {
                        speakerName(for: paragraph)
                    }
                    if let flag = TranscriptRowReview.flag(for: paragraph) {
                        TranscriptFlagDot(flag)
                            .help(reviewDescription)
                    }
                    Spacer(minLength: 0)
                }
                Text(TranscriptSearchHighlighter.highlight(paragraph.text, query: viewModel.searchText))
                    .font(TranscriptDesign.TypeRole.turn)
                    .lineSpacing(TranscriptDesign.TypeRole.turnLineSpacing)
                    .frame(maxWidth: turnMeasure, alignment: .leading)
                    .textSelection(.enabled)
                ForEach(paragraph.asides) { aside in
                    interjection(aside)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, TranscriptDesign.Spacing.rowHorizontalPadding)
        .padding(.vertical, TranscriptDesign.Spacing.rowVerticalPadding)
        .background(rowBackground(isPlaying: isPlaying, isSelected: isSelected), in: TranscriptDesign.Surface.row.anyShape)
        .overlay(TranscriptDesign.Surface.row.anyShape.stroke(isSelected && !isPlaying ? Color.primary.opacity(TranscriptDesign.Tint.hairline) : .clear, lineWidth: 0.5))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(isPlaying ? Color.accentColor : .clear)
                .frame(width: TranscriptDesign.Spacing.rowPlayingRailWidth)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onPlay)
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(paragraph.speakerLabel), \(paragraph.text)\(reviewDescription.isEmpty ? "" : ", \(reviewDescription)")")
        .accessibilityHint("Double-click to play from \(TranscriptTimecode.string(fromMilliseconds: paragraph.startMs)). Grouped from \(paragraph.sourceSegmentCount) saved turn\(paragraph.sourceSegmentCount == 1 ? "" : "s").")
    }

    private var reviewDescription: String { TranscriptRowReview.description(for: paragraph) }
    private var turnMeasure: CGFloat { CGFloat(TranscriptDesign.Spacing.turnMeasureCharacters) * TranscriptDesign.TypeRole.turnFontSize * 0.52 }

    private func speakerName(for paragraph: TranscriptParagraph) -> some View {
        HStack(spacing: 6) {
            TranscriptSpeakerDot(viewModel.speakerSwatch(forSpeakerID: paragraph.speakerID))
            Text(TranscriptSearchHighlighter.highlight(paragraph.speakerLabel, query: viewModel.searchText))
                .font(TranscriptDesign.TypeRole.speakerName)
                .foregroundStyle(viewModel.color(forSpeakerID: paragraph.speakerID) ?? .secondary)
        }
    }

    private func interjection(_ aside: TranscriptParagraph) -> some View {
        HStack(alignment: .top, spacing: 10) {
            TranscriptRowStartTime(milliseconds: aside.startMs, viewModel: viewModel)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    speakerName(for: aside)
                    if let flag = TranscriptRowReview.flag(for: aside) {
                        TranscriptFlagDot(flag).help(TranscriptRowReview.description(for: aside))
                    }
                }
                Text(TranscriptSearchHighlighter.highlight(aside.text, query: viewModel.searchText))
                    .font(TranscriptDesign.TypeRole.turn)
                    .lineSpacing(TranscriptDesign.TypeRole.turnLineSpacing)
                    .frame(maxWidth: turnMeasure, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(.leading, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(aside.sourceSegmentIDs.contains(viewModel.selectedSegmentID ?? "") ? Color.accentColor.opacity(0.08) : .clear)
        .overlay(alignment: .leading) {
            Rectangle().fill(viewModel.color(forSpeakerID: aside.speakerID) ?? Color.secondary.opacity(0.3)).frame(width: 2)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if let source = viewModel.primarySegment(for: aside) {
                viewModel.select(segment: source)
                viewModel.reviewLayout = .segments
            }
        }
        .onTapGesture {
            if let source = viewModel.primarySegment(for: aside) { viewModel.select(segment: source) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Interjection by \(aside.speakerLabel): \(aside.text)\(TranscriptRowReview.description(for: aside).isEmpty ? "" : ", \(TranscriptRowReview.description(for: aside))")")
        .accessibilityHint("Double-click to show the source turn")
    }
}

/// The quiet start time in a turn's leading column: minutes and seconds, with
/// hours only when the recording runs past an hour, so the column never wraps.
/// The full millisecond timecode stays one hover away.
private struct TranscriptRowStartTime: View {
    let milliseconds: Int
    let viewModel: TranscriptViewModel

    var body: some View {
        Text(TranscriptSpeakerTimeline.timeLabel(milliseconds, includeHours: viewModel.sourceDurationMilliseconds >= 3_600_000))
            .font(TranscriptDesign.TypeRole.timecode)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .frame(width: TranscriptDesign.Spacing.rowTimecodeColumnWidth, alignment: .leading)
            .help(TranscriptTimecode.string(fromMilliseconds: milliseconds))
            .accessibilityLabel("Starts at \(TranscriptTimecode.string(fromMilliseconds: milliseconds))")
    }
}

private func rowBackground(isPlaying: Bool, isSelected: Bool) -> Color {
    if isPlaying { return Color.accentColor.opacity(TranscriptDesign.Tint.playingRow) }
    if isSelected { return Color.primary.opacity(TranscriptDesign.Tint.selectedRow) }
    return .clear
}

/// Keeps compact flags descriptive for pointer and VoiceOver users.
enum TranscriptRowReview {
    static func description(for segment: TranscriptSegment) -> String {
        var reasons: [String] = []
        if segment.speakerID == nil && !segment.hasInferredSpeaker { reasons.append("Unknown speaker") }
        if segment.hasLowSpeakerConfidence, let confidence = segment.speakerConfidence {
            reasons.append("Uncertain speaker (\(Int((confidence * 100).rounded()))%)")
        }
        if segment.hasInferredSpeaker { reasons.append("Inferred attribution") }
        if segment.overlap { reasons.append("Overlapping speech") }
        if segment.timingQuality == .segmentOnly { reasons.append("Estimated timing") }
        return reasons.joined(separator: ", ")
    }

    static func flag(for segment: TranscriptSegment) -> TranscriptDesign.ReviewFlag? {
        if segment.overlap { return .overlap }
        if segment.speakerID == nil || segment.hasLowSpeakerConfidence || segment.hasInferredSpeaker || segment.timingQuality == .segmentOnly { return .uncertain }
        return nil
    }

    static func description(for paragraph: TranscriptParagraph) -> String {
        var reasons: [String] = []
        if paragraph.speakerID == nil { reasons.append("Unknown speaker") }
        if paragraph.hasLowSpeakerConfidence, let confidence = paragraph.speakerConfidence {
            reasons.append("Uncertain speaker (\(Int((confidence * 100).rounded()))%)")
        }
        if paragraph.containsInferredAttribution { reasons.append("Inferred attribution") }
        if paragraph.overlap { reasons.append("Overlapping speech") }
        if paragraph.timingQuality == .segmentOnly { reasons.append("Estimated timing") }
        if paragraph.sourceSegmentCount > 1 { reasons.append("\(paragraph.sourceSegmentCount) segments") }
        return reasons.joined(separator: ", ")
    }

    static func flag(for paragraph: TranscriptParagraph) -> TranscriptDesign.ReviewFlag? {
        if paragraph.overlap { return .overlap }
        if paragraph.speakerID == nil || paragraph.hasLowSpeakerConfidence || paragraph.containsInferredAttribution || paragraph.timingQuality == .segmentOnly || paragraph.sourceSegmentCount > 1 { return .uncertain }
        return nil
    }
}

/// Marks every occurrence of the search words in a turn's text.
enum TranscriptSearchHighlighter {
    static func highlight(_ text: String, query: String) -> AttributedString {
        var attributed = AttributedString(text)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return attributed }
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
            if let lower = AttributedString.Index(range.lowerBound, within: attributed),
               let upper = AttributedString.Index(range.upperBound, within: attributed) {
                attributed[lower..<upper].backgroundColor = Color.yellow.opacity(0.45)
                attributed[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
            }
            guard range.upperBound < text.endIndex else { break }
            searchRange = range.upperBound..<text.endIndex
        }
        return attributed
    }
}

// MARK: - Help and results

private struct TranscriptShortcutsHelp: View {
    private let rows: [(String, String)] = [
        ("Space", "Play the selected turn, or pause"),
        ("⌥↑ / ⌥↓", "Select the previous or next turn"),
        ("⌥← / ⌥→", "Back or forward five seconds"),
        ("⌘1 / ⌘2", "Segments or Paragraphs view"),
        ("⌘F", "Find words or a speaker"),
        ("⌘J", "Select the next turn needing review"),
        ("⌘E", "Edit the words of the selected turn"),
        ("⇧⌘S", "Split the selected turn"),
        ("⌥⌘↑ / ⌥⌘↓", "Combine the selected turn with its neighbour"),
        ("⇧⌘R", "Rename the transcript"),
        ("⌘Z / ⇧⌘Z", "Undo or redo an edit"),
    ]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            ForEach(rows, id: \.0) { key, meaning in
                GridRow {
                    Text(key).font(.body.monospaced()).foregroundStyle(.secondary)
                    Text(meaning)
                }
            }
        }
        .padding(14)
    }
}

private struct TranscriptToastStack: View {
    let center: TranscriptToastCenter
    let perform: (TranscriptToast.Action) -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: TranscriptDesign.Spacing.toastSpacing) {
            ForEach(center.visible) { toast in
                HStack(spacing: 8) {
                    if toast.kind == .progress {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: toast.kind == .failure ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(toast.kind == .failure ? .red : .primary)
                    }
                    Text(toast.text).lineLimit(1)
                    if let action = toast.action {
                        Button(action == .undo ? "Undo" : action == .redo ? "Redo" : "Show in Finder") {
                            perform(action)
                            center.dismiss(toast.id)
                        }
                        .buttonStyle(.borderless)
                    }
                    if toast.kind == .failure {
                        Button { center.dismiss(toast.id) } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Dismiss notification")
                    }
                }
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .glassSurface(shape: TranscriptDesign.Surface.toast)
                .onHover { center.setHovered($0, for: toast.id) }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(toast.text)
                .onAppear {
                    NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                                         userInfo: [.announcement: toast.text])
                }
                .onChange(of: toast.text) { _, newText in
                    NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                                         userInfo: [.announcement: newText])
                }
            }
        }
        .animation(.snappy, value: center.visible)
    }
}
