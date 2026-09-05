import Foundation

/// Newline-delimited JSON protocol shared by the host process and worker.
///
/// The envelope deliberately contains values, never shell fragments. The host
/// launches the worker directly and all file system locations are decoded as
/// `URL`s from JSON string values before they are used.
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
    public let payload: JSONValue

    public init(version: Int = WorkerEnvelope.currentVersion, kind: Kind, requestID: String, payload: JSONValue) {
        self.version = version
        self.kind = kind
        self.requestID = requestID
        self.payload = payload
    }
}

public enum WorkerProtocolError: Error, LocalizedError, Sendable, Equatable {
    case messageTooLarge(actualBytes: Int, limitBytes: Int)
    case unsupportedVersion(Int)
    case malformedMessage(String)
    case invalidRequest(String)

    public var errorDescription: String? {
        switch self {
        case let .messageTooLarge(actualBytes, limitBytes):
            "Message is \(actualBytes) bytes; the protocol limit is \(limitBytes) bytes. Stream large results to disk."
        case let .unsupportedVersion(version):
            "Unsupported protocol version \(version)."
        case let .malformedMessage(reason):
            "Malformed JSON message: \(reason)"
        case let .invalidRequest(reason):
            "Invalid worker request: \(reason)"
        }
    }
}

public enum WorkerProtocol {
    /// Messages are a single UTF-8 JSON value terminated by one LF. Keeping the
    /// control plane small prevents transcripts from exhausting the helper.
    public static let maximumMessageBytes = 1_048_576

    public static func decode(_ data: Data) throws -> WorkerEnvelope {
        guard data.count <= maximumMessageBytes else {
            throw WorkerProtocolError.messageTooLarge(actualBytes: data.count, limitBytes: maximumMessageBytes)
        }
        do {
            let envelope = try JSONDecoder().decode(WorkerEnvelope.self, from: data)
            guard envelope.version == WorkerEnvelope.currentVersion else {
                throw WorkerProtocolError.unsupportedVersion(envelope.version)
            }
            return envelope
        } catch let error as WorkerProtocolError {
            throw error
        } catch {
            throw WorkerProtocolError.malformedMessage(error.localizedDescription)
        }
    }

    public static func encode(_ envelope: WorkerEnvelope) throws -> Data {
        let data = try JSONEncoder.worker.encode(envelope)
        guard data.count <= maximumMessageBytes else {
            throw WorkerProtocolError.messageTooLarge(actualBytes: data.count, limitBytes: maximumMessageBytes)
        }
        return data
    }

    public static func error(requestID: String, code: String, message: String, details: JSONValue = .object([:])) -> WorkerEnvelope {
        WorkerEnvelope(kind: .error, requestID: requestID, payload: .object([
            "code": .string(code),
            "message": .string(message),
            "details": details,
        ]))
    }
}

public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
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

public extension JSONValue {
    var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
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
}

private extension JSONEncoder {
    static let worker: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}
