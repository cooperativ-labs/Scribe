import Foundation
import Testing
@testable import Platform

// MARK: - Fakes

private final class FakeMicrophoneProbe: MicrophoneActivityProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [AudioInputProcess] = []

    func set(_ processes: [AudioInputProcess]) { lock.withLock { self.processes = processes } }
    func processesRunningInput() -> [AudioInputProcess] { lock.withLock { processes } }
}

private final class FakeBrowserProbe: BrowserTabURLProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [String: BrowserTabProbeResult] = [:]
    private(set) var askedBundleIdentifiers: [String] = []

    func set(_ result: BrowserTabProbeResult, for bundleIdentifier: String) {
        lock.withLock { results[bundleIdentifier] = result }
    }

    func tabURLs(ofApplicationWithBundleIdentifier bundleIdentifier: String) async -> BrowserTabProbeResult {
        lock.withLock {
            askedBundleIdentifiers.append(bundleIdentifier)
            return results[bundleIdentifier] ?? .urls([])
        }
    }
}

@MainActor
private func makeSettings() throws -> (ScribeSettings, cleanup: () -> Void) {
    let suiteName = "MeetingDetectionTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    let settings = ScribeSettings(defaults: defaults, defaultRecordingsFolderURL: FileManager.default.temporaryDirectory)
    return (settings, { defaults.removePersistentDomain(forName: suiteName) })
}

private let zoom = MeetingApplication.catalog.first { $0.id == "zoom" }!
private let arc = MeetingApplication.catalog.first { $0.id == "arc" }!
private let slack = MeetingApplication.catalog.first { $0.id == "slack" }!

// MARK: - Catalog

@Suite struct MeetingApplicationCatalogTests {
    @Test func offersEveryRequestedApplication() {
        let names = Set(MeetingApplication.catalog.map(\.name))
        for expected in ["Zoom", "Google Chrome", "Arc", "Microsoft Edge", "Microsoft Teams", "Slack", "FaceTime", "WhatsApp", "Signal", "Discord"] {
            #expect(names.contains(expected), "\(expected) is missing from the catalog")
        }
        #expect(Set(MeetingApplication.catalog.map(\.id)).count == MeetingApplication.catalog.count, "ids must be unique")
    }

    @Test func browsersAreOfferedOnlyWhenInstalled() {
        let offered = MeetingApplication.offered { $0.id == "arc" }
        #expect(offered.filter(\.isBrowser).map(\.id) == ["arc"])
        // The calling applications are always listed so the settings read the same everywhere.
        #expect(offered.contains(zoom))
        #expect(offered.contains(slack))
    }

    @Test func matchesHelperProcessesCaseInsensitively() {
        #expect(arc.matches(processBundleIdentifier: "company.thebrowser.Browser"))
        #expect(arc.matches(processBundleIdentifier: "company.thebrowser.browser.helper"))
        #expect(MeetingApplication.application(matchingProcessBundleIdentifier: "org.whispersystems.signal-desktop.helper.Renderer")?.id == "signal")
        #expect(MeetingApplication.application(matchingProcessBundleIdentifier: "com.microsoft.teams")?.id == "teams")
        #expect(MeetingApplication.application(matchingProcessBundleIdentifier: "com.microsoft.teams2.helper")?.id == "teams")
        // A sibling product is not a helper.
        #expect(MeetingApplication.application(matchingProcessBundleIdentifier: "com.google.Chrome.beta") == nil)
        #expect(MeetingApplication.application(matchingProcessBundleIdentifier: "com.apple.controlcenter") == nil)
    }
}

// MARK: - Domains

@Suite struct MeetingDomainTests {
    @Test func normalizesWhateverWasTyped() {
        #expect(MeetingDomain.normalize("meet.google.com") == "meet.google.com")
        #expect(MeetingDomain.normalize("  https://Meet.Google.com/abc-defg-hij?x=1  ") == "meet.google.com")
        #expect(MeetingDomain.normalize("teams.microsoft.com/l/meetup-join") == "teams.microsoft.com")
        #expect(MeetingDomain.normalize("https://user@zoom.us:443/j/1") == "zoom.us")
        #expect(MeetingDomain.normalize("") == nil)
        #expect(MeetingDomain.normalize("localhost") == nil)
        #expect(MeetingDomain.normalize("not a domain") == nil)
    }

    @Test func matchesHostAndSubdomainsOnly() {
        #expect(MeetingDomain.host("meet.google.com", matches: "meet.google.com"))
        #expect(MeetingDomain.host("us05web.zoom.us", matches: "zoom.us"))
        #expect(!MeetingDomain.host("notzoom.us", matches: "zoom.us"))
        #expect(!MeetingDomain.host("google.com", matches: "meet.google.com"))
        let url = URL(string: "https://meet.google.com/abc-defg-hij")!
        #expect(MeetingDomain.matchingDomain(for: url, among: ["zoom.us", "meet.google.com"]) == "meet.google.com")
        #expect(MeetingDomain.matchingDomain(for: URL(string: "https://mail.google.com")!, among: ["meet.google.com"]) == nil)
    }
}

// MARK: - Settings

@Suite struct MeetingDetectionSettingsTests {
    @MainActor @Test func everythingIsWatchedByDefault() throws {
        let (settings, cleanup) = try makeSettings()
        defer { cleanup() }
        #expect(settings.meetingDetectionEnabled)
        #expect(!settings.stopRecordingWhenMeetingEnds)
        for application in MeetingApplication.catalog {
            #expect(settings.isMeetingDetectionEnabled(for: application))
        }
        #expect(settings.meetingDomains == ["meet.google.com"])
    }

    @MainActor @Test func choicesPersistAcrossLaunches() throws {
        let suiteName = "MeetingDetectionTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = ScribeSettings(defaults: defaults, defaultRecordingsFolderURL: FileManager.default.temporaryDirectory)
        first.setMeetingDetection(false, for: slack)
        first.meetingDetectionEnabled = false
        first.stopRecordingWhenMeetingEnds = true
        #expect(first.addMeetingDomain("https://zoom.us/j/123") == "zoom.us")
        #expect(first.addMeetingDomain("zoom.us") == "zoom.us", "a duplicate is accepted but stored once")
        #expect(first.addMeetingDomain("   ") == nil)
        first.removeMeetingDomain("meet.google.com")

        let second = ScribeSettings(defaults: defaults, defaultRecordingsFolderURL: FileManager.default.temporaryDirectory)
        #expect(!second.meetingDetectionEnabled)
        #expect(second.stopRecordingWhenMeetingEnds)
        #expect(!second.isMeetingDetectionEnabled(for: slack))
        #expect(second.isMeetingDetectionEnabled(for: zoom))
        #expect(second.meetingDomains == ["zoom.us"])

        second.setMeetingDetection(true, for: slack)
        second.resetMeetingDomains()
        let third = ScribeSettings(defaults: defaults, defaultRecordingsFolderURL: FileManager.default.temporaryDirectory)
        #expect(third.isMeetingDetectionEnabled(for: slack))
        #expect(third.meetingDomains == ["meet.google.com"])
    }
}

// MARK: - Detector

@MainActor
private struct Harness {
    let settings: ScribeSettings
    let cleanup: () -> Void
    let microphone = FakeMicrophoneProbe()
    let browser = FakeBrowserProbe()
    let detector: MeetingDetector

    init() throws {
        let (settings, cleanup) = try makeSettings()
        self.settings = settings
        self.cleanup = cleanup
        let clock = Clock()
        self.clock = clock
        detector = MeetingDetector(
            settings: settings,
            microphoneProbe: microphone,
            browserProbe: browser,
            pollInterval: 60,
            endGracePeriod: 5,
            browserRefreshInterval: 10,
            now: { clock.now }
        )
    }

    private let clock: Clock
    @MainActor final class Clock { var now = Date(timeIntervalSince1970: 1_000) }

    func advance(_ seconds: TimeInterval) { clock.now = clock.now.addingTimeInterval(seconds) }
}

@Suite struct MeetingDetectorTests {
    @MainActor @Test func aNativeApplicationWithTheMicrophoneOpenIsACall() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        var seen: [DetectedMeeting?] = []
        harness.detector.onChange = { seen.append($0) }

        harness.microphone.set([AudioInputProcess(processIdentifier: 42, bundleIdentifier: "us.zoom.xos")])
        await harness.detector.poll()

        let meeting = try #require(harness.detector.detectedMeeting)
        #expect(meeting.application == zoom)
        #expect(meeting.bundleIdentifier == "us.zoom.xos")
        #expect(meeting.processIdentifier == 42)
        #expect(meeting.domain == nil)
        #expect(meeting.displayName == "Zoom")
        #expect(seen.count == 1)
        #expect(harness.browser.askedBundleIdentifiers.isEmpty, "native applications are never asked about tabs")
    }

    @MainActor @Test func unrelatedMicrophoneUsersAreIgnored() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        harness.microphone.set([
            AudioInputProcess(processIdentifier: 1, bundleIdentifier: "com.apple.controlcenter"),
            AudioInputProcess(processIdentifier: 2, bundleIdentifier: "com.scribe.app"),
        ])
        await harness.detector.poll()
        #expect(harness.detector.detectedMeeting == nil)
    }

    @MainActor @Test func anUncheckedApplicationIsNotReported() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        harness.settings.setMeetingDetection(false, for: zoom)
        harness.microphone.set([AudioInputProcess(processIdentifier: 42, bundleIdentifier: "us.zoom.xos")])
        await harness.detector.poll()
        #expect(harness.detector.detectedMeeting == nil)

        harness.settings.setMeetingDetection(true, for: zoom)
        await harness.detector.poll()
        #expect(harness.detector.detectedMeeting?.application == zoom)
    }

    @MainActor @Test func theMasterSwitchStopsEverything() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        harness.microphone.set([AudioInputProcess(processIdentifier: 42, bundleIdentifier: "us.zoom.xos")])
        await harness.detector.poll()
        #expect(harness.detector.detectedMeeting != nil)

        harness.settings.meetingDetectionEnabled = false
        await harness.detector.poll()
        #expect(harness.detector.detectedMeeting == nil, "turning detection off clears an active detection immediately")
    }

    @MainActor @Test func aBrowserNeedsATabOnAChosenDomain() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        harness.microphone.set([AudioInputProcess(processIdentifier: 77, bundleIdentifier: "company.thebrowser.browser.helper")])

        harness.browser.set(.urls([URL(string: "https://mail.google.com/")!, URL(string: "https://github.com")!]), for: "company.thebrowser.Browser")
        await harness.detector.poll()
        #expect(harness.detector.detectedMeeting == nil, "a browser using the microphone for something else is not a meeting")
        #expect(harness.browser.askedBundleIdentifiers == ["company.thebrowser.Browser"], "the main application is asked, not the helper")

        harness.browser.set(.urls([URL(string: "https://mail.google.com/")!, URL(string: "https://meet.google.com/abc-defg-hij")!]), for: "company.thebrowser.Browser")
        await harness.detector.poll()
        let meeting = try #require(harness.detector.detectedMeeting)
        #expect(meeting.application == arc)
        #expect(meeting.bundleIdentifier == "company.thebrowser.Browser")
        #expect(meeting.domain == "meet.google.com")
        #expect(meeting.displayName == "meet.google.com in Arc")
    }

    @MainActor @Test func aBrowserWhoseTabsCannotBeReadIsStillReported() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        harness.microphone.set([AudioInputProcess(processIdentifier: 77, bundleIdentifier: "com.google.Chrome.helper")])
        harness.browser.set(.unavailable("allow Scribe to control it under System Settings."), for: "com.google.Chrome")

        await harness.detector.poll()
        let meeting = try #require(harness.detector.detectedMeeting)
        #expect(meeting.application.id == "chrome")
        #expect(meeting.domain == nil)
        let issue = try #require(harness.detector.browserProbeIssue)
        #expect(issue.contains("Google Chrome"))
        #expect(issue.contains("System Settings"))

        // Once the browser answers, the notice goes away. Tabs are re-read on the
        // refresh interval, not every poll.
        harness.browser.set(.urls([URL(string: "https://meet.google.com/x")!]), for: "com.google.Chrome")
        harness.advance(2)
        await harness.detector.poll()
        #expect(harness.browser.askedBundleIdentifiers.count == 1)
        #expect(harness.detector.browserProbeIssue != nil)
        harness.advance(10)
        await harness.detector.poll()
        #expect(harness.browser.askedBundleIdentifiers.count == 2)
        #expect(harness.detector.browserProbeIssue == nil)
        #expect(harness.detector.detectedMeeting?.domain == "meet.google.com")
    }

    @MainActor @Test func closingTheMeetingTabEndsABrowserCall() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        harness.microphone.set([AudioInputProcess(processIdentifier: 77, bundleIdentifier: "com.google.Chrome.helper")])
        harness.browser.set(.urls([URL(string: "https://meet.google.com/x")!]), for: "com.google.Chrome")
        await harness.detector.poll()
        #expect(harness.detector.detectedMeeting?.domain == "meet.google.com")

        // The tab is closed but the browser keeps the microphone for a voice note.
        harness.browser.set(.urls([URL(string: "https://example.com")!]), for: "com.google.Chrome")
        harness.advance(2)
        await harness.detector.poll()
        #expect(harness.detector.detectedMeeting != nil, "tabs are not re-read on every poll")
        harness.advance(10)
        await harness.detector.poll()
        #expect(harness.detector.detectedMeeting == nil, "a tab list with no meeting is definite")
    }

    @MainActor @Test func withNoDomainsABrowserIsTreatedLikeAnyApplication() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        harness.settings.removeMeetingDomain("meet.google.com")
        harness.microphone.set([AudioInputProcess(processIdentifier: 77, bundleIdentifier: "com.google.Chrome.helper")])
        await harness.detector.poll()
        #expect(harness.detector.detectedMeeting?.application.id == "chrome")
        #expect(harness.browser.askedBundleIdentifiers.isEmpty)
    }

    @MainActor @Test func theFirstCallIsKeptWhenASecondApplicationJoins() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        harness.microphone.set([AudioInputProcess(processIdentifier: 9, bundleIdentifier: "com.tinyspeck.slackmacgap.helper")])
        await harness.detector.poll()
        #expect(harness.detector.detectedMeeting?.application == slack)

        // Zoom is earlier in the catalog, but the Slack huddle is what is being offered.
        harness.microphone.set([
            AudioInputProcess(processIdentifier: 42, bundleIdentifier: "us.zoom.xos"),
            AudioInputProcess(processIdentifier: 9, bundleIdentifier: "com.tinyspeck.slackmacgap.helper"),
        ])
        await harness.detector.poll()
        #expect(harness.detector.detectedMeeting?.application == slack)
    }

    @MainActor @Test func aCallEndsOnlyAfterTheGracePeriod() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        var seen: [DetectedMeeting?] = []
        harness.detector.onChange = { seen.append($0) }
        harness.microphone.set([AudioInputProcess(processIdentifier: 42, bundleIdentifier: "us.zoom.xos")])
        await harness.detector.poll()

        // The device closes for a moment while the call reconnects.
        harness.microphone.set([])
        harness.advance(2)
        await harness.detector.poll()
        #expect(harness.detector.detectedMeeting != nil, "a brief close is not the end of the call")

        harness.microphone.set([AudioInputProcess(processIdentifier: 42, bundleIdentifier: "us.zoom.xos")])
        harness.advance(2)
        await harness.detector.poll()
        #expect(seen.count == 1, "the reconnect was not reported as a new call")

        harness.microphone.set([])
        harness.advance(6)
        await harness.detector.poll()
        #expect(harness.detector.detectedMeeting == nil)
        #expect(seen.count == 2)
        #expect(seen.last! == nil)
    }
}
