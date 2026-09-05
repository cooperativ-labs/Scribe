import Speakers
import SwiftUI

/// A macOS review window. The host supplies files as jobs complete; this view does not own jobs.
public struct TranscriptWindow: View {
    @Bindable private var viewModel: TranscriptViewModel
    @State private var isChoosingExportDirectory = false
    @State private var pendingFormats: Set<TranscriptExportFormat> = []
    @State private var fileAwaitingDeletion: TranscriptReviewFile?
    @State private var fileFilter = ""

    @State private var isRenaming = false
    @State private var draftTitle = ""
    @State private var editingSegmentID: TranscriptSegment.ID?
    @State private var draftText = ""
    @State private var splitSegment: TranscriptSegment?
    @State private var newPersonScope: TranscriptSpeakerScope?
    @State private var isShowingShortcuts = false
    @State private var isSpeakersExpanded = true
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isTitleFocused: Bool

    public init(viewModel: TranscriptViewModel) {
        self.viewModel = viewModel
    }

    /// While words are being typed the unmodified shortcuts (space, arrows)
    /// must reach the field, not the transport.
    private var isTyping: Bool { isSearchFocused || isTitleFocused || editingSegmentID != nil }

    public var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if let file = viewModel.selectedFile, let transcript = file.transcript {
                transcriptDetail(file: file, transcript: transcript)
            } else if let file = viewModel.selectedFile {
                ContentUnavailableView(file.jobState.displayName, systemImage: "waveform", description: Text(file.processingError ?? "A transcript will appear here when processing is complete."))
            } else {
                ContentUnavailableView("No file selected", systemImage: "text.bubble")
            }
        }
        .fileImporter(
            isPresented: $isChoosingExportDirectory,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let directory = urls.first else { return }
            let formats = pendingFormats
            Task {
                let granted = directory.startAccessingSecurityScopedResource()
                defer { if granted { directory.stopAccessingSecurityScopedResource() } }
                // Labels are brought up to date as a new revision first, so the
                // exported files carry the names the library holds now.
                await viewModel.exportRefreshingLabels(formats, to: directory)
            }
        }
        .task { await viewModel.loadPeople() }
        .onChange(of: viewModel.selectedFileID) {
            isRenaming = false
            editingSegmentID = nil
            splitSegment = nil
            newPersonScope = nil
            Task { await viewModel.loadPeople() }
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
        List(selection: $viewModel.selectedFileID) {
            ForEach(filteredFiles) { file in
                TranscriptFileRow(file: file, canDelete: viewModel.canDelete(file)) {
                    fileAwaitingDeletion = file
                }
                .tag(file.id)
                .contextMenu {
                    Button("Rename…") { beginRenaming(file) }
                        .disabled(file.transcript == nil)
                    Button("Delete…", role: .destructive) { fileAwaitingDeletion = file }
                        .disabled(!viewModel.canDelete(file))
                }
            }
        }
        .searchable(text: $fileFilter, placement: .sidebar, prompt: "Filter transcripts")
        .navigationTitle("Transcripts")
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
                TranscriptSuggestionBanner(viewModel: viewModel)
                if !viewModel.speakerRows.isEmpty {
                    DisclosureGroup(isExpanded: $isSpeakersExpanded) {
                        TranscriptSpeakersInspector(viewModel: viewModel)
                            .padding(.top, 4)
                    } label: {
                        Text("Speakers in this recording").font(.headline)
                    }
                }
                if let message = viewModel.speakerActionMessage {
                    Label(message.text, systemImage: message.isFailure ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(message.isFailure ? .red : .green)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 10)
            Divider()
            TranscriptFilterBar(viewModel: viewModel, isSearchFocused: $isSearchFocused)
            Divider()
            segmentList(transcript: transcript)
        }
        .navigationTitle(file.displayName)
        .navigationSubtitle(file.transcript?.title == nil ? "" : file.filename)
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                TranscriptExportResults(outcomes: viewModel.exportOutcomes)
                if !transcript.segments.isEmpty {
                    TranscriptTransportBar(viewModel: viewModel, shortcutsEnabled: !isTyping)
                }
            }
        }
        .sheet(item: $splitSegment) { segment in
            TranscriptSplitSheet(viewModel: viewModel, segment: segment)
        }
        .background { keyboardShortcuts }
        .animation(.snappy, value: viewModel.speakerActionMessage)
    }

    @ViewBuilder
    private func titleHeader(file: TranscriptReviewFile) -> some View {
        VStack(alignment: .leading, spacing: 5) {
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
                    Text(file.displayName)
                        .font(.title2)
                        .lineLimit(1)
                        .onTapGesture(count: 2) { beginRenaming(file) }
                        .help("Double-click to rename")
                    Button {
                        beginRenaming(file)
                    } label: {
                        Image(systemName: "pencil")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Rename this transcript")
                    .accessibilityLabel("Rename")
                }
            }
            HStack(spacing: 14) {
                if let summary = viewModel.reviewSummary {
                    Label(summary, systemImage: "text.quote")
                }
                if let language = viewModel.languageDescription {
                    Label(language, systemImage: "globe")
                }
                if viewModel.segmentsNeedingReviewCount > 0 {
                    Label("\(viewModel.segmentsNeedingReviewCount) to review", systemImage: "eye.trianglebadge.exclamationmark")
                        .foregroundStyle(.orange)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            if let timingLimitation = viewModel.timingLimitation {
                Label(timingLimitation, systemImage: "clock.badge.exclamationmark").foregroundStyle(.orange).font(.callout)
            }
            ForEach(viewModel.processingMessages, id: \.self) { message in
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
            }
        }
    }

    @ViewBuilder
    private func segmentList(transcript: CanonicalTranscript) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if transcript.segments.isEmpty {
                        ContentUnavailableView("No speech detected", systemImage: "waveform.slash", description: Text("This source completed without recognized speech."))
                            .frame(maxWidth: .infinity, minHeight: 240)
                    } else if viewModel.visibleSegments.isEmpty {
                        ContentUnavailableView.search(text: viewModel.searchText)
                            .frame(maxWidth: .infinity, minHeight: 240)
                    }
                    ForEach(viewModel.visibleSegments) { segment in
                        segmentRow(segment, in: transcript)
                            .id(segment.id)
                    }
                }
                .padding()
            }
            .onChange(of: viewModel.playingSegmentID) { _, playing in
                guard viewModel.followsPlayback, let playing else { return }
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(playing, anchor: .center) }
            }
            .onChange(of: viewModel.selectedSegmentID) { _, selected in
                guard let selected, !viewModel.isPlaying else { return }
                proxy.scrollTo(selected)
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
        ToolbarItemGroup(placement: .navigation) {
            Button("Undo", systemImage: "arrow.uturn.backward") { viewModel.undo() }
                .disabled(!viewModel.canUndo || isTyping)
                .keyboardShortcut("z", modifiers: .command)
                .help("Undo the last edit (⌘Z)")
            Button("Redo", systemImage: "arrow.uturn.forward") { viewModel.redo() }
                .disabled(!viewModel.canRedo || isTyping)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .help("Redo the last undone edit (⇧⌘Z)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Rename", systemImage: "pencil.line") {
                if let file = viewModel.selectedFile { beginRenaming(file) }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .help("Rename this transcript (⇧⌘R)")
            Button("Refresh Labels", systemImage: "arrow.triangle.2.circlepath") {
                Task { await viewModel.refreshLabelsFromLibrary() }
            }
            .help("Applies current speaker-library names to this transcript as a new revision.")
            Menu("Export", systemImage: "square.and.arrow.up") {
                Button("Export TXT") { chooseDestination(for: [.plainText]) }
                Button("Export JSON") { chooseDestination(for: [.json]) }
                Button("Export SRT") { chooseDestination(for: [.subtitles]) }
                Divider()
                Button("Export All") { chooseDestination(for: Set(TranscriptExportFormat.allCases)) }
            }
            .disabled(viewModel.selectedTranscript == nil)
            Button("Keyboard Shortcuts", systemImage: "keyboard") { isShowingShortcuts.toggle() }
                .popover(isPresented: $isShowingShortcuts, arrowEdge: .bottom) { TranscriptShortcutsHelp() }
                .help("Keyboard shortcuts")
        }
    }

    /// Invisible buttons that carry the window's key equivalents. They stay in
    /// the hierarchy at zero size so the shortcuts fire; `hidden()` would
    /// remove them from key handling too.
    private var keyboardShortcuts: some View {
        Group {
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
            Button("Edit Words") {
                if let segment = selectedSegment { beginEditing(segment) }
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(isTyping || selectedSegment == nil)
            Button("Split") {
                if let segment = selectedSegment, viewModel.splitTokens(for: segment).count > 1 { splitSegment = segment }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(isTyping || selectedSegment == nil)
            Button("Combine with Previous") {
                if let segment = selectedSegment { viewModel.merge(segmentID: segment.id, withNext: false) }
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            .disabled(isTyping || selectedSegment == nil)
            Button("Combine with Next") {
                if let segment = selectedSegment { viewModel.merge(segmentID: segment.id, withNext: true) }
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            .disabled(isTyping || selectedSegment == nil)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private var selectedSegment: TranscriptSegment? {
        viewModel.chronologicalSegments.first { $0.id == viewModel.selectedSegmentID }
    }

    private func chooseDestination(for formats: Set<TranscriptExportFormat>) {
        pendingFormats = formats
        isChoosingExportDirectory = true
    }
}

// MARK: - Sidebar row

private struct TranscriptFileRow: View {
    let file: TranscriptReviewFile
    let canDelete: Bool
    let requestDeletion: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(file.displayName).lineLimit(1)
                if file.transcript?.title != nil {
                    Text(file.filename)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if let progress = file.jobState.progress {
                    ProgressView(value: progress)
                }
                Text(stateLine)
                    .font(.caption)
                    .foregroundStyle(file.jobState.isFailure ? .red : .secondary)
            }
            Spacer(minLength: 0)
            Button(action: requestDeletion) {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(!canDelete)
            .help(canDelete ? "Delete this transcript" : "This transcript is still being processed.")
            .accessibilityLabel("Delete \(file.displayName)")
        }
    }

    private var stateLine: String {
        guard let transcript = file.transcript, !transcript.segments.isEmpty else { return file.jobState.displayName }
        let length = TranscriptTimecode.string(fromMilliseconds: transcript.source.durationMs)
            .replacingOccurrences(of: #"\.\d{3}$"#, with: "", options: .regularExpression)
        return "\(file.jobState.displayName) · \(length)"
    }
}

// MARK: - Search and filters

/// Search, the review filter, and the speaker filter, with a running count
/// of what the list is showing.
private struct TranscriptFilterBar: View {
    @Bindable var viewModel: TranscriptViewModel
    var isSearchFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
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
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
            .frame(maxWidth: 360)

            Picker("Show", selection: $viewModel.reviewFilter) {
                ForEach(TranscriptReviewFilter.allCases) { filter in
                    Text(filter.displayName).tag(filter)
                }
            }
            .labelsHidden()
            .fixedSize()

            if let speakerFilterID = viewModel.speakerFilterID {
                let label = viewModel.recordingSpeakers.first { $0.id == speakerFilterID }?.labelSnapshot ?? speakerFilterID
                Button {
                    viewModel.speakerFilterID = nil
                } label: {
                    Label("Only \(label)", systemImage: "xmark")
                        .labelStyle(.titleAndIcon)
                        .font(.callout)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Show every speaker")
            }

            Spacer()

            Text(countDescription)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Button("Next to Review", systemImage: "eye.trianglebadge.exclamationmark") {
                viewModel.selectNextSegmentNeedingReview()
            }
            .labelStyle(.iconOnly)
            .disabled(viewModel.segmentsNeedingReviewCount == 0)
            .help("Select the next turn with an unknown or uncertain speaker, overlap, or estimated timing (⌘J)")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var countDescription: String {
        let total = viewModel.chronologicalSegments.count
        let visible = viewModel.visibleSegments.count
        return viewModel.isFiltering ? "\(visible) of \(total) turns" : "\(total) turns"
    }
}

// MARK: - Transport

/// The playback controls at the foot of the transcript: transport, a readout
/// of who is speaking, a scrubber over the whole source, speed, and whether
/// the list follows the audio.
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
                    viewModel.playSelectedOrToggle()
                } label: {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .foregroundStyle(.primary)
                        .frame(width: 26, height: 26)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .help(viewModel.isPlaying ? "Pause (Space)" : "Play (Space)")
                .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")
                transportButton("goforward.5", help: "Forward 5 seconds (⌥→)") { viewModel.skip(byMilliseconds: 5_000) }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(status?.speakerLabel ?? "Ready")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(status?.timestamp ?? "Select a turn, or drag the play head")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 200, alignment: .leading)

            VStack(spacing: 1) {
                Slider(
                    value: Binding(
                        get: { Double(viewModel.playheadMilliseconds) },
                        set: { viewModel.seek(toMilliseconds: Int($0.rounded())) }
                    ),
                    in: 0...Double(max(1, viewModel.sourceDurationMilliseconds))
                )
                .controlSize(.small)
                .accessibilityLabel("Play head")
                HStack {
                    Text(TranscriptTimecode.string(fromMilliseconds: viewModel.playheadMilliseconds))
                    Spacer()
                    Text(TranscriptTimecode.string(fromMilliseconds: viewModel.sourceDurationMilliseconds))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
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

            transportButton("stop.fill", help: "Stop") { viewModel.stopPlayback() }
                .disabled(status == nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .modifier(TranscriptGlassPanel())
        .padding(.horizontal)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .animation(.snappy, value: viewModel.isPlaying)
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

/// Liquid glass on systems that draw it, a material panel everywhere else.
private struct TranscriptGlassPanel: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        }
    }
}

// MARK: - Segment row

/// One turn: its timing and speaker on the first line, the words beneath.
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Button(action: onPlay) {
                    Image(systemName: isPlaying ? "speaker.wave.2.fill" : "play.circle")
                        .font(.callout)
                        .foregroundStyle(isPlaying ? Color.accentColor : .secondary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .help("Play from this turn")
                .accessibilityLabel("Play from \(TranscriptTimecode.string(fromMilliseconds: segment.startMs))")

                Text("\(TranscriptTimecode.string(fromMilliseconds: segment.startMs)) – \(TranscriptTimecode.string(fromMilliseconds: segment.endMs))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                TranscriptSpeakerMenu(viewModel: viewModel, scope: .turn(segmentID: segment.id), onNewPerson: onNewPerson) {
                    if segment.speakerID == nil {
                        Label("Unknown speaker", systemImage: "person.crop.circle.badge.questionmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    } else {
                        Label(segment.speakerLabel, systemImage: "person.crop.circle")
                            .font(.caption.weight(.semibold))
                    }
                }
                .menuStyle(.borderlessButton)
                .help("Change who is speaking in this turn")

                if segment.hasLowSpeakerConfidence, let confidence = segment.speakerConfidence {
                    Label("Uncertain speaker (\(Int((confidence * 100).rounded()))%)", systemImage: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if segment.overlap {
                    Label("Overlapping speech", systemImage: "person.2.badge.gearshape")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                }
                if segment.timingQuality == .segmentOnly {
                    Label("Estimated timing", systemImage: "clock.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
                if isHovering, !isEditing {
                    HStack(spacing: 8) {
                        rowTool("pencil", help: "Edit words (⌘E)", action: onBeginEditing)
                        rowTool("scissors", help: "Split this turn (⇧⌘S)", action: onSplit)
                            .disabled(viewModel.splitTokens(for: segment).count < 2)
                        rowTool("arrow.up.to.line", help: "Combine with previous (⌥⌘↑)") { viewModel.merge(segmentID: segment.id, withNext: false) }
                            .disabled(viewModel.segment(before: segment.id) == nil)
                        rowTool("arrow.down.to.line", help: "Combine with next (⌥⌘↓)") { viewModel.merge(segmentID: segment.id, withNext: true) }
                            .disabled(viewModel.segment(after: segment.id) == nil)
                    }
                    .transition(.opacity)
                }
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onPlay)
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(segment.speakerLabel), \(segment.text)")
        .accessibilityHint("Double-click to play from \(TranscriptTimecode.string(fromMilliseconds: segment.startMs)) through the turns that follow")
    }

    private var background: Color {
        if isPlaying { return Color.accentColor.opacity(0.18) }
        if isSelected { return Color.accentColor.opacity(0.12) }
        return Color.secondary.opacity(0.06)
    }

    private func rowTool(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
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

private struct TranscriptExportResults: View {
    let outcomes: [TranscriptExportOutcome]

    var body: some View {
        if !outcomes.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(outcomes) { outcome in
                    if outcome.succeeded {
                        Label("Exported \(outcome.format.rawValue.uppercased()) to \(outcome.destinationURL?.lastPathComponent ?? "destination")", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("\(outcome.format.rawValue.uppercased()) export failed: \(outcome.errorMessage ?? "Unknown error")", systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .font(.caption)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
    }
}
