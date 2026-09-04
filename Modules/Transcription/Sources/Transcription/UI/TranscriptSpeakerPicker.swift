import Speakers
import SwiftUI

/// Assigns a turn or a verified cluster to a saved person or a new one.
///
/// Naming someone here never enrolls their voice: "Remember this voice" is a
/// separate action so a label correction cannot silently train a profile.
struct TranscriptSpeakerPicker: View {
    let viewModel: TranscriptViewModel
    let scope: TranscriptSpeakerScope
    let currentProfileID: String?

    @State private var newPersonName = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(scopeDescription).font(.headline)

            if viewModel.people.isEmpty {
                Text("No saved people yet. Add one below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(viewModel.people) { person in
                            Button {
                                viewModel.assign(person, scope: scope)
                                dismiss()
                            } label: {
                                HStack {
                                    Text(person.displayName)
                                    Spacer()
                                    if person.profileID.uuidString == currentProfileID {
                                        Image(systemName: "checkmark")
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 180)
            }

            Divider()

            HStack {
                TextField("New person", text: $newPersonName)
                    .onSubmit(addPerson)
                Button("Add", action: addPerson)
                    .disabled(newPersonName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("A new person is added by name only and is never matched automatically until you enroll their voice.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Button("Clear Name", role: .destructive) {
                viewModel.assign(nil, scope: scope)
                dismiss()
            }
            .disabled(currentProfileID == nil)
        }
        .padding(12)
        .frame(width: 300)
        .task { await viewModel.loadPeople() }
    }

    private var scopeDescription: String {
        switch scope {
        case let .cluster(speakerID): "Assign every turn of \(speakerID)"
        case .turn: "Assign this turn only"
        }
    }

    private func addPerson() {
        let name = newPersonName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        newPersonName = ""
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

/// The recording-local speakers of the selected transcript, with the picker and
/// the separate enrollment action.
struct TranscriptSpeakersInspector: View {
    let viewModel: TranscriptViewModel
    @State private var pickerScope: TranscriptSpeakerScope?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !viewModel.speakerRows.isEmpty {
                Text("Speakers in this recording").font(.headline)
            }
            ForEach(viewModel.speakerRows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.label)
                        Text("\(row.statusDescription) · \(row.segmentCount) turn(s)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Assign…") { pickerScope = .cluster(speakerID: row.speakerID) }
                        .popover(isPresented: isPresentingPicker(for: .cluster(speakerID: row.speakerID))) {
                            TranscriptSpeakerPicker(
                                viewModel: viewModel,
                                scope: .cluster(speakerID: row.speakerID),
                                currentProfileID: row.profileID
                            )
                        }
                    Button("Remember This Voice…") { viewModel.beginRememberingVoice(speakerID: row.speakerID) }
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

    private func isPresentingPicker(for scope: TranscriptSpeakerScope) -> Binding<Bool> {
        Binding(
            get: { pickerScope == scope },
            set: { if !$0, pickerScope == scope { pickerScope = nil } }
        )
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
