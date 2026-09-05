import AVFAudio
import FLACBridge
import Foundation
import ScribeAppCore

/// Produces the two archival FLAC exports before any echo cancellation or mixdown.
///
/// The capture archive remains authoritative: it is opened through
/// ``TimelineBuilder`` only, never modified. A stable capture format is retained
/// in its original rate and layout; a journaled format transition instead selects
/// the documented 48 kHz timeline format and records that decision in the
/// manifest. `FLACEncoder` writes each file to a same-directory temporary name,
/// decodes it to verify the integer payload, and only then renames it into place.
public struct UnprocessedFLACExporter: Sendable {
    public static let journalReference = "capture/timeline.jsonl"
    public static let canonicalSampleRate = timelineSampleRate

    public init() {}

    /// Exports every capture track present in `sessionDirectory` and atomically
    /// updates `metadata.json` after both verified files are available.
    @discardableResult
    public func export(sessionDirectory: URL) throws -> UnprocessedFLACExportResult {
        let builder = try TimelineBuilder.plan(sessionDirectory: sessionDirectory)
        let manifestURL = sessionDirectory.appendingPathComponent("metadata.json")
        let manifest = try RecorderSessionManifestCodec.decode(Data(contentsOf: manifestURL))

        var exports: [RecorderTrackKind: UnprocessedTrackExport] = [:]
        for kind in [RecorderTrackKind.system, .microphone] {
            guard let track = builder.timeline.track(kind) else { continue }
            exports[kind] = try export(track: track, with: builder, into: sessionDirectory)
        }

        let updated = updatedManifest(manifest, timeline: builder.timeline, exports: exports)
        try AtomicReplaceFileWriter().write(updated, to: manifestURL)
        return UnprocessedFLACExportResult(timeline: builder.timeline, tracks: exports, manifest: updated)
    }

    private func export(track: TrackTimeline, with builder: TimelineBuilder, into directory: URL) throws -> UnprocessedTrackExport {
        let format = exportFormat(for: track)
        let fileName = "\(track.track.rawValue).flac"
        let encoder = try FLACEncoder(
            outputURL: directory.appendingPathComponent(fileName),
            configuration: FLACEncoderConfiguration(sampleRate: format.sampleRate, channelCount: format.channelCount, bitDepth: .bits24)
        )
        guard let reader = try builder.makeReader(for: track.track) else { throw UnprocessedFLACExporterError.missingReader(track.track) }

        // The timeline is always 48 kHz float PCM. Converting back to a stable
        // source rate preserves that rate in the archival export while keeping its
        // offsets and journaled silence on one absolute session timeline.
        let resampler = SincResampler(
            inputSampleRate: timelineSampleRate,
            outputSampleRate: format.sampleRate,
            channelCount: format.channelCount
        )
        let pcmFormat = try outputPCMFormat(sampleRate: format.sampleRate, channelCount: format.channelCount)

        while let block = try reader.read() {
            let source = normalizedChannels(block.channels, channelCount: format.channelCount)
            let output = resampler.process(source)
            try write(output, format: pcmFormat, to: encoder)
        }
        // The final call supplies the sinc tail with silence, which is the only
        // content valid after a journaled run or at the end of a capture.
        let tail = resampler.process(Array(repeating: [], count: format.channelCount), isFinal: true)
        try write(tail, format: pcmFormat, to: encoder)

        let encoded = try encoder.finish()
        let expectedFrames = Int64((Double(track.outputFrameCount) * Double(format.sampleRate) / Double(timelineSampleRate)).rounded())
        guard encoded.frameCount == expectedFrames else {
            throw UnprocessedFLACExporterError.durationMismatch(track: track.track, expectedFrames: expectedFrames, actualFrames: encoded.frameCount)
        }
        return UnprocessedTrackExport(
            track: track.track,
            fileName: fileName,
            format: format,
            firstTimestampSeconds: track.firstTimestamp.seconds,
            result: encoded
        )
    }

    private func exportFormat(for track: TrackTimeline) -> UnprocessedExportFormat {
        let nativeRates = Set(track.runs.map { $0.format.sampleRate })
        let nativeChannels = Set(track.runs.map { $0.format.channelCount })
        let changedFormat = nativeRates.count != 1 || nativeChannels.count != 1
        // Built-in microphone arrays can surface as an unlabeled three-channel
        // stream. AudioToolbox cannot construct the PCM format its FLAC encoder
        // requires for that layout, and the recorder does not know enough about
        // the unlabeled channels to assign a meaningful surround layout. Preserve
        // the native channels in the authoritative CAF archive and publish the
        // unprocessed convenience export as mono, which is also the exact signal
        // shape consumed by delay estimation and echo cancellation.
        if track.track == .microphone, track.channelCount != 1 {
            return UnprocessedExportFormat(
                sampleRate: changedFormat ? Self.canonicalSampleRate : track.nativeFormat.sampleRate,
                channelCount: 1,
                canonicalBecause: "multi-channel microphone downmixed to mono; native channels retained in capture archive"
            )
        }
        if changedFormat {
            return UnprocessedExportFormat(
                sampleRate: Self.canonicalSampleRate,
                channelCount: track.channelCount,
                canonicalBecause: "journaled format transition; canonical 48000 Hz timeline export"
            )
        }
        return UnprocessedExportFormat(
            sampleRate: track.nativeFormat.sampleRate,
            channelCount: track.nativeFormat.channelCount,
            canonicalBecause: nil
        )
    }

    private func outputPCMFormat(sampleRate: Int, channelCount: Int) throws -> AVAudioFormat {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(channelCount),
            interleaved: false
        ) else { throw UnprocessedFLACExporterError.invalidOutputFormat(sampleRate: sampleRate, channelCount: channelCount) }
        return format
    }

    private func normalizedChannels(_ channels: [[Float]], channelCount: Int) -> [[Float]] {
        guard channelCount > 0 else { return [] }
        if channelCount == 1, channels.count > 1 {
            guard let first = channels.first else { return [[]] }
            var mono = first
            for channel in channels.dropFirst() {
                for frame in 0..<min(mono.count, channel.count) {
                    mono[frame] += channel[frame]
                }
            }
            let scale = 1 / Float(channels.count)
            for frame in mono.indices { mono[frame] *= scale }
            return [mono]
        }
        if channels.count > channelCount {
            return Array(channels.prefix(channelCount))
        }
        guard channels.count < channelCount, let last = channels.last else { return channels }
        return channels + Array(repeating: last, count: channelCount - channels.count)
    }

    private func write(_ samples: [[Float]], format: AVAudioFormat, to encoder: FLACEncoder) throws {
        guard let frames = samples.first?.count, frames > 0 else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            throw UnprocessedFLACExporterError.bufferAllocationFailed
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<samples.count {
            samples[channel].withUnsafeBufferPointer { source in
                buffer.floatChannelData![channel].initialize(from: source.baseAddress!, count: frames)
            }
        }
        try encoder.write(buffer)
    }

    private func updatedManifest(
        _ manifest: RecorderSessionManifest,
        timeline: SessionTimeline,
        exports: [RecorderTrackKind: UnprocessedTrackExport]
    ) -> RecorderSessionManifest {
        let system = exports[.system].map(trackManifest)
        let microphone = exports[.microphone].map(trackManifest)
        var configuration = timeline.manifestConfiguration
        configuration["unprocessedFLAC"] = .object(Dictionary(uniqueKeysWithValues: exports.values.map { export in
            let sourceFormats = timeline.track(export.track)?.runs.map { run in
                ManifestJSONValue.object([
                    "sampleRate": .number(Double(run.format.sampleRate)),
                    "channelCount": .number(Double(run.format.channelCount)),
                    "bitsPerChannel": .number(Double(run.format.bitsPerChannel)),
                    "isFloat": .boolean(run.format.isFloat),
                    "description": .string(run.format.description),
                ])
            } ?? []
            let details: [String: ManifestJSONValue] = [
                "file": .string(export.fileName),
                "sampleRate": .number(Double(export.format.sampleRate)),
                "channelCount": .number(Double(export.format.channelCount)),
                "bitDepth": .number(Double(export.result.bitDepth.rawValue)),
                "durationSeconds": .number(export.result.duration),
                "journalReference": .string(Self.journalReference),
                "canonicalFormatReason": export.format.canonicalBecause.map(ManifestJSONValue.string) ?? .null,
                // Keep every journaled source format too: a canonical export does
                // not erase the archive's actual transitions.
                "sourceFormats": .array(sourceFormats),
            ]
            return (export.track.rawValue, .object(details))
        }))
        let processing = ProcessingMetadata(
            state: manifest.processing.state,
            dependencyVersions: manifest.processing.dependencyVersions.merging(["FLACBridge": "system-audiotoolbox-verified"]) { current, _ in current },
            configuration: configuration,
            resamplingCorrections: timeline.resamplingCorrections,
            delayCorrections: manifest.processing.delayCorrections,
            mixGains: manifest.processing.mixGains,
            errors: manifest.processing.errors
        )
        return RecorderSessionManifest(
            schemaVersion: manifest.schemaVersion,
            sessionID: manifest.sessionID,
            appBuild: manifest.appBuild,
            macOSVersion: manifest.macOSVersion,
            startedAt: manifest.startedAt,
            endedAt: manifest.endedAt,
            durationSeconds: manifest.durationSeconds,
            completionStatus: manifest.completionStatus,
            capture: manifest.capture,
            tracks: RecorderTrackCollection(system: system, microphone: microphone, finalTrack: manifest.tracks.finalTrack),
            gaps: manifest.gaps,
            interruptions: manifest.interruptions,
            processing: processing
        )
    }

    private func trackManifest(_ export: UnprocessedTrackExport) -> RecorderTrackManifest {
        RecorderTrackManifest(
            sourceFormat: AudioSourceFormat(
                sampleRate: Double(export.format.sampleRate),
                channelCount: export.format.channelCount,
                formatDescription: export.format.canonicalBecause ?? "preserved stable capture format; 24-bit FLAC"
            ),
            firstMediaTimestampSeconds: export.firstTimestampSeconds,
            frameCount: export.result.frameCount,
            fileName: export.fileName,
            checksum: export.result.sha256,
            journalReference: Self.journalReference
        )
    }
}

public struct UnprocessedExportFormat: Sendable, Equatable {
    public let sampleRate: Int
    public let channelCount: Int
    /// Non-nil only when a journaled transition requires the canonical export.
    public let canonicalBecause: String?
}

public struct UnprocessedTrackExport: Sendable, Equatable {
    public let track: RecorderTrackKind
    public let fileName: String
    public let format: UnprocessedExportFormat
    public let firstTimestampSeconds: Double
    public let result: FLACEncodeResult
}

public struct UnprocessedFLACExportResult: Sendable, Equatable {
    public let timeline: SessionTimeline
    public let tracks: [RecorderTrackKind: UnprocessedTrackExport]
    public let manifest: RecorderSessionManifest
}

public enum UnprocessedFLACExporterError: Error, Equatable, CustomStringConvertible {
    case missingReader(RecorderTrackKind)
    case invalidOutputFormat(sampleRate: Int, channelCount: Int)
    case bufferAllocationFailed
    case durationMismatch(track: RecorderTrackKind, expectedFrames: Int64, actualFrames: Int64)

    public var description: String {
        switch self {
        case .missingReader(let track): return "no reconstructed reader for \(track.rawValue)"
        case .invalidOutputFormat(let rate, let channels): return "cannot create \(rate) Hz / \(channels) channel PCM"
        case .bufferAllocationFailed: return "could not allocate output PCM buffer"
        case let .durationMismatch(track, expected, actual): return "\(track.rawValue) export has \(actual) frames; expected \(expected)"
        }
    }
}
