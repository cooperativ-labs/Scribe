import Combine
import Foundation
import Platform

/// Drives the meeting chip: what it shows, and what its four buttons do.
///
/// Like `RecorderMenuModel` it never mutates recorder state itself. Every
/// button becomes a `RecordingCommand`, so accepting the offer takes exactly
/// the same serialized route into the coordinator as the menu's Record button
/// or the global shortcut.
@MainActor
public final class MeetingChipModel: ObservableObject {
    @Published public private(set) var presentation: MeetingChipPresentation = .hidden

    private let coordinator: any RecordingCoordinating
    private let now: @MainActor () -> Date
    private let shouldStopWhenMeetingEnds: @MainActor () -> Bool
    private var snapshot: RecorderSnapshot
    private var meeting: DetectedMeeting?
    /// The call whose offer was waved away, remembered so the same call is not
    /// offered again a moment later while the microphone is still open.
    private var dismissedCall: DismissedCall?
    /// The running capture is the one this chip started, which is what keeps
    /// the transport on screen after the call itself has ended.
    private var startedFromChip = false
    private var observation: RecorderObservationToken?
    /// Only ever touched on the main actor; marked so `deinit` may retire it.
    nonisolated(unsafe) private var elapsedTimeTicker: Timer?

    /// One call, identified by what stays constant for its whole life. The
    /// detector keeps a browser call's `detectedAt` across a domain change, so
    /// this survives the tab moving but not the next call.
    private struct DismissedCall: Equatable {
        let applicationID: String
        let detectedAt: Date

        init(_ meeting: DetectedMeeting) {
            applicationID = meeting.application.id
            detectedAt = meeting.detectedAt
        }
    }

    public init(
        coordinator: any RecordingCoordinating,
        shouldStopWhenMeetingEnds: @escaping @MainActor () -> Bool = { false },
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.coordinator = coordinator
        self.shouldStopWhenMeetingEnds = shouldStopWhenMeetingEnds
        self.now = now
        snapshot = coordinator.snapshot
        observation = coordinator.observeSnapshot { [weak self] snapshot in
            guard let self else { return }
            let wasBusy = self.snapshot.state.isCapturing || self.snapshot.state.isTransitioning
            self.snapshot = snapshot
            // The chip's responsibility ends with the recording it started, so a
            // capture that has finished releases it rather than leaving the next
            // manual recording wearing a chip nobody asked for. Only a capture
            // that actually ran counts: pressing Record leaves the recorder idle
            // for the moment it takes the command to reach it.
            if wasBusy, !(snapshot.state.isCapturing || snapshot.state.isTransitioning) {
                self.startedFromChip = false
            }
            refreshPresentation()
        }
        refreshPresentation()
    }

    deinit {
        elapsedTimeTicker?.invalidate()
    }

    /// What the detector found, or `nil` when the call ended.
    public func meetingWasDetected(_ meeting: DetectedMeeting?) {
        let previousCall = self.meeting.map(DismissedCall.init)
        let detectedCall = meeting.map(DismissedCall.init)
        self.meeting = meeting
        // A dismissal covers one call. Anything else arriving — the call ending,
        // or a different one starting — retires it, so the next meeting is
        // offered normally rather than being silently skipped.
        if detectedCall != dismissedCall {
            dismissedCall = nil
        }

        // The detector has already absorbed brief microphone reconnects before
        // publishing an end. A different call also ends the recording tied to
        // the old one, even when both apps overlap for one polling pass.
        if previousCall != nil,
           detectedCall != previousCall,
           startedFromChip,
           shouldStopWhenMeetingEnds() {
            coordinator.submit(.stop)
        }
        refreshPresentation()
    }

    /// Recomputes against the current time. The elapsed timer calls this every
    /// second while a recording runs; tests call it directly with a stubbed clock.
    public func refreshPresentation() {
        let isDismissed = meeting.map { DismissedCall($0) == dismissedCall } ?? false
        presentation = MeetingChipPresentation(
            meeting: meeting,
            snapshot: snapshot,
            isOfferDismissed: isDismissed,
            startedFromChip: startedFromChip,
            at: now()
        )
        updateElapsedTimeTicker()
    }

    // MARK: Commands

    /// Accepts the offer.
    ///
    /// The detected application is selected first, so the recording is scoped to
    /// the call that was noticed rather than to whatever was last chosen in the
    /// menu. It travels as a normal `selectApplication`, which is exactly what
    /// choosing it by hand would have done: the menu and Settings agree with the
    /// chip afterwards instead of disagreeing silently.
    public func record() {
        guard case .offer = presentation, let meeting else { return }
        startedFromChip = true
        coordinator.submit(.selectApplication(meeting.bundleIdentifier))
        coordinator.submit(.start)
        refreshPresentation()
    }

    /// Waves the offer away for this call only.
    public func dismiss() {
        guard let meeting else { return }
        dismissedCall = DismissedCall(meeting)
        refreshPresentation()
    }

    /// The single hold button: Pause while recording, Resume while paused.
    public func toggleHold() {
        guard case .session(let session) = presentation, session.isHoldEnabled else { return }
        coordinator.submit(session.isPaused ? .resume : .pause)
    }

    /// Stops the recording, and takes the question with it.
    ///
    /// A person can stop recording and keep talking, so the call may well still
    /// be running afterwards. Treating the stop as the answer is what stops the
    /// chip from popping straight back up to ask about the same meeting again.
    public func stop() {
        guard case .session(let session) = presentation, session.isStopEnabled else { return }
        coordinator.submit(.stop)
        if let meeting { dismissedCall = DismissedCall(meeting) }
        refreshPresentation()
    }

    // MARK: Elapsed time

    /// The clock runs only while the chip is showing one, so a hidden chip costs
    /// nothing.
    private func updateElapsedTimeTicker() {
        guard case .session = presentation else {
            elapsedTimeTicker?.invalidate()
            elapsedTimeTicker = nil
            return
        }
        guard elapsedTimeTicker == nil else { return }
        // Added to the main run loop, so the block always runs on the main actor.
        // It holds the model weakly and is retired as soon as the chip stops
        // showing a session, which is the only time it can be running.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPresentation() }
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimeTicker = timer
    }
}
