import Speakers
import SwiftUI

/// The dropdown that names who is speaking, for one turn or for a whole
/// recording-local speaker.
///
/// Every choice is a menu item, so the list of existing speakers is the
/// control rather than something a person has to discover. For a turn the
/// first section is the speakers this recording already has, which is the
/// common correction: diarization filed the turn under the wrong voice. Saved
/// people not yet heard in this recording follow, then a new name, then
/// "unknown". Naming someone here never enrolls their voice: "Remember this
/// voice" is a separate action so a label correction cannot silently train a
/// profile.
struct TranscriptSpeakerMenu<Label: View>: View {
    let viewModel: TranscriptViewModel
    let scope: TranscriptSpeakerScope
    /// Called when "New Person…" is chosen; the caller presents the name popover
    /// from a stable anchor, because a menu item is gone by the time it fires.
    let onNewPerson: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Menu {
            TranscriptSpeakerMenuItems(viewModel: viewModel, scope: scope, onNewPerson: onNewPerson)
        } label: {
            label()
        }
        .menuIndicator(.visible)
        .fixedSize()
    }
}

/// The items of the speaker dropdown, shared by the row menu and the context menu.
struct TranscriptSpeakerMenuItems: View {
    let viewModel: TranscriptViewModel
    let scope: TranscriptSpeakerScope
    let onNewPerson: () -> Void

    var body: some View {
        switch scope {
        case let .turn(segmentID):
            turnItems(segmentID: segmentID)
        case let .cluster(speakerID):
            clusterItems(speakerID: speakerID)
        }
    }

    // MARK: - One turn

    @ViewBuilder
    private func turnItems(segmentID: String) -> some View {
        let segment = viewModel.chronologicalSegments.first { $0.id == segmentID }
        let speakers = viewModel.recordingSpeakers
        let inRecording = Set(speakers.compactMap(\.profileID))
        let others = viewModel.people.filter { !inRecording.contains($0.profileID.uuidString) }

        if !speakers.isEmpty {
            Section("In this recording") {
                ForEach(speakers) { speaker in
                    Toggle(isOn: Binding(
                        get: { segment?.speakerID == speaker.id },
                        set: { if $0 { viewModel.move(segmentID: segmentID, toSpeakerID: speaker.id) } }
                    )) {
                        Text(speaker.labelSnapshot)
                    }
                }
            }
        }
        if !others.isEmpty {
            Section("From your speaker library") {
                ForEach(others) { person in
                    Button(person.displayName) { viewModel.assign(person, scope: scope) }
                }
            }
        }
        Divider()
        Button("New Person…", action: onNewPerson)
        Button("Unknown Speaker") { viewModel.assign(nil, scope: scope) }
            .disabled(segment?.speakerID == nil)
    }

    // MARK: - A whole speaker

    @ViewBuilder
    private func clusterItems(speakerID: String) -> some View {
        let speaker = viewModel.recordingSpeakers.first { $0.id == speakerID }
        let others = viewModel.recordingSpeakers.filter { $0.id != speakerID }

        if viewModel.people.isEmpty {
            Text("No saved people yet")
        } else {
            Section("Name every turn as") {
                ForEach(viewModel.people) { person in
                    Toggle(isOn: Binding(
                        get: { speaker?.profileID == person.profileID.uuidString },
                        set: { if $0 { viewModel.assign(person, scope: scope) } }
                    )) {
                        Text(person.displayName)
                    }
                }
            }
        }
        Button("New Person…", action: onNewPerson)
        if !others.isEmpty {
            Divider()
            Menu("Merge Into") {
                ForEach(others) { other in
                    Button(other.labelSnapshot) { viewModel.mergeSpeaker(speakerID, into: other.id) }
                }
            }
        }
        Divider()
        Button("Clear Name") { viewModel.assign(nil, scope: scope) }
            .disabled(speaker?.profileID == nil)
    }
}

/// Adds a person to the library by name and assigns them in one step.
struct TranscriptNewPersonPopover: View {
    let viewModel: TranscriptViewModel
    let scope: TranscriptSpeakerScope

    @State private var name = ""
    @FocusState private var isFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(scopeDescription).font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(add)
            Text("A new person is added by name only and is never matched automatically until you enroll their voice.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(12)
        .frame(width: 300)
        .onAppear { isFocused = true }
    }

    private var scopeDescription: String {
        switch scope {
        case let .cluster(speakerID):
            let label = viewModel.recordingSpeakers.first { $0.id == speakerID }?.labelSnapshot ?? speakerID
            return "Name every turn of \(label)"
        case .turn:
            return "Name this turn"
        }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func add() {
        let name = trimmedName
        guard !name.isEmpty else { return }
        Task {
            await viewModel.assignNewPerson(named: name, scope: scope)
            dismiss()
        }
    }
}

/// Confirmation flow for matches the matcher scored but would not name.
struct TranscriptSuggestionBanner: View {
    let viewModel: TranscriptViewModel

    var body: some View {
        if !viewModel.pendingSuggestions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(viewModel.pendingSuggestions) { suggestion in
                    HStack(spacing: 10) {
                        Label(
                            "\(suggestion.speakerID) may be \(suggestion.person.displayName) (\(suggestion.scoreDescription))",
                            systemImage: "questionmark.circle"
                        )
                        Spacer()
                        Button("Confirm") { viewModel.confirm(suggestion) }
                        Button("Not now") { viewModel.dismiss(suggestion) }
                    }
                    .font(.callout)
                }
                Text("The generic label stays until you confirm. A similarity score is not proof of identity.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yellow.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// The recording-local speakers of the selected transcript, each with its
/// naming dropdown, a filter shortcut, and the separate enrollment action.
struct TranscriptSpeakersInspector: View {
    @Bindable var viewModel: TranscriptViewModel
    @State private var newPersonSpeakerID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(viewModel.speakerRows) { row in
                HStack(alignment: .center, spacing: 8) {
                    Button {
                        viewModel.speakerFilterID = viewModel.speakerFilterID == row.speakerID ? nil : row.speakerID
                    } label: {
                        Image(systemName: viewModel.speakerFilterID == row.speakerID ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                            .foregroundStyle(viewModel.speakerFilterID == row.speakerID ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(viewModel.speakerFilterID == row.speakerID ? "Show every speaker" : "Show only this speaker's turns")
                    .accessibilityLabel("Filter to \(row.label)")

                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.label).fontWeight(.medium)
                        Text("\(row.statusDescription) · \(row.segmentCount) turn\(row.segmentCount == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    TranscriptSpeakerMenu(
                        viewModel: viewModel,
                        scope: .cluster(speakerID: row.speakerID),
                        onNewPerson: { newPersonSpeakerID = row.speakerID }
                    ) {
                        Text(row.profileID == nil ? "Name…" : "Rename…")
                    }
                    .help("Name every turn of this speaker, merge them into another speaker, or clear the name.")
                    .popover(
                        isPresented: Binding(
                            get: { newPersonSpeakerID == row.speakerID },
                            set: { if !$0, newPersonSpeakerID == row.speakerID { newPersonSpeakerID = nil } }
                        ),
                        arrowEdge: .bottom
                    ) {
                        TranscriptNewPersonPopover(viewModel: viewModel, scope: .cluster(speakerID: row.speakerID))
                    }
                    Button("Remember Voice…") { viewModel.beginRememberingVoice(speakerID: row.speakerID) }
                        .help("Enroll confirmed excerpts so this person is recognised in future recordings.")
                }
                .padding(.vertical, 2)
            }
        }
        .sheet(
            isPresented: Binding(
                get: { viewModel.enrollmentSpeakerID != nil },
                set: { if !$0 { viewModel.cancelRememberingVoice() } }
            )
        ) {
            TranscriptEnrollmentSheet(viewModel: viewModel)
        }
    }
}

/// Confirms clean excerpts before any voice signature is written.
struct TranscriptEnrollmentSheet: View {
    let viewModel: TranscriptViewModel
    @State private var selectedPersonID: UUID?
    @State private var newPersonName = ""
    @State private var retainClips = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remember this voice").font(.title3)
            Text("Listen to each excerpt and confirm only clean speech from one person. Overlapping, estimated-timing, and very short turns cannot be enrolled.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach(viewModel.enrollmentCandidates) { candidate in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Toggle(
                            isOn: Binding(
                                get: { candidate.isConfirmed },
                                set: { viewModel.setCandidate(candidate.segmentID, confirmed: $0) }
                            )
                        ) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.text).lineLimit(2)
                                Text(excerptCaption(candidate))
                                    .font(.caption)
                                    .foregroundStyle(candidate.isEligible ? Color.secondary : Color.orange)
                            }
                        }
                        .disabled(!candidate.isEligible)
                        Button("Play", systemImage: "play.circle") { viewModel.preview(candidate) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                    }
                }
            }
            .frame(minHeight: 220)

            Picker("Enroll as", selection: $selectedPersonID) {
                Text("New person").tag(UUID?.none)
                ForEach(viewModel.people) { person in
                    Text(person.displayName).tag(UUID?.some(person.profileID))
                }
            }
            if selectedPersonID == nil {
                TextField("Name", text: $newPersonName)
            }
            Toggle("Keep the confirmed clips locally for later review", isOn: $retainClips)

            Text("Confirmed speech: \(Int(viewModel.confirmedEnrollmentDuration.rounded()))s (aim for 20–60s across several excerpts)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let message = viewModel.speakerActionMessage, message.isFailure {
                Label(message.text, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { viewModel.cancelRememberingVoice() }
                Button("Remember Voice") {
                    Task { await viewModel.rememberVoice(target: target, retainClips: retainClips) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canEnroll)
            }
        }
        .padding(16)
        .frame(width: 520)
        .task { await viewModel.loadPeople() }
    }

    private var target: SpeakerEnrollmentTarget {
        if let selectedPersonID { return .existingProfile(selectedPersonID) }
        return .newProfile(displayName: newPersonName.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var canEnroll: Bool {
        guard !viewModel.isEnrolling, viewModel.confirmedEnrollmentDuration > 0 else { return false }
        if selectedPersonID == nil {
            return !newPersonName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    private func excerptCaption(_ candidate: TranscriptEnrollmentCandidate) -> String {
        let times = "\(TranscriptTimecode.string(fromMilliseconds: candidate.startMs)) – \(TranscriptTimecode.string(fromMilliseconds: candidate.endMs))"
        guard let reason = candidate.exclusionReason else { return times }
        return "\(times) · \(reason) — not usable for enrollment"
    }
}
