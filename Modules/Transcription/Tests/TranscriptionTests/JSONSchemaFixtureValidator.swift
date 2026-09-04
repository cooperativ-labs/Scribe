import Foundation

/// A minimal Draft 2020-12 subset validator, enough for the constructs the canonical schema uses.
struct JSONSchemaFixtureValidator {
    let rootSchema: [String: Any]

    func validate(_ instance: Any) throws {
        try validate(instance, against: rootSchema)
    }

    private func validate(_ value: Any, against schema: [String: Any]) throws {
        let schema = try resolve(schema)
        if let constant = schema["const"] as? NSNumber, let value = value as? NSNumber, value != constant { throw ValidationError.invalidConstant }
        if let constant = schema["const"] as? String, value as? String != constant { throw ValidationError.invalidConstant }
        if let values = schema["enum"] as? [String], !values.contains(value as? String ?? "") { throw ValidationError.invalidEnum }
        if let types = schema["type"] as? [String], !types.contains(where: { matches(value, type: $0) }) { throw ValidationError.invalidType }
        if let type = schema["type"] as? String, !matches(value, type: type) { throw ValidationError.invalidType }
        if let minimum = schema["minimum"] as? NSNumber, let number = value as? NSNumber, number.doubleValue < minimum.doubleValue { throw ValidationError.invalidMinimum }
        if let minLength = schema["minLength"] as? NSNumber, let string = value as? String, string.count < minLength.intValue { throw ValidationError.invalidLength }
        if let array = value as? [Any], let itemSchema = schema["items"] as? [String: Any] {
            try array.forEach { try validate($0, against: itemSchema) }
        }
        guard let object = value as? [String: Any] else { return }
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
        case invalidConstant, invalidEnum, invalidType, invalidMinimum, invalidLength, missingRequiredField(String), unsupportedReference
    }
}
