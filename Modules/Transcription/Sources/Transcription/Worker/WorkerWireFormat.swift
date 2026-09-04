import Foundation

/// Host-side copy of the worker's newline-delimited JSON envelope.
///
/// Field names and the size bound match `WorkerProtocol.swift` in
/// `Workers/TranscriptionWorker`. The copy exists for the same reason as
/// `WorkerASRTranscript`: the helper package pulls in FluidAudio and the Core ML
/// model stack, and none of that belongs in the process that draws the UI. The
/// integration test in this module drives the real binary, so a drift in either
/// direction fails a test rather than only a production run.
public struct WorkerEnvelope: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public enum Kind: String, Codable, Sendable {
        case request
        case progress
        case stageResult = "stage_result"
        case error
        case cancel
    }

    public let version: Int
    public let kind: Kind
    public let requestID: String
    public let payload: WorkerJSONValue

    public init(version: Int = WorkerEnvelope.currentVersion, kind: Kind, requestID: String, payload: WorkerJSONValue) {
        self.version = version
        self.kind = kind
        self.requestID = requestID
        self.payload = payload
    }
}

public enum WorkerJSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: WorkerJSONValue])
    case array([WorkerJSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: WorkerJSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([WorkerJSONValue].self) { self = .array(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value") }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public extension WorkerJSONValue {
    var objectValue: [String: WorkerJSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var arrayValue: [WorkerJSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var numberValue: Double? {
        guard case let .number(value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    /// Integers cross the wire as JSON numbers; a fractional value is not one.
    var integerValue: Int? {
        guard case let .number(value) = self, value.rounded() == value, value.magnitude < 9_007_199_254_740_992 else { return nil }
        return Int(value)
    }
}

/// Framing and the record-size bound shared with the worker.
public enum WorkerWireFormat {
    /// One record is one UTF-8 JSON value terminated by a single LF. Results
    /// larger than this are written to the run directory by the worker and
    /// referenced by file name, so the control plane stays small in both
    /// directions.
    public static let maximumMessageBytes = 1_048_576
    public static let recordSeparator: UInt8 = 0x0A

    public static func decode(_ data: Data) throws -> WorkerEnvelope {
        guard data.count <= maximumMessageBytes else {
            throw WorkerWireFormatError.messageTooLarge(actualBytes: data.count, limitBytes: maximumMessageBytes)
        }
        let envelope: WorkerEnvelope
        do { envelope = try JSONDecoder().decode(WorkerEnvelope.self, from: data) }
        catch { throw WorkerWireFormatError.malformedMessage(error.localizedDescription) }
        guard envelope.version == WorkerEnvelope.currentVersion else {
            throw WorkerWireFormatError.unsupportedVersion(envelope.version)
        }
        return envelope
    }

    /// Returns the record with its trailing separator, ready to write.
    public static func encode(_ envelope: WorkerEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(envelope)
        guard data.count <= maximumMessageBytes else {
            throw WorkerWireFormatError.messageTooLarge(actualBytes: data.count, limitBytes: maximumMessageBytes)
        }
        data.append(recordSeparator)
        return data
    }
}

public enum WorkerWireFormatError: Error, Equatable, Sendable {
    case messageTooLarge(actualBytes: Int, limitBytes: Int)
    case unsupportedVersion(Int)
    case malformedMessage(String)
}

extension WorkerWireFormatError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .messageTooLarge(actualBytes, limitBytes):
            "A worker message of \(actualBytes) bytes exceeds the \(limitBytes)-byte protocol limit."
        case let .unsupportedVersion(version):
            "The worker speaks protocol version \(version); this build supports version \(WorkerEnvelope.currentVersion)."
        case let .malformedMessage(reason):
            "The worker sent a malformed JSON record: \(reason)"
        }
    }
}
