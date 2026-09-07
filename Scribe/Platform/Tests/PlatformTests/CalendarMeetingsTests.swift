import Foundation
import Testing
@testable import Platform

// MARK: - Fakes

private final class FakeCalendarProvider: CalendarEventProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var status: CalendarAccessStatus
    private var statusAfterRequest: CalendarAccessStatus
    private var events: [CalendarEvent]
    private(set) var requestCount = 0
    private(set) var readCount = 0

    init(status: CalendarAccessStatus, statusAfterRequest: CalendarAccessStatus? = nil, events: [CalendarEvent] = []) {
        self.status = status
        self.statusAfterRequest = statusAfterRequest ?? status
        self.events = events
    }

    func accessStatus() -> CalendarAccessStatus { lock.withLock { status } }

    func requestAccess() async -> CalendarAccessStatus {
        lock.withLock {
            requestCount += 1
            status = statusAfterRequest
            return status
        }
    }

    func events(from start: Date, to end: Date) async -> [CalendarEvent] {
        lock.withLock {
            readCount += 1
            return events.filter { $0.endDate > start && $0.startDate < end }
        }
    }
}

@MainActor
private func makeSettings() throws -> (ScribeSettings, cleanup: () -> Void) {
    let suiteName = "CalendarMeetingsTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    let settings = ScribeSettings(defaults: defaults, defaultRecordingsFolderURL: FileManager.default.temporaryDirectory)
    return (settings, { defaults.removePersistentDomain(forName: suiteName) })
}

private let noon = Date(timeIntervalSince1970: 1_725_364_800) // 2024-09-03 12:00:00 UTC

private func event(_ title: String, from startMinutes: Double, to endMinutes: Double, allDay: Bool = false, declined: Bool = false) -> CalendarEvent {
    CalendarEvent(
        id: title,
        title: title,
        startDate: noon.addingTimeInterval(startMinutes * 60),
        endDate: noon.addingTimeInterval(endMinutes * 60),
        calendarTitle: "Work",
        isAllDay: allDay,
        isDeclined: declined
    )
}

// MARK: - Matching

@Suite struct CalendarMeetingMatcherTests {
    let matcher = CalendarMeetingMatcher(leadTime: 10 * 60, overrunTolerance: 15 * 60)

    @Test func theMeetingInProgressWins() {
        let chosen = matcher.meeting(at: noon, among: [event("Earlier", from: -60, to: -30), event("Standup", from: -5, to: 25), event("Later", from: 60, to: 90)])
        #expect(chosen?.title == "Standup")
    }

    @Test func aShortCallInsideALongBlockIsNamedAfterTheCall() {
        // A "Focus" block covers the whole afternoon; the 1:1 inside it is what
        // is actually being recorded.
        let chosen = matcher.meeting(at: noon.addingTimeInterval(5 * 60), among: [event("Focus", from: -60, to: 180), event("1:1 with Sam", from: 0, to: 30)])
        #expect(chosen?.title == "1:1 with Sam")
    }

    @Test func joiningEarlyCountsWithinTheLeadTime() {
        #expect(matcher.meeting(at: noon, among: [event("Design review", from: 8, to: 60)])?.title == "Design review")
        #expect(matcher.meeting(at: noon, among: [event("Design review", from: 12, to: 60)]) == nil)
    }

    @Test func runningOverCountsWithinTheTolerance() {
        #expect(matcher.meeting(at: noon, among: [event("Retro", from: -60, to: -10)])?.title == "Retro")
        #expect(matcher.meeting(at: noon, among: [event("Retro", from: -60, to: -20)]) == nil)
    }

    @Test func theNearestMeetingWinsWhenNothingIsOn() {
        // Ended 5 minutes ago versus starting in 8: the one just finished is closer.
        let chosen = matcher.meeting(at: noon, among: [event("Just finished", from: -30, to: -5), event("About to start", from: 8, to: 30)])
        #expect(chosen?.title == "Just finished")
    }

    @Test func allDayDeclinedAndUntitledEventsNeverCount() {
        let events = [
            event("Company holiday", from: -720, to: 720, allDay: true),
            event("Declined sync", from: -5, to: 25, declined: true),
            event("   ", from: -5, to: 25),
        ]
        #expect(matcher.meeting(at: noon, among: events) == nil)
    }

    @Test func theFetchWindowCoversBothTolerances() {
        let window = matcher.fetchWindow(around: noon)
        #expect(window.start == noon.addingTimeInterval(-15 * 60))
        #expect(window.end == noon.addingTimeInterval(10 * 60))
    }
}

// MARK: - Service

@Suite @MainActor struct CalendarMeetingServiceTests {
    @Test func nothingIsReadOrAskedUntilThePersonTurnsItOn() async throws {
        let (settings, cleanup) = try makeSettings()
        defer { cleanup() }
        let provider = FakeCalendarProvider(status: .notDetermined, statusAfterRequest: .granted, events: [event("Standup", from: -5, to: 25)])
        let service = CalendarMeetingService(settings: settings, provider: provider, now: { noon })

        #expect(settings.useCalendarMeetingNames == false)
        #expect(service.isActive == false)
        #expect(await service.suggestedRecordingTitle(at: noon) == nil)
        #expect(provider.requestCount == 0)
        #expect(provider.readCount == 0)
    }

    @Test func turningItOnAsksForAccessAndThenNamesTheMeeting() async throws {
        let (settings, cleanup) = try makeSettings()
        defer { cleanup() }
        let provider = FakeCalendarProvider(status: .notDetermined, statusAfterRequest: .granted, events: [event("Standup", from: -5, to: 25)])
        let service = CalendarMeetingService(settings: settings, provider: provider, now: { noon })

        await service.setEnabled(true)

        #expect(provider.requestCount == 1)
        #expect(service.accessStatus == .granted)
        #expect(settings.useCalendarMeetingNames)
        #expect(service.currentMeeting?.title == "Standup")
        #expect(await service.suggestedRecordingTitle(at: noon) == "Standup")
    }

    @Test func aRefusalLeavesTheSwitchOnButNamesNothing() async throws {
        let (settings, cleanup) = try makeSettings()
        defer { cleanup() }
        let provider = FakeCalendarProvider(status: .notDetermined, statusAfterRequest: .denied, events: [event("Standup", from: -5, to: 25)])
        let service = CalendarMeetingService(settings: settings, provider: provider, now: { noon })

        await service.setEnabled(true)

        #expect(settings.useCalendarMeetingNames)
        #expect(service.accessStatus == .denied)
        #expect(service.isActive == false)
        #expect(await service.suggestedRecordingTitle(at: noon) == nil)
        #expect(service.statusMessage.contains("System Settings"))
    }

    @Test func turningItOffStopsNamingWithoutRevokingAnything() async throws {
        let (settings, cleanup) = try makeSettings()
        defer { cleanup() }
        let provider = FakeCalendarProvider(status: .granted, events: [event("Standup", from: -5, to: 25)])
        let service = CalendarMeetingService(settings: settings, provider: provider, now: { noon })
        await service.setEnabled(true)
        #expect(await service.suggestedRecordingTitle(at: noon) == "Standup")

        await service.setEnabled(false)

        #expect(await service.suggestedRecordingTitle(at: noon) == nil)
        #expect(service.currentMeeting == nil)
        #expect(service.accessStatus == .granted)
    }

    @Test func theChoiceSurvivesARelaunch() throws {
        let suiteName = "CalendarMeetingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let folder = FileManager.default.temporaryDirectory

        let firstLaunch = ScribeSettings(defaults: defaults, defaultRecordingsFolderURL: folder)
        #expect(firstLaunch.useCalendarMeetingNames == false)
        firstLaunch.useCalendarMeetingNames = true

        let secondLaunch = ScribeSettings(defaults: defaults, defaultRecordingsFolderURL: folder)
        #expect(secondLaunch.useCalendarMeetingNames)
    }
}

// MARK: - Detection

@Suite @MainActor struct DetectedMeetingCalendarTitleTests {
    @Test func aDetectedCallPrefersItsCalendarName() {
        let zoom = MeetingApplication.catalog.first { $0.id == "zoom" }!
        let unnamed = DetectedMeeting(application: zoom, bundleIdentifier: "us.zoom.xos", processIdentifier: 1, domain: nil, detectedAt: noon)
        let named = DetectedMeeting(application: zoom, bundleIdentifier: "us.zoom.xos", processIdentifier: 1, domain: nil, detectedAt: noon, calendarTitle: "Standup")

        #expect(unnamed.preferredName == "Zoom")
        #expect(named.preferredName == "Standup")
        #expect(named.displayName == "Zoom")
    }
}
