import Speakers
import SwiftUI

/// A macOS review window. The host supplies files as jobs complete; this view does not own jobs.
public struct TranscriptWindow: View {
    @Bindable private var viewModel: TranscriptViewModel
    @State private var isChoosingExportDirectory = false
    @State private var pendingFormats: Set<TranscriptExportFormat> = []
    @State private var turnPickerSegmentID: TranscriptSegment.ID?

    public init(viewModel: TranscriptViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: $viewModel.selectedFileID) {
                ForEach(viewModel.files) { file in
                    TranscriptFileRow(file: file)
                        .tag(file.id)
                }
            }
            .navigationTitle("Transcripts")
            .frame(minWidth: 230)
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
    }

    @ViewBuilder
    private func transcriptDetail(file: TranscriptReviewFile, transcript: CanonicalTranscript) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                TranscriptMetadataView(
                    title: file.filename,
                    language: viewModel.languageDescription,
                    timingLimitation: viewModel.timingLimitation,
                    messages: viewModel.processingMessages
                )
                TranscriptSuggestionBanner(viewModel: viewModel)
                TranscriptSpeakersInspector(viewModel: viewModel)
                if let message = viewModel.speakerActionMessage {
                    Label(message.text, systemImage: message.isFailure ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(message.isFailure ? .red : .green)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if transcript.segments.isEmpty {
                        ContentUnavailableView("No speech detected", systemImage: "waveform.slash", description: Text("This source completed without recognized speech."))
                            .frame(maxWidth: .infinity, minHeight: 240)
                    }
                    ForEach(viewModel.chronologicalSegments) { segment in
                        TranscriptSegmentRow(segment: segment, isSelected: segment.id == viewModel.selectedSegmentID) {
                            viewModel.select(segment: segment)
                        }
                        .contextMenu {
                            Button("Assign Speaker for This Turn…") { turnPickerSegmentID = segment.id }
                        }
                        .popover(isPresented: turnPickerBinding(for: segment.id)) {
                            TranscriptSpeakerPicker(
                                viewModel: viewModel,
                                scope: .turn(segmentID: segment.id),
                                currentProfileID: profileID(ofSpeaker: segment.speakerID, in: transcript)
                            )
                        }
                    }
                }
                .padding()
            }
        }
        .navigationTitle(file.filename)
        .toolbar { exportToolbar }
        .safeAreaInset(edge: .bottom) {
            TranscriptExportResults(outcomes: viewModel.exportOutcomes)
        }
    }

    @ToolbarContentBuilder
    private var exportToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
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
        }
    }

    private func chooseDestination(for formats: Set<TranscriptExportFormat>) {
        pendingFormats = formats
        isChoosingExportDirectory = true
    }

    private func turnPickerBinding(for segmentID: TranscriptSegment.ID) -> Binding<Bool> {
        Binding(
            get: { turnPickerSegmentID == segmentID },
            set: { if !$0, turnPickerSegmentID == segmentID { turnPickerSegmentID = nil } }
        )
    }

    private func profileID(ofSpeaker speakerID: String?, in transcript: CanonicalTranscript) -> String? {
        guard let speakerID else { return nil }
        return transcript.speakers.first { $0.id == speakerID }?.profileID
    }
}

private struct TranscriptFileRow: View {
    let file: TranscriptReviewFile

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(file.filename).lineLimit(1)
            if let progress = file.jobState.progress {
                ProgressView(value: progress)
            }
            Text(file.jobState.displayName)
                .font(.caption)
                .foregroundStyle(file.jobState.isFailure ? .red : .secondary)
        }
    }
}

private struct TranscriptMetadataView: View {
    let title: String
    let language: String?
    let timingLimitation: String?
    let messages: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.title2)
            if let language { Label(language, systemImage: "globe") }
            if let timingLimitation { Label(timingLimitation, systemImage: "clock.badge.exclamationmark").foregroundStyle(.orange) }
            ForEach(messages, id: \.self) { message in
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
        }
        .padding()
    }
}

private struct TranscriptSegmentRow: View {
    let segment: TranscriptSegment
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Text("\(TranscriptTimecode.string(fromMilliseconds: segment.startMs)) – \(TranscriptTimecode.string(fromMilliseconds: segment.endMs))")
                        .font(.caption.monospacedDigit())
                    if segment.speakerID == nil {
                        Label("Unknown speaker", systemImage: "person.crop.circle.badge.questionmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    } else {
                        Text(segment.speakerLabel).font(.caption.weight(.semibold))
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
                }
                Text(segment.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(segment.speakerLabel), \(segment.text)")
        .accessibilityHint("Select to seek playback to \(TranscriptTimecode.string(fromMilliseconds: segment.startMs))")
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
