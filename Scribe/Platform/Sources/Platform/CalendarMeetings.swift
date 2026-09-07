import AppKit
import EventKit
import Foundation
import os

// MARK: - Events

/// One calendar event, reduced to what naming a recording needs.
public struct CalendarEvent: Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let startDate: Date
    public let endDate: Date
    public let calendarTitle: String
    public let isAllDay: Bool
    /// The person declined the invitation. A meeting they are not in is not
    /// the one they are recording.
    public let isDeclined: Bool

    public init(id: String, title: String, startDate: Date, endDate: Date, calendarTitle: String, isAllDay: Bool = false, isDeclined: Bool = false) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.calendarTitle = calendarTitle
        self.isAllDay = isAllDay
        self.isDeclined = isDeclined
    }

    public var duration: TimeInterval { endDate.timeIntervalSince(startDate) }

    public func isInProgress(at date: Date) -> Bool {
        startDate <= date && date < endDate
    }
}

/// Whether Scribe may read the person's calendars.
///
/// macOS 14 split calendar access into write-only and full; only full access
/// can read event titles, so write-only is reported as denied.
public enum CalendarAccessStatus: Equatable, Sendable {
    case notDetermined
    case granted
    case denied
    /// Parental controls or a device profile forbid it; asking cannot help.
    case restricted

    public var isGranted: Bool { self == .granted }
}

/// Reads events from the operating system's calendar store.
///
/// Behind a protocol so the naming rules can be exercised with a fixed set of
/// events and without a Calendar permission prompt.
public protocol CalendarEventProviding: Sendable {
    func accessStatus() -> CalendarAccessStatus
    /// Shows the system prompt when it is still available, then reports the
    /// resulting status. macOS does not re-prompt after a refusal.
    func requestAccess() async -> CalendarAccessStatus
    /// Events overlapping the window, from every calendar. Empty when access
    /// is missing or the store cannot be read.
    func events(from start: Date, to end: Date) async -> [CalendarEvent]
}

// MARK: - Matching

/// Chooses which calendar event a recording that starts now is for.
///
/// The rules are plain values so they can be asserted without a calendar:
/// a meeting counts from a little before its start, because people dial in
/// early, and for a while after its end, because meetings run over. Among
/// meetings in progress the one that began most recently wins, so a short call
/// inside a long "focus" block is named after the call. All-day events and
/// declined invitations never count.
public struct CalendarMeetingMatcher: Sendable {
    /// How early a meeting may be joined and still count.
    public let leadTime: TimeInterval
    /// How long past its scheduled end a meeting still counts.
    public let overrunTolerance: TimeInterval

    public init(leadTime: TimeInterval = 10 * 60, overrunTolerance: TimeInterval = 15 * 60) {
        self.leadTime = leadTime
        self.overrunTolerance = overrunTolerance
    }

    /// The window of events worth fetching for a decision at `date`.
    public func fetchWindow(around date: Date) -> (start: Date, end: Date) {
        (date.addingTimeInterval(-overrunTolerance), date.addingTimeInterval(leadTime))
    }

    public func meeting(at date: Date, among events: [CalendarEvent]) -> CalendarEvent? {
        let eligible = events.filter { event in
            !event.isAllDay && !event.isDeclined
                && !event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && event.endDate > event.startDate
        }

        let inProgress = eligible.filter { $0.isInProgress(at: date) }
        if let current = inProgress.max(by: { lhs, rhs in
            if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
            // Same start: prefer the shorter, which is the more specific one.
            return lhs.duration > rhs.duration
        }) {
            return current
        }

        // Nothing is on right now. The nearest meeting by clock distance wins,
        // whether it is about to start or just finished.
        let nearby = eligible.compactMap { event -> (event: CalendarEvent, distance: TimeInterval)? in
            if event.startDate > date {
                let untilStart = event.startDate.timeIntervalSince(date)
                return untilStart <= leadTime ? (event, untilStart) : nil
            }
            let sinceEnd = date.timeIntervalSince(event.endDate)
            return sinceEnd <= overrunTolerance ? (event, sinceEnd) : nil
        }
        return nearby.min { lhs, rhs in
            if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
            return lhs.event.startDate < rhs.event.startDate
        }?.event
    }
}

// MARK: - Title provider

/// Suggests a name for a recording that starts at a given moment.
///
/// The recorder asks this once per start, so a recording begun from the menu,
/// a shortcut, or the meeting chip is named the same way.
public protocol RecordingTitleProviding: Sendable {
    func suggestedRecordingTitle(at date: Date) async -> String?
}

// MARK: - Service

/// The connection between Scribe and the person's calendars.
///
/// Owns the permission state Settings shows, answers "which meeting is on
/// right now" for the recorder and the meeting chip, and does nothing at all
/// until the person turns the feature on: no prompt, no calendar read.
@MainActor
public final class CalendarMeetingService: ObservableObject {
    @Published public private(set) var accessStatus: CalendarAccessStatus
    /// The meeting the next recording would be named after, for Settings to
    /// show. Refreshed on demand rather than polled.
    @Published public private(set) var currentMeeting: CalendarEvent?

    public let matcher: CalendarMeetingMatcher
    private let settings: ScribeSettings
    private let provider: any CalendarEventProviding
    private let now: @MainActor () -> Date
    private let logger = Logger(subsystem: "com.scribe.app", category: "CalendarMeetings")

    public init(
        settings: ScribeSettings,
        provider: any CalendarEventProviding = EventKitCalendarEventProvider(),
        matcher: CalendarMeetingMatcher = CalendarMeetingMatcher(),
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.settings = settings
        self.provider = provider
        self.matcher = matcher
        self.now = now
        accessStatus = provider.accessStatus()
    }

    /// Names are used only when the person opted in and macOS allows reading.
    public var isActive: Bool { settings.useCalendarMeetingNames && accessStatus.isGranted }

    /// Turns the feature on or off. Turning it on asks macOS for access when
    /// that question has not been answered yet; a refusal leaves the switch on
    /// with the System Settings route shown beside it.
    public func setEnabled(_ enabled: Bool) async {
        settings.useCalendarMeetingNames = enabled
        guard enabled else {
            currentMeeting = nil
            return
        }
        await connect()
    }

    /// Requests access if still possible and reads the current meeting.
    public func connect() async {
        accessStatus = await provider.requestAccess()
        logger.info("Calendar access: \(String(describing: self.accessStatus), privacy: .public)")
        await refreshCurrentMeeting()
    }

    /// Re-reads the permission after returning from System Settings.
    public func refreshAccessStatus() {
        accessStatus = provider.accessStatus()
    }

    public func openSystemSettings() {
        NSWorkspace.shared.open(Self.systemSettingsURL)
    }

    public static let systemSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!

    /// Updates `currentMeeting` for Settings.
    public func refreshCurrentMeeting() async {
        currentMeeting = await meeting(at: now())
    }

    /// The meeting a recording starting at `date` is for, or `nil` when the
    /// feature is off, access is missing, or nothing is on.
    public func meeting(at date: Date) async -> CalendarEvent? {
        guard isActive else { return nil }
        let window = matcher.fetchWindow(around: date)
        let events = await provider.events(from: window.start, to: window.end)
        return matcher.meeting(at: date, among: events)
    }

    /// What Settings says under the switch.
    public var statusMessage: String {
        switch accessStatus {
        case .granted:
            "Scribe can read your calendars."
        case .notDetermined:
            "Scribe will ask for calendar access when this is turned on."
        case .denied:
            "Calendar access was declined. Allow Scribe under System Settings › Privacy & Security › Calendars."
        case .restricted:
            "Calendar access is restricted on this Mac."
        }
    }
}

extension CalendarMeetingService: RecordingTitleProviding {
    public func suggestedRecordingTitle(at date: Date) async -> String? {
        await meeting(at: date)?.title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - EventKit

/// Reads the person's calendars through EventKit.
///
/// One store for the life of the app: creating an `EKEventStore` is not
/// cheap, and its permission state is process-wide anyway.
public final class EventKitCalendarEventProvider: CalendarEventProviding, @unchecked Sendable {
    private let store = EKEventStore()

    public init() {}

    public func accessStatus() -> CalendarAccessStatus {
        Self.status(EKEventStore.authorizationStatus(for: .event))
    }

    public func requestAccess() async -> CalendarAccessStatus {
        guard accessStatus() == .notDetermined else { return accessStatus() }
        do {
            _ = try await store.requestFullAccessToEvents()
        } catch {
            // The status below says what happened; the error adds nothing.
        }
        return accessStatus()
    }

    public func events(from start: Date, to end: Date) async -> [CalendarEvent] {
        guard accessStatus().isGranted else { return [] }
        let store = self.store
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).compactMap { event in
            guard event.status != .canceled, let start = event.startDate, let end = event.endDate else { return nil }
            let declined = event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
            return CalendarEvent(
                id: event.eventIdentifier ?? UUID().uuidString,
                title: event.title ?? "",
                startDate: start,
                endDate: end,
                calendarTitle: event.calendar?.title ?? "",
                isAllDay: event.isAllDay,
                isDeclined: declined
            )
        }
    }

    private static func status(_ status: EKAuthorizationStatus) -> CalendarAccessStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .fullAccess: .granted
        case .restricted: .restricted
        case .denied, .writeOnly: .denied
        @unknown default: .denied
        }
    }
}
