import Foundation

/// A minimal JSON tree used for the report so absent measurements encode as explicit `null`
/// rather than being dropped the way synthesized `Codable` optionals are.
public indirect enum JSONValue: Encodable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public static func number(_ value: Double?) -> JSONValue {
        guard let value, value.isFinite else { return .null }
        return .double(value)
    }

    public static func number(_ value: Int?) -> JSONValue {
        value.map { .int($0) } ?? .null
    }

    public static func string(_ value: String?) -> JSONValue {
        value.map { .string($0) } ?? .null
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let values): try container.encode(values)
        case .object(let values): try container.encode(values)
        }
    }

    public func encodedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }
}
