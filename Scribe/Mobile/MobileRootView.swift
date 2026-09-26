import ScribeDesign
import ScribeMobile
import SwiftUI
import UniformTypeIdentifiers

struct MobileRootView: View {
    @Bindable var model: MobileAppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var importing = false
    @State private var installing = false
    @State private var settings = false
    @State private var query = ""
    @State private var deleting: Meeting?
    @State private var editingSpeaker: String?
    @State private var speakerName = ""
    @ScaledMetric(relativeTo: .body) private var turnSize = TranscriptDesign.TypeRole.turnFontSize

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                Section {
                    ForEach(model.meetings.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }) { meeting in
                        NavigationLink(value: meeting.id) {
                            VStack(alignment: .leading, spacing: TranscriptDesign.Spacing.chipSpacing) {
                                Text(meeting.title).font(.headline).lineLimit(2)
                                HStack {
                                    Text(meeting.createdAt, style: .date)
                                    Spacer()
                                    Text(meeting.state.rawValue.capitalized)
                                }.font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, TranscriptDesign.Spacing.rowVerticalPadding)
                        }.contextMenu {
                            Button("Delete recording", role: .destructive) { deleting = meeting }.disabled(!model.canStart)
                        }
                    }
                } footer: {
                    Text("Audio and transcripts stay on this device.")
                }
            }
            .navigationTitle("Transcripts")
            .searchable(text: $query, prompt: "Find a meeting")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Settings", systemImage: "gearshape") { settings = true } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Import recording", systemImage: "square.and.arrow.down") { importing = true }.disabled(!model.canStart)
                    Button("Record meeting", systemImage: "mic") { model.record() }.disabled(!model.canStart)
                }
            }
        } detail: {
            if let meeting = model.selected {
                detail(meeting).navigationTitle(meeting.title).navigationBarTitleDisplayMode(.inline)
            } else {
                ContentUnavailableView {
                    Label("Your meetings, on this device", systemImage: "waveform")
                } description: {
                    Text("Record an in-person meeting or import a recording. Transcription and speaker separation run locally.")
                } actions: {
                    Button("Record a meeting", systemImage: "mic") { model.record() }.buttonStyle(.borderedProminent).disabled(!model.canStart)
                    Button("Import recording") { importing = true }.disabled(!model.canStart)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.recordingID != nil {
                HStack(spacing: TranscriptDesign.Spacing.transportHorizontalPadding) {
                    VStack(alignment: .leading) {
                        Label("Recording microphone", systemImage: "record.circle").foregroundStyle(.red)
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(Meeting.timecode(model.recorder.duration)).font(TranscriptDesign.TypeRole.timecode)
                        }
                    }
                    Spacer()
                    Button("Stop", systemImage: "stop.fill") { model.stopRecording() }.buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, TranscriptDesign.Spacing.transportHorizontalPadding)
                .padding(.vertical, TranscriptDesign.Spacing.transportVerticalPadding)
                .glassSurface(shape: TranscriptDesign.Surface.transport)
                .padding()
            } else if model.busy {
                ProgressView("Preparing…").padding().glassSurface(shape: .capsule).padding()
            }
        }
        .task { await model.load() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { model.backgrounded() } }
        .onChange(of: model.selection) { model.stopPlayback(); editingSpeaker = nil }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, .movie]) { result in
            switch result {
            case .success(let url): Task { await model.importFile(url) }
            case .failure(let error): model.error = error.localizedDescription
            }
        }
        .fileImporter(isPresented: $installing, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): Task { await model.installModels(url) }
            case .failure(let error): model.error = error.localizedDescription
            }
        }
        .sheet(isPresented: $settings) { settingsView }
        .alert("Scribe", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
            Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
        } message: { Text(model.error ?? "") }
        .confirmationDialog("Delete recording and transcript from this device?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let meeting = deleting { Task { await model.delete(meeting) } }; deleting = nil }
        }
        .alert("Name this speaker", isPresented: Binding(get: { editingSpeaker != nil }, set: { if !$0 { editingSpeaker = nil } })) {
            TextField("Speaker name", text: $speakerName)
            Button("Save") {
                if let id = editingSpeaker, let meeting = model.selected { Task { await model.renameSpeaker(id, name: speakerName, meeting: meeting) } }
                editingSpeaker = nil
            }
            Button("Cancel", role: .cancel) { editingSpeaker = nil }
        } message: { Text("This name applies only to this meeting.") }
    }

    private func detail(_ meeting: Meeting) -> some View {
        let palette = TranscriptDesign.SpeakerPalette(speakerIDs: meeting.speakerIDs)
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        TranscriptChip(meeting.state.rawValue.capitalized, systemImage: "waveform")
                        if let duration = meeting.duration { TranscriptChip(Meeting.timecode(duration), systemImage: "clock") }
                        TranscriptChip("On device", systemImage: "lock")
                    }
                    TranscriptChip(meeting.state.rawValue.capitalized, systemImage: "waveform")
                }
                if let notice = meeting.notice { Label(notice, systemImage: "exclamationmark.circle").foregroundStyle(TranscriptDesign.reviewUncertain).font(.callout) }
                if !meeting.turns.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: TranscriptDesign.Spacing.chipSpacing) {
                            ForEach(meeting.speakerIDs, id: \.self) { id in
                                Button {
                                    editingSpeaker = id; speakerName = meeting.speakerName(id)
                                } label: {
                                    TranscriptChip(meeting.speakerName(id), systemImage: "person", tint: palette.color(forSpeakerID: id))
                                        .frame(minHeight: 44)
                                }.buttonStyle(.plain).accessibilityHint("Rename speaker for this meeting")
                            }
                        }
                    }.scrollIndicators(.hidden)
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(meeting.turns) { turn in
                            HStack(alignment: .top, spacing: TranscriptDesign.Spacing.rowHorizontalPadding) {
                                Button(Meeting.timecode(turn.start)) { Task { await model.play(meeting, at: turn.start) } }
                                    .font(TranscriptDesign.TypeRole.timecode)
                                    .frame(minWidth: TranscriptDesign.Spacing.rowTimecodeColumnWidth, minHeight: 44, alignment: .topLeading)
                                    .accessibilityLabel("Play from \(Meeting.timecode(turn.start))")
                                VStack(alignment: .leading, spacing: TranscriptDesign.Spacing.chipSpacing) {
                                    HStack {
                                        TranscriptSpeakerDot(palette.swatch(forSpeakerID: turn.speakerID))
                                        Text(meeting.speakerName(turn.speakerID)).font(.subheadline.weight(.semibold))
                                        if turn.overlaps { TranscriptChip("Overlap", tint: TranscriptDesign.reviewOverlap) }
                                        else if turn.speakerID == nil { TranscriptFlagDot(.uncertain).accessibilityHidden(false).accessibilityLabel("Speaker uncertain") }
                                    }
                                    Text(turn.text).font(.system(size: turnSize))
                                        .lineSpacing(turnSize * (TranscriptDesign.TypeRole.turnLineHeightMultiple - 1.2))
                                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(.horizontal, TranscriptDesign.Spacing.rowHorizontalPadding)
                            .padding(.vertical, TranscriptDesign.Spacing.rowVerticalPadding)
                        }
                    }
                } else if meeting.state == .complete {
                    ContentUnavailableView("No speech detected", systemImage: "waveform", description: Text("The recording has been processed. You can still listen to the audio."))
                } else if meeting.state != .recording {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(meeting.state.isProcessing ? "\(meeting.state.rawValue.capitalized)…" : "Ready when you are").font(.title2.weight(.semibold))
                        Text("Keep Scribe open during transcription. Completed stages are saved if processing is interrupted.").foregroundStyle(.secondary)
                        if model.processingID == meeting.id {
                            ProgressView(); Button("Pause processing") { model.pause() }
                        } else {
                            Button(modelsButtonTitle(meeting), systemImage: "text.bubble") {
                                if model.modelsInstalled { model.process(meeting) } else { settings = true }
                            }.buttonStyle(.borderedProminent).disabled(!model.canStart)
                        }
                    }
                }
            }
            .frame(maxWidth: CGFloat(TranscriptDesign.Spacing.turnMeasureCharacters) * turnSize * 0.58, alignment: .leading)
            .padding(24).frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            if meeting.state != .recording && model.canStart {
                HStack(spacing: TranscriptDesign.Spacing.transportHorizontalPadding) {
                    Button("Play / pause", systemImage: "playpause.fill") { Task { await model.play(meeting) } }
                    if meeting.state == .complete {
                        ShareLink(item: meeting.transcriptText) { Label("Export transcript", systemImage: "square.and.arrow.up") }
                    }
                }
                .padding(.horizontal, TranscriptDesign.Spacing.transportHorizontalPadding)
                .padding(.vertical, TranscriptDesign.Spacing.transportVerticalPadding)
                .glassSurface(shape: TranscriptDesign.Surface.transport, interactive: true).padding()
            }
        }
    }
    private func modelsButtonTitle(_ meeting: Meeting) -> String {
        model.modelsInstalled ? (meeting.state == .paused || meeting.state == .failed ? "Resume transcription" : "Transcribe meeting") : "Download offline models"
    }
    @ViewBuilder private var modelStatus: some View {
        if let progress = model.modelDownload {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(progress.completedBytes), total: Double(max(1, progress.totalBytes)))
                    .accessibilityLabel("Model download")
                Text("Downloading and verifying models…")
                Text("\(ByteCountFormatter.string(fromByteCount: progress.completedBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file)) · Keep Scribe open")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Cancel Download", role: .cancel) { model.cancelModelDownload() }
        } else if model.checkingModels {
            HStack { ProgressView(); Text("Checking installed models…") }
        } else if model.modelsInstalled {
            Label("Installed · Ready to transcribe", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            Button("Show in Files", systemImage: "folder") { showModelsInFiles() }
        } else {
            if let error = model.modelDownloadError {
                Text(error).font(.footnote).foregroundStyle(.red)
            } else {
                Text("Download the model to enable transcription.").foregroundStyle(.secondary)
            }
            Button(model.modelDownloadError == nil ? "Download Model" : "Retry Download", systemImage: "arrow.down.circle") { model.downloadModels() }
                .buttonStyle(.borderedProminent).disabled(model.busy)
        }
    }
    /// Files opens the app's Documents folder through the shareddocuments scheme.
    private func showModelsInFiles() {
        Task {
            let directory = await model.models.directory
            var components = URLComponents(url: directory, resolvingAgainstBaseURL: false)
            components?.scheme = "shareddocuments"
            if let url = components?.url { await UIApplication.shared.open(url) }
        }
    }
    private var settingsView: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Model", value: "Parakeet v3 · Recommended")
                    Text("Runs on this device. The \(ByteCountFormatter.string(fromByteCount: model.models.downloadBytes, countStyle: .file)) download includes the speaker-separation model. Wi-Fi is recommended.")
                        .font(.footnote).foregroundStyle(.secondary)
                    LabeledContent("Folder") {
                        Text("On My \(UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone") › Scribe › Models").foregroundStyle(.secondary)
                    }
                    modelStatus
                } header: {
                    Text("Offline transcription")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Link("Parakeet v3 on Hugging Face · CC BY 4.0", destination: URL(string: "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml")!)
                        Link("Speaker diarization on Hugging Face · CC BY 4.0", destination: URL(string: "https://huggingface.co/FluidInference/speaker-diarization-coreml")!)
                    }
                }
                Section {
                    Button("Install from a folder in Files…") { settings = false; installing = true }
                        .disabled(!model.canStart || model.modelDownload != nil)
                } header: {
                    Text("Install without downloading")
                } footer: {
                    Text("Choose a folder that contains both “parakeet-tdt-0.6b-v3-coreml” and “speaker-diarization-coreml”. Files in iCloud Drive are downloaded first. Scribe verifies every file before installing.")
                }
                Section("Recording access") {
                    Text("Microphone access is requested when you first record. Recording can continue while the screen is locked. Calls and disconnected microphones can interrupt recording.")
                    Text("Scribe records the microphone. It does not capture audio from calls in Meet, Zoom, Teams, or Slack. Import a recording from those apps to transcribe it.")
                }
                Section("Privacy") {
                    Text("Record with everyone’s permission. Audio and transcripts are stored privately on this device and excluded from device cloud backups; only the models appear in the Scribe folder in Files. Export shares only the transcript text. Deleting a meeting removes its audio, transcript, and processing files.")
                    Text("No account, cloud inference, speech-recognition permission, or contacts access is needed. Speaker names are assigned manually within each meeting.")
                }
            }.navigationTitle("Settings").toolbar { Button("Done") { settings = false } }
        }
    }
}
