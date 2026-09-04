import Foundation

/// A JSON tree with author-controlled key order, serialized by a writer that never reorders or
/// omits what the exporter asked for.
///
/// `JSONEncoder` cannot express the canonical schema faithfully: its synthesized encoding drops
/// `null` for absent optionals, so schema-required nullable fields such as `speaker_id` and
/// `speaker_confidence` would disappear. Building the tree explicitly also fixes key order and
/// number formatting, which is what makes exports byte-deterministic across processes.
enum ExportJSON: Equatable, Sendable {
    case string(String)
    case integer(Int)
    case double(Double)
    case boolean(Bool)
    case null
    case array([ExportJSON])
    case object([Member])

    struct Member: Equatable, Sendable {
        let key: String
        let value: ExportJSON

        init(_ key: String, _ value: ExportJSON) {
            self.key = key
            self.value = value
        }
    }

    /// Builds an object whose keys are sorted, for Swift dictionaries that carry no inherent order.
    static func sortedObject(_ dictionary: [String: ExportJSON]) -> ExportJSON {
        .object(dictionary.keys.sorted().map { Member($0, dictionary[$0]!) })
    }
}

/// Serializes an ``ExportJSON`` tree as pretty-printed UTF-8 with two-space indentation.
enum ExportJSONWriter {
    static func data(_ value: ExportJSON) throws -> Data {
        var output = ""
        try write(value, depth: 0, into: &output)
        output.append("\n")
        return Data(output.utf8)
    }

    private static func write(_ value: ExportJSON, depth: Int, into output: inout String) throws {
        switch value {
        case .string(let text):
            output.append(escaped(text))
        case .integer(let number):
            output.append(String(number))
        case .double(let number):
            guard number.isFinite else { throw TranscriptExportError.nonFiniteNumber }
            output.append("\(number)")
        case .boolean(let flag):
            output.append(flag ? "true" : "false")
        case .null:
            output.append("null")
        case .array(let elements):
            guard !elements.isEmpty else { return output.append("[]") }
            output.append("[\n")
            for (offset, element) in elements.enumerated() {
                output.append(indent(depth + 1))
                try write(element, depth: depth + 1, into: &output)
                output.append(offset == elements.count - 1 ? "\n" : ",\n")
            }
            output.append(indent(depth))
            output.append("]")
        case .object(let members):
            guard !members.isEmpty else { return output.append("{}") }
            output.append("{\n")
            for (offset, member) in members.enumerated() {
                output.append(indent(depth + 1))
                output.append(escaped(member.key))
                output.append(": ")
                try write(member.value, depth: depth + 1, into: &output)
                output.append(offset == members.count - 1 ? "\n" : ",\n")
            }
            output.append(indent(depth))
            output.append("}")
        }
    }

    private static func indent(_ depth: Int) -> String {
        String(repeating: "  ", count: depth)
    }

    /// Escapes only what RFC 8259 requires, leaving non-ASCII text as literal UTF-8.
    private static func escaped(_ text: String) -> String {
        var output = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": output.append("\\\"")
            case "\\": output.append("\\\\")
            case "\u{08}": output.append("\\b")
            case "\u{0C}": output.append("\\f")
            case "\n": output.append("\\n")
            case "\r": output.append("\\r")
            case "\t": output.append("\\t")
            default:
                if scalar.value < 0x20 {
                    output.append(String(format: "\\u%04x", scalar.value))
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output.append("\"")
        return output
    }
}
