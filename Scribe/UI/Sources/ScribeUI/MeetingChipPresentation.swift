import Foundation
import Platform

/// Everything the meeting chip shows, derived from one detected call and one
/// recorder snapshot at one instant.
///
/// The chip is the only part of Scribe that speaks first, so what it may say
/// and when is kept as a plain value: every state — including the ones that
/// exist for a moment, like the pause between pressing Record and capture
/// actually starting — can be produced and asserted without rendering SwiftUI.
public enum MeetingChipPresentation: Equatable, Sendable {
    case hidden
    /// A call was noticed and nothing is being recorded yet.
    case offer(Offer)
    /// A recording is running that this chip is responsible for.
    case session(Session)

    /// The question, and the call it is about.
    public struct Offer: Equatable, Sendable {
        public let applicationName: String
        /// The website the call was matched on, when it was noticed in a
        /// browser. `nil` for a dedicated calling application.
        public let domain: String?
        /// The calendar meeting on at the time, when the person connected
        /// their calendar and one matched.
        public let meetingTitle: String?

        public init(applicationName: String, domain: String?, meetingTitle: String? = nil) {
            self.applicationName = applicationName
            self.domain = domain
            self.meetingTitle = meetingTitle
        }

        /// "Record “Weekly Sync”?" when the calendar names the meeting, and
        /// "Record this Zoom meeting?" otherwise.
        public var question: String {
            if let meetingTitle { return "Record \u{201C}\(meetingTitle)\u{201D}?" }
            return "Record this \(applicationName) meeting?"
        }

        /// The second line: where the call is. With a calendar name on the
        /// first line the application is worth saying too; without one, only
        /// the website adds anything.
        public var detail: String? {
            switch (meetingTitle, domain) {
            case (nil, nil): nil
            case (nil, let domain?): domain
            case (_, nil): applicationName
            case (_, let domain?): "\(domain) in \(applicationName)"
            }
        }
    }

    /// The transport the chip offers while it owns a recording.
    public struct Session: Equatable, Sendable {
        /// `MM:SS`, or `H:MM:SS` past an hour.
        public let elapsedText: String
        /// The hold button is Resume rather than Pause.
        public let isPaused: Bool
        public let isHoldEnabled: Bool
        public let isStopEnabled: Bool
        /// The meeting's name, when the recording has one.
        public let title: String?

        public init(elapsedText: String, isPaused: Bool, isHoldEnabled: Bool, isStopEnabled: Bool, title: String? = nil) {
            self.elapsedText = elapsedText
            self.isPaused = isPaused
            self.isHoldEnabled = isHoldEnabled
            self.isStopEnabled = isStopEnabled
            self.title = title
        }
    }

    public var isVisible: Bool { self != .hidden }

    /// Derives what the chip shows.
    ///
    /// Two rules decide this. A live capture takes precedence over an offer —
    /// once recording starts the chip becomes the transport for it, so the
    /// person who said yes is never asked again. And the chip stays out of the
    /// way otherwise: no call, a dismissed one, or permissions that would make
    /// Record fail all leave it hidden rather than showing a control that
    /// cannot work.
    ///
    /// - Parameters:
    ///   - startedFromChip: the running capture is the one this chip started.
    ///     Kept separate from the detected call so the transport survives the
    ///     call ending — a person still has to stop the recording.
    public init(
        meeting: DetectedMeeting?,
        snapshot: RecorderSnapshot,
        isOfferDismissed: Bool,
        startedFromChip: Bool,
        at date: Date
    ) {
        let isOffered = meeting != nil && !isOfferDismissed

        if snapshot.state.isCapturing || snapshot.state.isTransitioning {
            // A recording started from the menu, with no call noticed and no
            // offer taken, belongs to the menu. Two transports for one
            // recording, one of them floating over every window, is worse than
            // none.
            guard startedFromChip || isOffered else {
                self = .hidden
                return
            }
            // `.starting` has no activity yet; the clock reads zero rather than
            // the chip flickering between two shapes a moment apart.
            let elapsed = snapshot.state.activity?.elapsed(at: date) ?? 0
            self = .session(Session(
                elapsedText: MenuPresentation.elapsedText(elapsed),
                isPaused: snapshot.state.isPaused,
                isHoldEnabled: snapshot.state.isCapturing,
                isStopEnabled: snapshot.state.isCapturing,
                title: snapshot.state.activity?.title
            ))
            return
        }

        guard let meeting, !isOfferDismissed, snapshot.permissions.isReadyToRecord else {
            self = .hidden
            return
        }
        self = .offer(Offer(applicationName: meeting.application.name, domain: meeting.domain, meetingTitle: meeting.calendarTitle))
    }
}
