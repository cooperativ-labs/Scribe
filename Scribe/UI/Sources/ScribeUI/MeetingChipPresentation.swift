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

        public init(applicationName: String, domain: String?) {
            self.applicationName = applicationName
            self.domain = domain
        }

        /// "Record this Zoom meeting?"
        public var question: String { "Record this \(applicationName) meeting?" }
    }

    /// The transport the chip offers while it owns a recording.
    public struct Session: Equatable, Sendable {
        /// `MM:SS`, or `H:MM:SS` past an hour.
        public let elapsedText: String
        /// The hold button is Resume rather than Pause.
        public let isPaused: Bool
        public let isHoldEnabled: Bool
        public let isStopEnabled: Bool

        public init(elapsedText: String, isPaused: Bool, isHoldEnabled: Bool, isStopEnabled: Bool) {
            self.elapsedText = elapsedText
            self.isPaused = isPaused
            self.isHoldEnabled = isHoldEnabled
            self.isStopEnabled = isStopEnabled
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
                isStopEnabled: snapshot.state.isCapturing
            ))
            return
        }

        guard let meeting, !isOfferDismissed, snapshot.permissions.isReadyToRecord else {
            self = .hidden
            return
        }
        self = .offer(Offer(applicationName: meeting.application.name, domain: meeting.domain))
    }
}
