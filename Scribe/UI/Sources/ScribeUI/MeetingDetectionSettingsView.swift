import Platform
import SwiftUI

/// The Settings section that chooses which calls Scribe notices.
///
/// The application list is the fixed catalog, not what is running: a choice
/// made here has to survive relaunches and mean the same thing tomorrow.
/// Browsers are listed only when installed. The domain list is the browser
/// half of the rule: a browser is on a meeting when it has the microphone open
/// and a tab on one of these hosts.
public struct MeetingDetectionSettingsView: View {
    @ObservedObject private var settings: ScribeSettings
    @ObservedObject private var detector: MeetingDetector
    private let offeredApplications: [MeetingApplication]
    private let installed: Set<String>
    @State private var newDomain = ""
    @State private var domainError: String?

    public init(
        settings: ScribeSettings,
        detector: MeetingDetector,
        installedApplications: any InstalledApplicationChecking = LaunchServicesInstalledApplicationChecker()
    ) {
        self.settings = settings
        self.detector = detector
        offeredApplications = MeetingApplication.offered { installedApplications.isInstalled($0) }
        installed = Set(MeetingApplication.catalog.filter { installedApplications.isInstalled($0) }.map(\.id))
    }

    public var body: some View {
        Section {
            Toggle("Detect meetings and calls", isOn: $settings.meetingDetectionEnabled)

            Toggle("Stop recording automatically when the meeting ends", isOn: $settings.stopRecordingWhenMeetingEnds)
                .disabled(!settings.meetingDetectionEnabled)

            if let meeting = detector.detectedMeeting {
                Label("Call in progress: \(meeting.displayName)", systemImage: "phone.fill")
                    .foregroundStyle(.secondary)
            }

            ForEach(offeredApplications) { application in
                Toggle(isOn: applicationBinding(application)) {
                    HStack(spacing: 6) {
                        Text(application.name)
                        if !installed.contains(application.id) {
                            Text("Not installed")
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .disabled(!settings.meetingDetectionEnabled)
            }

            Text("A call is detected when one of these applications has the microphone open. Muting does not end a call; quitting or hanging up does. Automatic stop applies only to recordings started from the meeting prompt.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("Meeting detection")
        }

        Section {
            ForEach(settings.meetingDomains, id: \.self) { domain in
                HStack {
                    Text(domain)
                    Spacer()
                    Button {
                        settings.removeMeetingDomain(domain)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(domain)")
                }
            }
            HStack {
                TextField("Add a domain, such as teams.microsoft.com", text: $newDomain)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addDomain)
                Button("Add", action: addDomain)
                    .disabled(newDomain.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let domainError {
                Text(domainError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            if settings.meetingDomains != MeetingDomain.defaults {
                Button("Use Default") { settings.resetMeetingDomains() }
                    .controlSize(.small)
            }
            Text(domainsFootnote)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let issue = detector.browserProbeIssue {
                Text(issue)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Meeting websites")
        }
        .disabled(!settings.meetingDetectionEnabled)
    }

    private var domainsFootnote: String {
        var lines = ["In a browser, a call counts only when a tab is on one of these websites; subdomains match too."]
        if offeredApplications.contains(where: \.isBrowser) {
            lines.append("The first time a browser is checked, macOS asks whether Scribe may read its tabs. Leave the list empty to treat browsers like any other application.")
        }
        return lines.joined(separator: " ")
    }

    private func applicationBinding(_ application: MeetingApplication) -> Binding<Bool> {
        Binding(
            get: { settings.isMeetingDetectionEnabled(for: application) },
            set: { settings.setMeetingDetection($0, for: application) }
        )
    }

    private func addDomain() {
        let input = newDomain
        guard !input.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if settings.addMeetingDomain(input) != nil {
            newDomain = ""
            domainError = nil
        } else {
            domainError = "Enter a website address such as meet.google.com."
        }
    }
}
