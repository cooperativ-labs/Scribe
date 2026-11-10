@preconcurrency import AVFoundation
import Foundation

public enum AudioConcatenationError: LocalizedError, Equatable, Sendable {
    case noAudio(String)
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .noAudio(name): "\(name) has no audio Scribe can read."
        case let .exportFailed(reason): "The recordings could not be joined: \(reason)"
        }
    }
}

/// Writes recordings one after another into a single audio file.
///
/// The recordings are laid end to end on one audio track and written as M4A.
/// When their audio is already in a format M4A can carry as is (Scribe's own
/// recordings are AAC), the samples are copied without re-encoding; otherwise
/// they are encoded to AAC once. Either way this is seconds of work, not a
/// transcription.
public struct AudioConcatenator: Sendable {
    public struct Output: Equatable, Sendable {
        /// Where each input starts in the joined file, in milliseconds.
        public let offsetsMs: [Int]
        public let durationMs: Int
    }

    public init() {}

    /// Joins `inputs` in order into `destination`, which must not exist and
    /// must end in `.m4a`.
    public func concatenate(_ inputs: [URL], to destination: URL) async throws -> Output {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw AudioConcatenationError.exportFailed("no audio track could be created")
        }
        var cursor = CMTime.zero
        var offsets: [Int] = []
        for input in inputs {
            let asset = AVURLAsset(url: input)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first else {
                throw AudioConcatenationError.noAudio(input.lastPathComponent)
            }
            // From time zero, not the track's own start: transcript times are
            // measured from the start of the file, priming included.
            let range = try await source.load(.timeRange)
            let span = CMTimeRange(start: .zero, end: range.end)
            guard span.duration.seconds > 0 else { throw AudioConcatenationError.noAudio(input.lastPathComponent) }
            offsets.append(Self.milliseconds(cursor))
            try track.insertTimeRange(span, of: source, at: cursor)
            cursor = cursor + span.duration
        }

        do {
            try await export(composition, preset: AVAssetExportPresetPassthrough, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            try await export(composition, preset: AVAssetExportPresetAppleM4A, to: destination)
        }
        return Output(offsetsMs: offsets, durationMs: Self.milliseconds(cursor))
    }

    private func export(_ composition: AVComposition, preset: String, to destination: URL) async throws {
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw AudioConcatenationError.exportFailed("this Mac cannot write \(preset)")
        }
        do {
            try await session.export(to: destination, as: .m4a)
        } catch {
            throw AudioConcatenationError.exportFailed(error.localizedDescription)
        }
    }

    private static func milliseconds(_ time: CMTime) -> Int {
        Int((time.seconds * 1_000).rounded())
    }
}
