import SwiftUI

/// Manages the local speaker library: names, voice signatures, automatic
/// matching, enrollment samples, and deletion.
///
/// Enrollment itself happens in a transcript, where the user can hear the
/// excerpts being confirmed; this view manages what enrollment produced.
public struct SpeakersView: View {
    @Bindable private var viewModel: SpeakerLibraryViewModel
    @State private var newPersonName = ""
    @State private var isAddingPerson = false
    @State private var profilePendingDeletion: SpeakerLibraryRow?

    public init(viewModel: SpeakerLibraryViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: $viewModel.selectedProfileID) {
                ForEach(viewModel.rows) { row in
                    SpeakerListRow(row: row, isOwner: viewModel.ownerProfileID == row.id)
                        .tag(row.id)
                    .contextMenu {
                        Button("Delete Person…", role: .destructive) { profilePendingDeletion = row }
                    }
                }
            }
            .navigationTitle("Speakers")
            .frame(minWidth: 230)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // Opaque so rows scrolling underneath never show through the button.
                VStack(spacing: 0) {
                    Divider()
                    Button("Add Person", systemImage: "person.badge.plus") { isAddingPerson = true }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(nsColor: .windowBackgroundColor))
            }
        } detail: {
            if let row = viewModel.selectedRow {
                SpeakerProfileDetail(row: row, viewModel: viewModel) { profilePendingDeletion = row }
            } else {
                ContentUnavailableView(
                    "No person selected",
                    systemImage: "person.crop.circle",
                    description: Text("Add a person here, or use “Remember this voice” in a transcript to enroll one.")
                )
            }
        }
        .task { await viewModel.load() }
        .alert("Add Person", isPresented: $isAddingPerson) {
            TextField("Name", text: $newPersonName)
            Button("Cancel", role: .cancel) { newPersonName = "" }
            Button("Add") {
                let name = newPersonName
                newPersonName = ""
                Task { await viewModel.addPerson(named: name) }
            }
        } message: {
            Text("A new person has no voice signature, so they are never matched automatically until you enroll confirmed excerpts.")
        }
        .alert(
            "Delete \(profilePendingDeletion?.displayName ?? "this person")?",
            isPresented: Binding(get: { profilePendingDeletion != nil }, set: { if !$0 { profilePendingDeletion = nil } })
        ) {
            Button("Cancel", role: .cancel) { profilePendingDeletion = nil }
            Button("Delete", role: .destructive) {
                guard let row = profilePendingDeletion else { return }
                profilePendingDeletion = nil
                Task { await viewModel.deleteProfile(row.id) }
            }
        } message: {
            Text("Their voice signatures and retained clips are removed and they stop matching future recordings. Existing transcripts keep the labels they already saved.")
        }
        .safeAreaInset(edge: .bottom) {
            if let message = viewModel.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
            }
        }
    }
}

/// One sidebar row: the name, a "Me" tag on the owner's profile, and a
/// trailing icon for matching state. The full status stays in the tooltip.
private struct SpeakerListRow: View {
    let row: SpeakerLibraryRow
    let isOwner: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(row.displayName).lineLimit(1)
            if isOwner {
                Text("Me")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .accessibilityLabel("This is me")
            }
            Spacer(minLength: 4)
            statusIcon
        }
        .help(row.matchingStatus)
    }

    @ViewBuilder private var statusIcon: some View {
        if row.needsReenrollment {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel(row.matchingStatus)
        } else if !row.isNameOnly && row.automaticMatchingEnabled {
            Image(systemName: "waveform")
                .foregroundStyle(.secondary)
                .accessibilityLabel(row.matchingStatus)
        }
    }
}

private struct SpeakerProfileDetail: View {
    let row: SpeakerLibraryRow
    @Bindable var viewModel: SpeakerLibraryViewModel
    let requestDeletion: () -> Void

    @State private var editedName = ""

    var body: some View {
        Form {
            Section("Name") {
                TextField("Name", text: $editedName)
                    .onSubmit { Task { await viewModel.rename(profileID: row.id, to: editedName) } }
                Button("Save Name") { Task { await viewModel.rename(profileID: row.id, to: editedName) } }
                    .disabled(editedName.trimmingCharacters(in: .whitespacesAndNewlines) == row.displayName)
            }

            Section("My profile") {
                Toggle("This is me", isOn: Binding(
                    get: { viewModel.ownerProfileID == row.id },
                    set: { enabled in Task { await viewModel.setOwner(profileID: enabled ? row.id : nil) } }
                ))
                Text("Used by the optional microphone identification setting for remote calls. Only one profile can be yours.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Automatic matching") {
                Toggle(
                    "Match this voice in new recordings",
                    isOn: Binding(
                        get: { row.automaticMatchingEnabled },
                        set: { enabled in Task { await viewModel.setAutomaticMatching(enabled, for: row.id) } }
                    )
                )
                Text(row.matchingStatus).font(.caption).foregroundStyle(.secondary)
                if row.isNameOnly {
                    Label(
                        row.needsReenrollment
                            ? "These signatures came from a different embedding model and need reenrollment."
                            : "Enroll confirmed excerpts from a transcript before this person can be matched.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section("Enrollment samples") {
                if row.signatures.isEmpty {
                    Text("No voice signatures stored.").foregroundStyle(.secondary)
                } else {
                    Text("\(row.signatures.count) sample(s), \(Int(row.usableSpeechDuration.rounded()))s of usable speech")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(row.signatures) { signature in
                        SpeakerSignatureRow(signature: signature) {
                            Task { await viewModel.removeSignature(signature.signatureID, from: row.id) }
                        }
                    }
                }
            }

            Section {
                Button("Delete Person…", role: .destructive, action: requestDeletion)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(row.displayName)
        .onAppear { editedName = row.displayName }
        .onChange(of: row.id) { editedName = row.displayName }
    }
}

private struct SpeakerSignatureRow: View {
    let signature: SpeakerSignature
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Int(signature.usableSpeechDuration.rounded()))s from \(signature.enrollmentSourceID)")
                Text("\(signature.embeddingModel.modelID) rev \(signature.embeddingModel.revision) · confirmed \(signature.confirmedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !signature.isCompatible {
                    Label("Needs reenrollment", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if signature.retainedClipURL != nil {
                    Label("Clip retained locally", systemImage: "waveform")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Remove", role: .destructive, action: remove)
                .buttonStyle(.borderless)
        }
    }
}
