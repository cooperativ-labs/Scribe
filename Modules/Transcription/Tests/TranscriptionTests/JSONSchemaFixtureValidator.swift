import Foundation

/// A minimal Draft 2020-12 subset validator, enough for the constructs the canonical schema uses.
struct JSONSchemaFixtureValidator {
    let rootSchema: [String: Any]

    func validate(_ instance: Any) throws {
        try validate(instance, against: rootSchema)
    }

    private func validate(_ value: Any, against schema: [String: Any]) throws {
        let schema = try resolve(schema)
        if let alternatives = schema["oneOf"] as? [[String: Any]] {
            let matches = alternatives.filter { alternative in
                do { try validate(value, against: alternative); return true } catch { return false }
            }.count
            guard matches == 1 else { throw ValidationError.invalidType }
        }
        if let constant = schema["const"] as? NSNumber, let value = value as? NSNumber, value != constant { throw ValidationError.invalidConstant }
        if let constant = schema["const"] as? String, value as? String != constant { throw ValidationError.invalidConstant }
        if let values = schema["enum"] as? [String], !values.contains(value as? String ?? "") { throw ValidationError.invalidEnum }
        if let types = schema["type"] as? [String], !types.contains(where: { matches(value, type: $0) }) { throw ValidationError.invalidType }
        if let type = schema["type"] as? String, !matches(value, type: type) { throw ValidationError.invalidType }
        if let minimum = schema["minimum"] as? NSNumber, let number = value as? NSNumber, number.doubleValue < minimum.doubleValue { throw ValidationError.invalidMinimum }
        if let maximum = schema["maximum"] as? NSNumber, let number = value as? NSNumber, number.doubleValue > maximum.doubleValue { throw ValidationError.invalidMaximum }
        if let minLength = schema["minLength"] as? NSNumber, let string = value as? String, string.count < minLength.intValue { throw ValidationError.invalidLength }
        if let minItems = schema["minItems"] as? NSNumber, let array = value as? [Any], array.count < minItems.intValue { throw ValidationError.invalidLength }
        if let array = value as? [Any], let itemSchema = schema["items"] as? [String: Any] {
            try array.forEach { try validate($0, against: itemSchema) }
        }
        guard let object = value as? [String: Any] else { return }
        let properties = schema["properties"] as? [String: Any] ?? [:]
        if schema["additionalProperties"] as? Bool == false {
            let allowed = Set(properties.keys)
            guard Set(object.keys).isSubset(of: allowed) else { throw ValidationError.invalidType }
        }
        if let additional = schema["additionalProperties"] as? [String: Any] {
            for key in object.keys where properties[key] == nil {
                try validate(object[key] as Any, against: additional)
            }
        }
        if let propertyNames = schema["propertyNames"] as? [String: Any],
           let pattern = propertyNames["pattern"] as? String {
            let expression = try NSRegularExpression(pattern: pattern)
            for key in object.keys {
                let range = NSRange(key.startIndex..<key.endIndex, in: key)
                guard expression.firstMatch(in: key, range: range)?.range == range else {
                    throw ValidationError.invalidPattern
                }
            }
        }
        for key in schema["required"] as? [String] ?? [] where object[key] == nil { throw ValidationError.missingRequiredField(key) }
        for (key, propertySchema) in schema["properties"] as? [String: [String: Any]] ?? [:] {
            if let property = object[key] { try validate(property, against: propertySchema) }
        }
    }

    private func resolve(_ schema: [String: Any]) throws -> [String: Any] {
        guard let reference = schema["$ref"] as? String else { return schema }
        guard reference.hasPrefix("#/$defs/"),
              let definitions = rootSchema["$defs"] as? [String: [String: Any]],
              let resolved = definitions[String(reference.dropFirst("#/$defs/".count))] else { throw ValidationError.unsupportedReference }
        return resolved
    }

    private func matches(_ value: Any, type: String) -> Bool {
        switch type {
        case "object": return value is [String: Any]
        case "array": return value is [Any]
        case "string": return value is String
        case "integer": return value is NSNumber && floor((value as! NSNumber).doubleValue) == (value as! NSNumber).doubleValue
        case "number": return value is NSNumber
        case "boolean": return value is Bool
        case "null": return value is NSNull
        default: return false
        }
    }

    private enum ValidationError: Swift.Error {
        case invalidConstant, invalidEnum, invalidType, invalidMinimum, invalidMaximum, invalidLength, invalidPattern, missingRequiredField(String), unsupportedReference
    }
}
