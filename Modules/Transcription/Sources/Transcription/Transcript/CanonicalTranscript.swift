import Foundation

/// The versioned, source-relative transcript consumed by review and export features.
public struct CanonicalTranscript: Codable, Sendable, Equatable, Identifiable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let transcriptID: String
    public let revision: Int
    /// A name a person gave this transcript in review, or nil to go by the
    /// source filename. Renaming is a revision like any other label edit.
    public let title: String?
    public let status: TranscriptStatus
    public let createdAt: String
    public let source: TranscriptSource
    public let language: String
    public let languageSource: TranscriptLanguageSource
    public let timestampUnit: TranscriptTimestampUnit
    public let timestampOrigin: TranscriptTimestampOrigin
    public let speakers: [TranscriptSpeaker]
    public let segments: [TranscriptSegment]
    public let subtitleCueMappings: [SubtitleCueMapping]?
    public let processingOptions: [String: TranscriptJSONValue]
    public let engineRevisions: [String: String]
    public let warnings: [TranscriptWarning]

    public var id: String { transcriptID }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case transcriptID = "transcript_id"
        case revision, status, title
        case createdAt = "created_at"
        case source, language
        case languageSource = "language_source"
        case timestampUnit = "timestamp_unit"
        case timestampOrigin = "timestamp_origin"
        case speakers, segments
        case subtitleCueMappings = "subtitle_cue_mappings"
        case processingOptions = "processing_options"
        case engineRevisions = "engine_revisions"
        case warnings
    }

    public init(
        schemaVersion: Int = CanonicalTranscript.currentSchemaVersion,
        transcriptID: String,
        revision: Int,
        title: String? = nil,
        status: TranscriptStatus,
        createdAt: String,
        source: TranscriptSource,
        language: String,
        languageSource: TranscriptLanguageSource,
        timestampUnit: TranscriptTimestampUnit = .milliseconds,
        timestampOrigin: TranscriptTimestampOrigin = .sourceStart,
        speakers: [TranscriptSpeaker],
        segments: [TranscriptSegment],
        subtitleCueMappings: [SubtitleCueMapping]? = nil,
        processingOptions: [String: TranscriptJSONValue] = [:],
        engineRevisions: [String: String] = [:],
        warnings: [TranscriptWarning] = []
    ) {
        self.schemaVersion = schemaVersion
        self.transcriptID = transcriptID
        self.revision = revision
        self.title = title
        self.status = status
        self.createdAt = createdAt
        self.source = source
        self.language = language
        self.languageSource = languageSource
        self.timestampUnit = timestampUnit
        self.timestampOrigin = timestampOrigin
        self.speakers = speakers
        self.segments = segments
        self.subtitleCueMappings = subtitleCueMappings
        self.processingOptions = processingOptions
        self.engineRevisions = engineRevisions
        self.warnings = warnings
    }
}

public enum TranscriptStatus: String, Codable, Sendable, Equatable {
    case complete
    case completeWithWarnings
    case noSpeech
}

public enum TranscriptLanguageSource: String, Codable, Sendable, Equatable {
    case detected
    case userProvided = "user_provided"
    case unknown
}

public enum TranscriptTimestampUnit: String, Codable, Sendable, Equatable {
    case milliseconds
}

public enum TranscriptTimestampOrigin: String, Codable, Sendable, Equatable {
    case sourceStart = "source_start"
}

public struct TranscriptSource: Codable, Sendable, Equatable {
    public let filename: String
    public let durationMs: Int
    public let checksum: String

    private enum CodingKeys: String, CodingKey {
        case filename
        case durationMs = "duration_ms"
        case checksum
    }

    public init(filename: String, durationMs: Int, checksum: String) {
        self.filename = filename
        self.durationMs = durationMs
        self.checksum = checksum
    }
}

public struct TranscriptSpeaker: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let profileID: String?
    public let identityAssignment: SpeakerIdentityAssignment
    public let labelSnapshot: String

    private enum CodingKeys: String, CodingKey {
        case id
        case profileID = "profile_id"
        case identityAssignment = "identity_assignment"
        case labelSnapshot = "label_snapshot"
    }

    public init(id: String, profileID: String? = nil, identityAssignment: SpeakerIdentityAssignment, labelSnapshot: String) {
        self.id = id
        self.profileID = profileID
        self.identityAssignment = identityAssignment
        self.labelSnapshot = labelSnapshot
    }
}

public enum SpeakerIdentityAssignment: String, Codable, Sendable, Equatable {
    case manual
    case automatic
    case unmatched
}

public struct TranscriptSegment: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let speakerID: String?
    public let speakerLabel: String
    public let startMs: Int
    public let endMs: Int
    public let text: String
    public let overlap: Bool
    public let timingQuality: TranscriptTimingQuality
    public let speakerConfidence: Double?
    public let words: [TimedWord]?

    private enum CodingKeys: String, CodingKey {
        case id
        case speakerID = "speaker_id"
        case speakerLabel = "speaker_label"
        case startMs = "start_ms"
        case endMs = "end_ms"
        case text, overlap
        case timingQuality = "timing_quality"
        case speakerConfidence = "speaker_confidence"
        case words
    }

    public init(
        id: String,
        speakerID: String?,
        speakerLabel: String,
        startMs: Int,
        endMs: Int,
        text: String,
        overlap: Bool,
        timingQuality: TranscriptTimingQuality,
        speakerConfidence: Double? = nil,
        words: [TimedWord]? = nil
    ) {
        self.id = id
        self.speakerID = speakerID
        self.speakerLabel = speakerLabel
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.overlap = overlap
        self.timingQuality = timingQuality
        self.speakerConfidence = speakerConfidence
        self.words = words
    }
}

public enum TranscriptTimingQuality: String, Codable, Sendable, Equatable {
    case asrWord = "asr_word"
    case segmentOnly = "segment_only"
    case forcedAligned = "forced_aligned"
}

public struct TimedWord: Codable, Sendable, Equatable {
    public let text: String
    public let startMs: Int
    public let endMs: Int

    private enum CodingKeys: String, CodingKey {
        case text
        case startMs = "start_ms"
        case endMs = "end_ms"
    }

    public init(text: String, startMs: Int, endMs: Int) {
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
    }
}

/// Maps an exporter-derived subtitle cue back to the canonical segment that produced it.
public struct SubtitleCueMapping: Codable, Sendable, Equatable, Identifiable {
    public let cueID: String
    public let parentSegmentID: String
    public let startMs: Int
    public let endMs: Int

    public var id: String { cueID }

    private enum CodingKeys: String, CodingKey {
        case cueID = "cue_id"
        case parentSegmentID = "parent_segment_id"
        case startMs = "start_ms"
        case endMs = "end_ms"
    }

    public init(cueID: String, parentSegmentID: String, startMs: Int, endMs: Int) {
        self.cueID = cueID
        self.parentSegmentID = parentSegmentID
        self.startMs = startMs
        self.endMs = endMs
    }
}

public struct TranscriptWarning: Codable, Sendable, Equatable {
    public let code: String
    public let message: String
    public let segmentID: String?

    private enum CodingKeys: String, CodingKey {
        case code, message
        case segmentID = "segment_id"
    }

    public init(code: String, message: String, segmentID: String? = nil) {
        self.code = code
        self.message = message
        self.segmentID = segmentID
    }
}

/// A JSON-safe value for persisted processing options without narrowing future option types.
public enum TranscriptJSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case array([TranscriptJSONValue])
    case object([String: TranscriptJSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([TranscriptJSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: TranscriptJSONValue].self)) }
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

public enum CanonicalTranscriptCodec {
    public static func encode(_ transcript: CanonicalTranscript) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(transcript)
    }

    public static func decode(_ data: Data) throws -> CanonicalTranscript {
        let decoder = JSONDecoder()
        return try decoder.decode(CanonicalTranscript.self, from: data)
    }
}

/// The bundled Draft 2020-12 schema for canonical transcript JSON.
public enum CanonicalTranscriptSchema {
    public static var data: Data {
        guard let url = Bundle.module.url(forResource: "CanonicalTranscript", withExtension: "schema.json"),
              let data = try? Data(contentsOf: url) else {
            preconditionFailure("CanonicalTranscript.schema.json is missing from Transcription resources")
        }
        return data
    }
}
