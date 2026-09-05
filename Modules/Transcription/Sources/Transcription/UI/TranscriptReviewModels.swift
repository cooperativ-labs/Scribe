import AVFoundation
import Foundation
import Speakers

/// The state shown for an imported source while no production job coordinator is attached.
///
/// This deliberately models the states the eventual coordinator owns so fixture-backed UI has
/// the same presentation contract as a live job.
public enum TranscriptJobState: Equatable, Sendable {
    case ready
    case queued
    case processing(progress: Double?)
    case complete
    case completeWithWarnings
    case noSpeech
    case failed(message: String)

    public var displayName: String {
        switch self {
        case .ready: "Ready"
        case .queued: "Queued"
        case .processing: "Processing"
        case .complete: "Complete"
        case .completeWithWarnings: "Complete with warnings"
        case .noSpeech: "No speech"
        case .failed: "Failed"
        }
    }

    public var progress: Double? {
        guard case .processing(let progress) = self else { return nil }
        return progress
    }

    public var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// A transcript together with the immutable source copy used to validate it during review.
public struct TranscriptReviewFile: Identifiable, Equatable, Sendable {
    public let id: String
    public let sourceSnapshotURL: URL
    public let transcript: CanonicalTranscript?
    public let jobState: TranscriptJobState
    public let processingError: String?
    /// Matches that scored too low to name automatically and await confirmation.
    public var suggestions: [TranscriptSpeakerSuggestion]

    public init(
        id: String? = nil,
        sourceSnapshotURL: URL,
        transcript: CanonicalTranscript?,
        jobState: TranscriptJobState,
        processingError: String? = nil,
        suggestions: [TranscriptSpeakerSuggestion] = []
    ) {
        self.id = id ?? transcript?.transcriptID ?? sourceSnapshotURL.absoluteString
        self.sourceSnapshotURL = sourceSnapshotURL
        self.transcript = transcript
        self.jobState = jobState
        self.processingError = processingError
        self.suggestions = suggestions
    }

    public var filename: String {
        transcript?.source.filename ?? sourceSnapshotURL.lastPathComponent
    }

    /// Replaces the stored transcript with a newer revision, keeping identity and job state.
    public func replacingTranscript(_ transcript: CanonicalTranscript) -> TranscriptReviewFile {
        TranscriptReviewFile(
            id: id,
            sourceSnapshotURL: sourceSnapshotURL,
            transcript: transcript,
            jobState: jobState,
            processingError: processingError,
            suggestions: suggestions
        )
    }
}

/// What playback reports back to review as the source plays.
public enum TranscriptPlaybackEvent: Equatable, Sendable {
    /// The play head moved; sent repeatedly while playing.
    case timeChanged(milliseconds: Int)
    /// The source ran out, so playback stopped on its own.
    case ended
}

/// Playback is injected so review remains testable and does not depend on the job pipeline.
///
/// Transport control and progress reporting have default no-op implementations so a
/// seek-only test double still satisfies the contract.
@MainActor
public protocol TranscriptPlaybackSeeking: AnyObject {
    func load(sourceSnapshotURL: URL)
    func seek(toMilliseconds milliseconds: Int)
    func play()
    func pause()
    /// Registers the single observer that receives progress and end-of-source events.
    func setPlaybackObserver(_ observer: (@MainActor (TranscriptPlaybackEvent) -> Void)?)
}

public extension TranscriptPlaybackSeeking {
    func play() {}
    func pause() {}
    func setPlaybackObserver(_: (@MainActor (TranscriptPlaybackEvent) -> Void)?) {}
}

/// AVFoundation-backed playback of the source snapshot retained with a transcript.
@MainActor
public final class AVFoundationTranscriptPlayback: TranscriptPlaybackSeeking {
    public let player: AVPlayer
    private var loadedURL: URL?
    private var observer: (@MainActor (TranscriptPlaybackEvent) -> Void)?
    private var timeObserverToken: Any?
    private var endObserverToken: (any NSObjectProtocol)?

    public init(player: AVPlayer = AVPlayer()) {
        self.player = player
        // Seeking between spoken turns must land exactly where the transcript says,
        // so the player is not allowed to trade accuracy for a faster start.
        player.automaticallyWaitsToMinimizeStalling = false
    }

    public func load(sourceSnapshotURL: URL) {
        guard loadedURL != sourceSnapshotURL else { return }
        loadedURL = sourceSnapshotURL
        player.replaceCurrentItem(with: AVPlayerItem(url: sourceSnapshotURL))
        observeEndOfCurrentItem()
    }

    public func seek(toMilliseconds milliseconds: Int) {
        player.seek(
            to: CMTime(value: CMTimeValue(milliseconds), timescale: 1_000),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    public func play() { player.play() }

    public func pause() { player.pause() }

    public func setPlaybackObserver(_ observer: (@MainActor (TranscriptPlaybackEvent) -> Void)?) {
        self.observer = observer
        if let timeObserverToken {
            player.removeTimeObserver(timeObserverToken)
            self.timeObserverToken = nil
        }
        guard observer != nil else { return }
        // A tenth of a second is fine enough that the current-speaker readout
        // changes on the turn boundary rather than visibly after it.
        let interval = CMTime(value: 1, timescale: 10)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard time.isNumeric else { return }
            let milliseconds = Int((time.seconds * 1_000).rounded())
            MainActor.assumeIsolated {
                self?.observer?(.timeChanged(milliseconds: milliseconds))
            }
        }
    }

    private func observeEndOfCurrentItem() {
        if let endObserverToken {
            NotificationCenter.default.removeObserver(endObserverToken)
        }
        endObserverToken = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.observer?(.ended)
            }
        }
    }
}

public struct TranscriptExportOutcome: Identifiable, Equatable, Sendable {
    public let format: TranscriptExportFormat
    public let destinationURL: URL?
    public let errorMessage: String?

    public var id: TranscriptExportFormat { format }
    public var succeeded: Bool { destinationURL != nil && errorMessage == nil }

    public init(format: TranscriptExportFormat, destinationURL: URL?, errorMessage: String?) {
        self.format = format
        self.destinationURL = destinationURL
        self.errorMessage = errorMessage
    }
}

/// Writes individual export formats independently, retaining successes when one format fails.
public protocol TranscriptExportWriting: Sendable {
    func write(
        _ transcript: CanonicalTranscript,
        formats: Set<TranscriptExportFormat>,
        to directoryURL: URL
    ) -> [TranscriptExportOutcome]
}

public struct FileTranscriptExportWriter: TranscriptExportWriting {
    public init() {}

    public func write(
        _ transcript: CanonicalTranscript,
        formats: Set<TranscriptExportFormat>,
        to directoryURL: URL
    ) -> [TranscriptExportOutcome] {
        let basename = (transcript.source.filename as NSString).deletingPathExtension

        return TranscriptExportFormat.allCases.compactMap { format in
            guard formats.contains(format) else { return nil }
            let destination = directoryURL.appendingPathComponent(basename).appendingPathExtension(format.fileExtension)

            do {
                let data = try TranscriptExporter.export(transcript, as: format)
                try data.write(to: destination, options: .atomic)
                return TranscriptExportOutcome(format: format, destinationURL: destination, errorMessage: nil)
            } catch {
                return TranscriptExportOutcome(format: format, destinationURL: nil, errorMessage: error.localizedDescription)
            }
        }
    }
}

/// Persists a revision produced in the review window.
///
/// Relabelling is an edit to a saved transcript, so it belongs on disk beside
/// the revision it supersedes rather than only in the window that made it. The
/// protocol keeps the transcript store out of the view model, which still works
/// against fixtures with no store attached.
public protocol TranscriptRevisionStoring: Sendable {
    func save(_ transcript: CanonicalTranscript, forFileID fileID: TranscriptReviewFile.ID) throws
}

/// Removes a reviewed file from wherever the host keeps it.
///
/// Deleting is the one review action that discards data rather than adding a
/// revision, so it stays behind its own contract: a fixture-backed window with
/// no deleter attached simply removes the row from the list.
public protocol TranscriptFileDeleting: Sendable {
    func delete(fileID: TranscriptReviewFile.ID) throws
}
