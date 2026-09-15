import AVFoundation
import Foundation
import ScribeAppCore
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

    /// The name shown for this file: the title a person gave it, or the source
    /// filename until they do.
    public var displayName: String {
        transcript?.title ?? filename
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
    /// Sets the speed later play calls use; 1 is natural speed.
    func setRate(_ rate: Float)
    /// Registers the single observer that receives progress and end-of-source events.
    func setPlaybackObserver(_ observer: (@MainActor (TranscriptPlaybackEvent) -> Void)?)
}

public extension TranscriptPlaybackSeeking {
    func play() {}
    func pause() {}
    func setRate(_: Float) {}
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
    private var rate: Float = 1

    public init(player: AVPlayer = AVPlayer()) {
        self.player = player
        // Seeking between spoken turns must land exactly where the transcript says,
        // so the player is not allowed to trade accuracy for a faster start.
        player.automaticallyWaitsToMinimizeStalling = false
    }

    public func load(sourceSnapshotURL: URL) {
        guard loadedURL != sourceSnapshotURL else { return }
        loadedURL = sourceSnapshotURL
        // Exact seek tolerances alone are not enough: unindexed formats such as
        // FLAC otherwise use approximate byte offsets, even while reporting the
        // requested time. Parse the asset for precise random access first.
        let asset = AVURLAsset(
            url: sourceSnapshotURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        observeEndOfCurrentItem()
    }

    public func seek(toMilliseconds milliseconds: Int) {
        player.seek(
            to: CMTime(value: CMTimeValue(milliseconds), timescale: 1_000),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    /// Plays at the chosen speed. `AVPlayer.play()` would reset to natural
    /// speed, so the rate is set directly.
    public func play() { player.rate = rate }

    public func pause() { player.pause() }

    public func setRate(_ rate: Float) {
        self.rate = rate
        if player.rate != 0 { player.rate = rate }
    }

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
        to directoryURL: URL,
        basename: String
    ) -> [TranscriptExportOutcome]

    func write(
        _ transcript: CanonicalTranscript,
        format: TranscriptExportFormat,
        toFile fileURL: URL
    ) -> TranscriptExportOutcome
}

extension TranscriptExportWriting {
    /// Names files after the transcript when the caller has not chosen a different name.
    public func write(
        _ transcript: CanonicalTranscript,
        formats: Set<TranscriptExportFormat>,
        to directoryURL: URL
    ) -> [TranscriptExportOutcome] {
        write(
            transcript,
            formats: formats,
            to: directoryURL,
            basename: FileTranscriptExportWriter.basename(for: transcript)
        )
    }
}

/// The folder and shared file name implied by a Save panel URL.
public struct TranscriptExportDestination: Equatable, Sendable {
    public let directoryURL: URL
    public let basename: String

    public init(directoryURL: URL, basename: String) {
        self.directoryURL = directoryURL
        self.basename = basename
    }

    /// Treats a Save panel URL as a destination folder plus a name. A known export
    /// extension is stripped so every exported copy can share that name.
    public static func fromSaveURL(_ url: URL) -> TranscriptExportDestination {
        let filename = url.lastPathComponent
        let matchedExtension = TranscriptExportFormat.allCases
            .map(\.fileExtension)
            .sorted { $0.count > $1.count }
            .first { filename.lowercased().hasSuffix("." + $0) }
        let stripped = matchedExtension.map { String(filename.dropLast($0.count + 1)) }
        let basename = stripped.flatMap { $0.isEmpty ? nil : $0 } ?? filename
        return TranscriptExportDestination(directoryURL: url.deletingLastPathComponent(), basename: basename)
    }
}

public struct FileTranscriptExportWriter: TranscriptExportWriting {
    public init() {}

    /// Exports are named after the transcript's title when it has one, with
    /// characters a filesystem rejects replaced, and after the source otherwise.
    public static func basename(for transcript: CanonicalTranscript) -> String {
        if let title = transcript.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            let cleaned = title.map { $0 == "/" || $0 == ":" ? "-" : $0 }
            let name = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        return (transcript.source.filename as NSString).deletingPathExtension
    }

    public func write(
        _ transcript: CanonicalTranscript,
        formats: Set<TranscriptExportFormat>,
        to directoryURL: URL,
        basename: String
    ) -> [TranscriptExportOutcome] {
        TranscriptExportFormat.allCases.compactMap { format in
            guard formats.contains(format) else { return nil }
            let destination = directoryURL.appendingPathComponent(basename).appendingPathExtension(format.fileExtension)
            return write(transcript, format: format, toFile: destination)
        }
    }

    public func write(
        _ transcript: CanonicalTranscript,
        format: TranscriptExportFormat,
        toFile fileURL: URL
    ) -> TranscriptExportOutcome {
        do {
            let data = try TranscriptExporter.export(transcript, as: format)
            try data.write(to: fileURL, options: .atomic)
            return TranscriptExportOutcome(format: format, destinationURL: fileURL, errorMessage: nil)
        } catch {
            return TranscriptExportOutcome(format: format, destinationURL: nil, errorMessage: error.localizedDescription)
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

/// The result of handing dropped files to the host for transcription.
public struct TranscriptImportOutcome: Equatable, Sendable {
    /// One dropped item the host would not queue, with the reason it gave.
    public struct Refusal: Equatable, Sendable {
        public let url: URL
        public let message: String

        public init(url: URL, message: String) {
            self.url = url
            self.message = message
        }
    }

    public let queuedCount: Int
    public let refusals: [Refusal]

    public init(queuedCount: Int, refusals: [Refusal] = []) {
        self.queuedCount = queuedCount
        self.refusals = refusals
    }

    /// One line for the window: how many were queued, and how many were not.
    public var summary: String {
        let queued = "Queued \(queuedCount) file\(queuedCount == 1 ? "" : "s") for transcription"
        guard !refusals.isEmpty else { return queued + "." }
        if queuedCount == 0, refusals.count == 1 { return refusals[0].message }
        return "\(queued); \(refusals.count) could not be queued."
    }

    public var isFailure: Bool { queuedCount == 0 && !refusals.isEmpty }
}

/// Queues files a person dropped on the window for transcription.
///
/// The window only knows file URLs. Probing, snapshotting, and running are the
/// host's business, so the contract returns what happened rather than a job:
/// the list refreshes from the store as the jobs move, the way it does for
/// every other source. A fixture-backed window with no importer attached
/// simply does not accept drops.
public protocol TranscriptFileImporting: Sendable {
    func importFiles(at urls: [URL]) async -> TranscriptImportOutcome
}

/// Starts a new run from a reviewed transcript's retained source. It is kept
/// distinct from revision editing: re-diarization must not overwrite edits to
/// the transcript currently on screen.
public protocol TranscriptReprocessing: Sendable {
    func reprocess(fileID: TranscriptReviewFile.ID, speakerCount: TranscriptionSpeakerCount) async -> TranscriptReprocessingOutcome
}

/// Re-runs recognition and diarization from a retained source using the host's
/// current models and settings. Distinct from speaker-count reprocess, which
/// keeps the prior run's model profile.
public protocol TranscriptRetranscribing: Sendable {
    func retranscribe(fileID: TranscriptReviewFile.ID) async -> TranscriptReprocessingOutcome
}

public struct TranscriptReprocessingOutcome: Equatable, Sendable {
    public let message: String
    public let isFailure: Bool
    /// The new run queued for this action, when queueing succeeded.
    public let queuedRunID: String?

    public init(message: String, isFailure: Bool, queuedRunID: String? = nil) {
        self.message = message
        self.isFailure = isFailure
        self.queuedRunID = queuedRunID
    }
}

/// Phases of the speaker-count reprocess confirmation sheet.
public enum TranscriptReprocessPhase: Equatable, Sendable {
    case confirming
    case queued
    case processing(stageLabel: String, progress: Double)
    case complete
    case failed(message: String)

    public var isTerminal: Bool {
        switch self {
        case .complete, .failed: true
        case .confirming, .queued, .processing: false
        }
    }

    public var isInFlight: Bool {
        switch self {
        case .queued, .processing: true
        case .confirming, .complete, .failed: false
        }
    }
}

/// One deliberate speaker-count reprocess, from confirmation through completion.
public struct TranscriptReprocessSession: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let fileID: TranscriptReviewFile.ID
    public let displayName: String
    public let speakerCount: TranscriptionSpeakerCount
    public var phase: TranscriptReprocessPhase
    /// The run queued after confirmation, used to match coordinator progress events.
    public var queuedRunID: String?

    public init(
        id: UUID = UUID(),
        fileID: TranscriptReviewFile.ID,
        displayName: String,
        speakerCount: TranscriptionSpeakerCount,
        phase: TranscriptReprocessPhase = .confirming,
        queuedRunID: String? = nil
    ) {
        self.id = id
        self.fileID = fileID
        self.displayName = displayName
        self.speakerCount = speakerCount
        self.phase = phase
        self.queuedRunID = queuedRunID
    }

    public var speakerCountDescription: String {
        switch speakerCount {
        case .automatic: "automatic speaker count"
        case .known(let count): "exactly \(count) speaker\(count == 1 ? "" : "s")"
        case .upTo(let count): "up to \(count) speaker\(count == 1 ? "" : "s")"
        }
    }
}
