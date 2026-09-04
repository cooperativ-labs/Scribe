import Foundation

/// The contract implemented by `ProcessingQueue` and consumed by local jobs such
/// as transcription. Capture always has priority over background work.
public protocol ProcessingScheduler: Sendable {
    /// Reports whether a recording is currently active.
    func isCaptureActive() async -> Bool

    /// Requests that a background job be deferred until recording permits it.
    func requestDeferral(for job: ProcessingJobDescriptor) async -> ProcessingJobDeferral

    /// Delivers suspension and resumption requests. Jobs act only at safe boundaries.
    func jobControlSignals(for jobID: UUID) async -> AsyncStream<ProcessingJobControlSignal>
}

public struct ProcessingJobDescriptor: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let kind: String

    public init(id: UUID = UUID(), kind: String) {
        self.id = id
        self.kind = kind
    }
}

public enum ProcessingJobDeferral: String, Codable, Sendable, Equatable {
    case startNow
    case deferUntilCaptureEnds
}

public enum ProcessingJobControlSignal: String, Codable, Sendable, Equatable {
    case suspend
    case resume
}

// MARK: - Transcription producer handoff

public struct TranscriptionRequest: Codable, Sendable, Equatable, Identifiable {
    public let requestID: UUID
    public let sourceURL: URL
    public let languageMode: TranscriptionLanguageMode
    public let expectedLanguage: String?
    public let speakerCount: TranscriptionSpeakerCount
    public let speakerMatching: TranscriptionSpeakerMatching
    public let speakerLibraryRevision: String?
    public let modelProfileID: String
    /// Redirects TXT/JSON/SRT exports only; canonical data stays in the transcript store.
    public let exportDirectory: URL?
    public let provenance: TranscriptionProvenance?

    public var id: UUID { requestID }

    public init(
        requestID: UUID = UUID(),
        sourceURL: URL,
        languageMode: TranscriptionLanguageMode = .automatic,
        expectedLanguage: String? = nil,
        speakerCount: TranscriptionSpeakerCount = .automatic,
        speakerMatching: TranscriptionSpeakerMatching = .enabled,
        speakerLibraryRevision: String? = nil,
        modelProfileID: String,
        exportDirectory: URL? = nil,
        provenance: TranscriptionProvenance? = nil
    ) {
        self.requestID = requestID
        self.sourceURL = sourceURL
        self.languageMode = languageMode
        self.expectedLanguage = expectedLanguage
        self.speakerCount = speakerCount
        self.speakerMatching = speakerMatching
        self.speakerLibraryRevision = speakerLibraryRevision
        self.modelProfileID = modelProfileID
        self.exportDirectory = exportDirectory
        self.provenance = provenance
    }
}

public enum TranscriptionLanguageMode: String, Codable, Sendable, Equatable {
    case automatic
}

public enum TranscriptionSpeakerCount: Sendable, Equatable {
    case automatic
    case known(Int)
}

extension TranscriptionSpeakerCount: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let count = try? container.decode(Int.self) {
            self = .known(count)
        } else if try container.decode(String.self) == "automatic" {
            self = .automatic
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "speakerCount must be automatic or a known count")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .automatic: try container.encode("automatic")
        case .known(let count): try container.encode(count)
        }
    }
}

public enum TranscriptionSpeakerMatching: String, Codable, Sendable, Equatable {
    case enabled
    case disabled
}

public struct TranscriptionProvenance: Codable, Sendable, Equatable {
    public let producerID: String
    public let sessionID: UUID

    public init(producerID: String, sessionID: UUID) {
        self.producerID = producerID
        self.sessionID = sessionID
    }
}

/// The durable handoff point a producer writes finished recordings into, as a
/// consumer sees it.
///
/// The submitting half lives with the recorder's storage; this half is declared
/// here, with the rest of the producer-handoff contract, so neither module has
/// to depend on the other to be built, shipped, or tested.
public protocol TranscriptionHandoffSource: Sendable {
    func pendingRequests() async throws -> [TranscriptionRequest]
    /// Called only once a consumer has taken durable responsibility for a request.
    func claim(_ requestID: UUID) async throws
}

public struct TranscriptionEvent: Codable, Sendable, Equatable {
    public let requestID: UUID
    public let stage: String
    public let progress: TranscriptionProgress?
    public let warning: TranscriptionDiagnostic?
    public let error: TranscriptionDiagnostic?

    public init(requestID: UUID, stage: String, progress: TranscriptionProgress? = nil, warning: TranscriptionDiagnostic? = nil, error: TranscriptionDiagnostic? = nil) {
        self.requestID = requestID
        self.stage = stage
        self.progress = progress
        self.warning = warning
        self.error = error
    }
}

public struct TranscriptionProgress: Codable, Sendable, Equatable {
    public let completedUnits: Int
    public let totalUnits: Int

    public init(completedUnits: Int, totalUnits: Int) {
        self.completedUnits = completedUnits
        self.totalUnits = totalUnits
    }
}

public struct TranscriptionDiagnostic: Codable, Sendable, Equatable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct TranscriptionResult: Codable, Sendable, Equatable {
    public let transcriptID: UUID
    public let revision: Int
    public let canonicalTranscriptURL: URL
    public let status: TranscriptionResultStatus

    public init(transcriptID: UUID, revision: Int, canonicalTranscriptURL: URL, status: TranscriptionResultStatus) {
        self.transcriptID = transcriptID
        self.revision = revision
        self.canonicalTranscriptURL = canonicalTranscriptURL
        self.status = status
    }
}

public enum TranscriptionResultStatus: String, Codable, Sendable, Equatable {
    case complete
    case completeWithWarnings
    case noSpeech
}

// MARK: - Recorder session manifest

/// A versioned recorder-session `metadata.json` manifest.
///
/// Stable consumer fields are `schemaVersion`, `processing.state`, and
/// `tracks.final.checksum` (the checksum for `final.flac`). New schema versions
/// must add fields rather than renaming or changing the meaning of those paths.
public struct RecorderSessionManifest: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    /// Stable consumer field: recognized schema version.
    public let schemaVersion: Int
    public let sessionID: UUID
    public let appBuild: String
    public let macOSVersion: String
    public let startedAt: Date
    public let endedAt: Date?
    public let durationSeconds: TimeInterval?
    public let completionStatus: RecorderSessionCompletionStatus
    public let capture: CaptureMetadata
    public let tracks: RecorderTrackCollection
    public let gaps: [CaptureGap]
    public let interruptions: [CaptureInterruption]
    public let processing: ProcessingMetadata

    public init(schemaVersion: Int = Self.currentSchemaVersion, sessionID: UUID, appBuild: String, macOSVersion: String, startedAt: Date, endedAt: Date? = nil, durationSeconds: TimeInterval? = nil, completionStatus: RecorderSessionCompletionStatus, capture: CaptureMetadata, tracks: RecorderTrackCollection, gaps: [CaptureGap] = [], interruptions: [CaptureInterruption] = [], processing: ProcessingMetadata) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.appBuild = appBuild
        self.macOSVersion = macOSVersion
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.completionStatus = completionStatus
        self.capture = capture
        self.tracks = tracks
        self.gaps = gaps
        self.interruptions = interruptions
        self.processing = processing
    }
}

public enum RecorderSessionCompletionStatus: String, Codable, Sendable, Equatable {
    case complete
    case interrupted
    case failed
}

/// Capture lifecycle is deliberately independent from background processing.
public enum CaptureState: String, Codable, Sendable, Equatable {
    case capturing
    case complete
    case interrupted
}

/// Processing lifecycle is deliberately independent from capture lifecycle.
public enum ProcessingState: String, Codable, Sendable, Equatable {
    case pending
    case running
    case complete
    case failed
}

public struct CaptureMetadata: Codable, Sendable, Equatable {
    public let state: CaptureState
    public let scope: CaptureScope
    public let microphone: AudioDeviceIdentity
    public let outputDeviceChanges: [OutputDeviceChange]

    public init(state: CaptureState, scope: CaptureScope, microphone: AudioDeviceIdentity, outputDeviceChanges: [OutputDeviceChange] = []) {
        self.state = state
        self.scope = scope
        self.microphone = microphone
        self.outputDeviceChanges = outputDeviceChanges
    }
}

public struct CaptureScope: Codable, Sendable, Equatable {
    public let applicationBundleIdentifiers: [String]
    public let processIdentifiers: [Int32]

    public init(applicationBundleIdentifiers: [String], processIdentifiers: [Int32]) {
        self.applicationBundleIdentifiers = applicationBundleIdentifiers
        self.processIdentifiers = processIdentifiers
    }
}

public struct AudioDeviceIdentity: Codable, Sendable, Equatable {
    public let uniqueID: String
    public let name: String

    public init(uniqueID: String, name: String) {
        self.uniqueID = uniqueID
        self.name = name
    }
}

public struct OutputDeviceChange: Codable, Sendable, Equatable {
    public let occurredAt: Date
    public let previousDevice: AudioDeviceIdentity?
    public let currentDevice: AudioDeviceIdentity

    public init(occurredAt: Date, previousDevice: AudioDeviceIdentity?, currentDevice: AudioDeviceIdentity) {
        self.occurredAt = occurredAt
        self.previousDevice = previousDevice
        self.currentDevice = currentDevice
    }
}

public struct RecorderTrackCollection: Codable, Sendable, Equatable {
    public let system: RecorderTrackManifest?
    public let microphone: RecorderTrackManifest?
    /// Stable consumer field: `tracks.final.checksum` is the verified `final.flac` checksum.
    public let finalTrack: RecorderTrackManifest?

    enum CodingKeys: String, CodingKey { case system, microphone, finalTrack = "final" }

    public init(system: RecorderTrackManifest? = nil, microphone: RecorderTrackManifest? = nil, finalTrack: RecorderTrackManifest? = nil) {
        self.system = system
        self.microphone = microphone
        self.finalTrack = finalTrack
    }
}

public struct RecorderTrackManifest: Codable, Sendable, Equatable {
    public let sourceFormat: AudioSourceFormat
    public let firstMediaTimestampSeconds: TimeInterval
    public let frameCount: Int64
    public let fileName: String
    public let checksum: String
    public let journalReference: String?

    public init(sourceFormat: AudioSourceFormat, firstMediaTimestampSeconds: TimeInterval, frameCount: Int64, fileName: String, checksum: String, journalReference: String? = nil) {
        self.sourceFormat = sourceFormat
        self.firstMediaTimestampSeconds = firstMediaTimestampSeconds
        self.frameCount = frameCount
        self.fileName = fileName
        self.checksum = checksum
        self.journalReference = journalReference
    }
}

public struct AudioSourceFormat: Codable, Sendable, Equatable {
    public let sampleRate: Double
    public let channelCount: Int
    public let formatDescription: String

    public init(sampleRate: Double, channelCount: Int, formatDescription: String) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.formatDescription = formatDescription
    }
}

public struct CaptureGap: Codable, Sendable, Equatable {
    public let track: RecorderTrackKind?
    public let startedAtSeconds: TimeInterval
    public let durationSeconds: TimeInterval
    public let reason: String

    public init(track: RecorderTrackKind? = nil, startedAtSeconds: TimeInterval, durationSeconds: TimeInterval, reason: String) {
        self.track = track
        self.startedAtSeconds = startedAtSeconds
        self.durationSeconds = durationSeconds
        self.reason = reason
    }
}

public enum RecorderTrackKind: String, Codable, Sendable, Equatable {
    case system
    case microphone
    case final
}

public struct CaptureInterruption: Codable, Sendable, Equatable {
    public let occurredAt: Date
    public let reason: String

    public init(occurredAt: Date, reason: String) {
        self.occurredAt = occurredAt
        self.reason = reason
    }
}

public struct ProcessingMetadata: Codable, Sendable, Equatable {
    /// Stable consumer field. A transcription importer accepts only `.complete`.
    public let state: ProcessingState
    public let dependencyVersions: [String: String]
    public let configuration: [String: ManifestJSONValue]
    public let resamplingCorrections: [ResamplingCorrection]
    public let delayCorrections: [DelayCorrection]
    public let mixGains: [String: Double]
    public let errors: [ManifestError]

    public init(state: ProcessingState, dependencyVersions: [String: String] = [:], configuration: [String: ManifestJSONValue] = [:], resamplingCorrections: [ResamplingCorrection] = [], delayCorrections: [DelayCorrection] = [], mixGains: [String: Double] = [:], errors: [ManifestError] = []) {
        self.state = state
        self.dependencyVersions = dependencyVersions
        self.configuration = configuration
        self.resamplingCorrections = resamplingCorrections
        self.delayCorrections = delayCorrections
        self.mixGains = mixGains
        self.errors = errors
    }
}

public struct ResamplingCorrection: Codable, Sendable, Equatable {
    public let track: RecorderTrackKind
    public let originalSampleRate: Double
    public let outputSampleRate: Double

    public init(track: RecorderTrackKind, originalSampleRate: Double, outputSampleRate: Double) {
        self.track = track
        self.originalSampleRate = originalSampleRate
        self.outputSampleRate = outputSampleRate
    }
}

public struct DelayCorrection: Codable, Sendable, Equatable {
    public let track: RecorderTrackKind
    public let delaySeconds: TimeInterval

    public init(track: RecorderTrackKind, delaySeconds: TimeInterval) {
        self.track = track
        self.delaySeconds = delaySeconds
    }
}

public struct ManifestError: Codable, Sendable, Equatable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public enum ManifestJSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case array([ManifestJSONValue])
    case object([String: ManifestJSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([ManifestJSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: ManifestJSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public enum RecorderSessionManifestCodec {
    public static func encode(_ manifest: RecorderSessionManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(manifest)
    }

    public static func decode(_ data: Data) throws -> RecorderSessionManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RecorderSessionManifest.self, from: data)
    }
}

/// The bundled Draft 2020-12 JSON Schema for `metadata.json`.
public enum RecorderSessionManifestSchema {
    public static var data: Data {
        guard let url = Bundle.module.url(forResource: "RecorderSessionManifest", withExtension: "schema.json"),
              let data = try? Data(contentsOf: url) else {
            preconditionFailure("RecorderSessionManifest.schema.json is missing from ScribeAppCore resources")
        }
        return data
    }
}

public enum AtomicReplaceFileWriterError: Error, Equatable {
    case destinationHasNoParentDirectory
}

/// Writes a completed manifest through a same-directory temporary file, then atomically replaces it.
public final class AtomicReplaceFileWriter: @unchecked Sendable {
    public typealias CommitOperation = @Sendable (_ temporaryURL: URL, _ destinationURL: URL) throws -> Void

    private let fileManager: FileManager
    private let commitOperation: CommitOperation?

    /// `commitOperation` exists to make failure behavior testable without weakening production replacement.
    public init(fileManager: FileManager = .default, commitOperation: CommitOperation? = nil) {
        self.fileManager = fileManager
        self.commitOperation = commitOperation
    }

    public func write(_ manifest: RecorderSessionManifest, to destinationURL: URL) throws {
        try write(RecorderSessionManifestCodec.encode(manifest), to: destinationURL)
    }

    public func write(_ data: Data, to destinationURL: URL) throws {
        let directoryURL = destinationURL.deletingLastPathComponent()
        guard !directoryURL.path.isEmpty else { throw AtomicReplaceFileWriterError.destinationHasNoParentDirectory }
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let temporaryURL = directoryURL.appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporaryURL, options: .withoutOverwriting)
            if let commitOperation {
                try commitOperation(temporaryURL, destinationURL)
            } else if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }
}
