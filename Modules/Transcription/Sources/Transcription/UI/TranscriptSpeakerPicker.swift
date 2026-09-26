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

/// The recording-local speakers of the selected transcript as a wrapping row
/// of chips: palette dot, name, and turn count.
///
/// Clicking a chip filters the list to that speaker; pressing and holding or
/// right-clicking opens naming, merging, and Remember Voice. A pending match
/// rides on its chip with a one-tap confirm, and "Not now" lives in the chip's
/// menu. The row wraps to at most three lines and then scrolls horizontally, so
/// many speakers cannot squeeze the transcript out of the window.
struct TranscriptSpeakerChips: View {
    @Bindable var viewModel: TranscriptViewModel
    @State private var newPersonSpeakerID: String?
    @State private var availableWidth: CGFloat = 0

    static let maxLines = 3

    var body: some View {
        ScrollView(.horizontal) {
            TranscriptChipFlowLayout(
                targetWidth: availableWidth,
                spacing: TranscriptDesign.Spacing.chipSpacing,
                maxLines: Self.maxLines
            ) {
                ForEach(viewModel.speakerRows) { row in
                    chip(for: row)
                }
            }
        }
        .scrollIndicators(.automatic)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        // The flow is at most three chip lines tall, so its ideal height is
        // bounded; the horizontal scroll view otherwise has no height of its own.
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Speakers in this recording")
        .sheet(
            isPresented: Binding(
                get: { viewModel.enrollmentSpeakerID != nil },
                set: { if !$0 { viewModel.cancelRememberingVoice() } }
            )
        ) {
            TranscriptEnrollmentSheet(viewModel: viewModel)
        }
    }

    @ViewBuilder
    private func chip(for row: TranscriptSpeakerRow) -> some View {
        let isSelected = viewModel.speakerFilterID == row.speakerID
        let color = viewModel.color(forSpeakerID: row.speakerID) ?? Color.secondary
        // A speaker nobody has named yet keeps the dashed dot, as its turns do.
        let swatch = row.profileID == nil ? nil : viewModel.speakerSwatch(forSpeakerID: row.speakerID)

        HStack(spacing: 4) {
            Menu {
                menuItems(for: row)
            } label: {
                HStack(spacing: 6) {
                    TranscriptSpeakerDot(swatch)
                    Text(row.label)
                        .foregroundStyle(.primary)
                    Text(row.segmentCount, format: .number)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(TranscriptDesign.TypeRole.chip)
                .lineLimit(1)
                .contentShape(Capsule())
            } primaryAction: {
                viewModel.speakerFilterID = isSelected ? nil : row.speakerID
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(chipHelp(for: row, isSelected: isSelected))
            .accessibilityLabel("\(row.label), \(row.segmentCount) turn\(row.segmentCount == 1 ? "" : "s")")
            .accessibilityValue(isSelected ? "Showing only this speaker" : "")
            .accessibilityHint("Toggles a filter to this speaker's turns. Open the menu to name, merge, or remember the voice.")
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            if let suggestion = row.suggestion {
                suggestionBadge(suggestion, row: row)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, row.suggestion == nil ? 10 : 3)
        .padding(.vertical, row.suggestion == nil ? 5 : 3)
        .background(
            isSelected ? color.opacity(TranscriptDesign.Tint.chipFill) : Color.primary.opacity(TranscriptDesign.Tint.neutralFill),
            in: Capsule()
        )
        .overlay {
            Capsule().strokeBorder(
                isSelected ? color.opacity(0.6) : Color.primary.opacity(TranscriptDesign.Tint.hairline),
                lineWidth: isSelected ? 1 : 0.5
            )
        }
        .contextMenu { menuItems(for: row) }
        .popover(
            isPresented: Binding(
                get: { newPersonSpeakerID == row.speakerID },
                set: { if !$0, newPersonSpeakerID == row.speakerID { newPersonSpeakerID = nil } }
            ),
            arrowEdge: .bottom
        ) {
            TranscriptNewPersonPopover(viewModel: viewModel, scope: .cluster(speakerID: row.speakerID))
        }
    }

    @ViewBuilder
    private func menuItems(for row: TranscriptSpeakerRow) -> some View {
        if let suggestion = row.suggestion {
            Section("Suggested: \(suggestion.person.displayName) (\(suggestion.percentDescription))") {
                Button("Confirm \(suggestion.person.displayName)") { viewModel.confirm(suggestion) }
                Button("Not Now") { viewModel.dismiss(suggestion) }
            }
            Divider()
        }
        TranscriptSpeakerMenuItems(viewModel: viewModel, scope: .cluster(speakerID: row.speakerID)) {
            newPersonSpeakerID = row.speakerID
        }
        Divider()
        Button("Remember Voice…") { viewModel.beginRememberingVoice(speakerID: row.speakerID) }
    }

    private func suggestionBadge(_ suggestion: TranscriptSpeakerSuggestion, row: TranscriptSpeakerRow) -> some View {
        Button {
            viewModel.confirm(suggestion)
        } label: {
            HStack(spacing: 4) {
                Text(suggestion.chipBadgeTitle)
                Image(systemName: "checkmark.circle.fill")
            }
            .font(TranscriptDesign.TypeRole.badge)
            .lineLimit(1)
            .foregroundStyle(TranscriptDesign.reviewUncertain)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(TranscriptDesign.reviewUncertain.opacity(TranscriptDesign.Tint.chipFill), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Confirm \(suggestion.person.displayName) for \(row.label). \(suggestion.scoreDescription.capitalizedFirst); a similarity score is not proof of identity. \"Not Now\" is in the chip's menu.")
        .accessibilityLabel("Confirm \(suggestion.person.displayName) for \(row.label), \(suggestion.percentDescription) similar")
    }

    private func chipHelp(for row: TranscriptSpeakerRow, isSelected: Bool) -> String {
        let action = isSelected ? "Click to show every speaker." : "Click to show only this speaker's turns."
        return "\(row.statusDescription). \(action) Press and hold or right-click to name, merge, or remember this voice."
    }
}

/// Wraps chips onto lines no wider than `targetWidth`, widening the lines when
/// that would take more than `maxLines`, so the surrounding horizontal scroll
/// view scrolls instead of the row growing taller.
struct TranscriptChipFlowLayout: Layout {
    var targetWidth: CGFloat
    var spacing: CGFloat
    var maxLines: Int

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return Self.arrange(sizes: sizes, targetWidth: targetWidth, spacing: spacing, maxLines: maxLines).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let arrangement = Self.arrange(sizes: sizes, targetWidth: targetWidth, spacing: spacing, maxLines: maxLines)
        for (index, origin) in arrangement.origins.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: ProposedViewSize(sizes[index])
            )
        }
    }

    struct Arrangement: Equatable {
        var origins: [CGPoint]
        var size: CGSize
        var lineCount: Int
    }

    /// Greedy line filling at the narrowest width, from `targetWidth` up to one
    /// single line, that fits in `maxLines`.
    static func arrange(sizes: [CGSize], targetWidth: CGFloat, spacing: CGFloat, maxLines: Int) -> Arrangement {
        guard !sizes.isEmpty else { return Arrangement(origins: [], size: .zero, lineCount: 0) }
        let singleLine = sizes.map(\.width).reduce(0, +) + spacing * CGFloat(sizes.count - 1)
        let widest = sizes.map(\.width).max() ?? 0
        var width = min(max(targetWidth, widest), singleLine)
        var arrangement = fill(sizes: sizes, width: width, spacing: spacing)
        while arrangement.lineCount > max(maxLines, 1), width < singleLine {
            width = min(width + max(widest / 2, 24), singleLine)
            arrangement = fill(sizes: sizes, width: width, spacing: spacing)
        }
        return arrangement
    }

    private static func fill(sizes: [CGSize], width: CGFloat, spacing: CGFloat) -> Arrangement {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        var lineCount = 1
        for size in sizes {
            if x > 0, x + size.width > width + 0.5 {
                y += lineHeight + spacing
                x = 0
                lineHeight = 0
                lineCount += 1
            }
            origins.append(CGPoint(x: x, y: y))
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return Arrangement(origins: origins, size: CGSize(width: usedWidth, height: y + lineHeight), lineCount: lineCount)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
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
