import Platform
import SwiftUI

/// The Settings section that connects Scribe to Apple Calendar.
///
/// One switch. Turning it on asks macOS for calendar access the first time,
/// and afterwards every recording is named after the meeting in progress
/// when it starts. The section also shows which meeting that would be right
/// now, so a person can tell the rule is doing what they expect before they
/// depend on it.
public struct CalendarSettingsView: View {
    @ObservedObject private var settings: ScribeSettings
    @ObservedObject private var calendar: CalendarMeetingService

    public init(settings: ScribeSettings, calendar: CalendarMeetingService) {
        self.settings = settings
        self.calendar = calendar
    }

    public var body: some View {
        Section {
            Toggle(
                "Name recordings after Apple Calendar meetings",
                isOn: Binding(
                    get: { settings.useCalendarMeetingNames },
                    set: { enabled in Task { await calendar.setEnabled(enabled) } }
                )
            )
            .disabled(calendar.accessStatus == .restricted)

            if settings.useCalendarMeetingNames {
                statusRow
                if calendar.isActive {
                    currentMeetingRow
                }
            }

            Text("When a recording starts during a meeting on your calendar, the recording folder and its transcript take the meeting's name, and the meeting prompt says which meeting it is. Declined invitations and all-day events are ignored.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("Apple Calendar")
        }
        .task(id: settings.useCalendarMeetingNames) {
            guard settings.useCalendarMeetingNames else { return }
            calendar.refreshAccessStatus()
            await calendar.refreshCurrentMeeting()
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch calendar.accessStatus {
        case .granted:
            Label(calendar.statusMessage, systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .notDetermined:
            HStack {
                Text(calendar.statusMessage)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Connect") { Task { await calendar.connect() } }
                    .controlSize(.small)
            }
        case .denied:
            VStack(alignment: .leading, spacing: 6) {
                Text(calendar.statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                Button("Open System Settings…") { calendar.openSystemSettings() }
                    .controlSize(.small)
            }
        case .restricted:
            Text(calendar.statusMessage)
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    private var currentMeetingRow: some View {
        HStack {
            if let meeting = calendar.currentMeeting {
                Label("Now: \(meeting.title)", systemImage: "calendar")
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            } else {
                Label("No meeting on your calendar right now", systemImage: "calendar")
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Refresh") { Task { await calendar.refreshCurrentMeeting() } }
                .controlSize(.small)
        }
    }
}
