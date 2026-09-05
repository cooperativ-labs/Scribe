import Foundation
import XCTest
@testable import ScribeAppCore

final class ScribeAppCoreContractTests: XCTestCase {
    func testGitHubReleaseUsesPublishedMacOSArchiveAndNormalizesTagVersion() throws {
        let data = Data("""
        {
          "tag_name": "v1.2.3",
          "html_url": "https://github.com/cooperativ-labs/scribe/releases/tag/v1.2.3",
          "assets": [
            {"name": "Scribe-1.2.3-macos.zip", "browser_download_url": "https://github.com/cooperativ-labs/scribe/releases/download/v1.2.3/Scribe-1.2.3-macos.zip"}
          ]
        }
        """.utf8)

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)

        XCTAssertEqual(release.version, "1.2.3")
        XCTAssertEqual(release.installableArchiveURL?.absoluteString, "https://github.com/cooperativ-labs/scribe/releases/download/v1.2.3/Scribe-1.2.3-macos.zip")
    }

    func testGitHubReleaseWithoutArchiveCannotBeInstalled() throws {
        let data = Data("""
        {
          "tag_name": "v1.2.3",
          "html_url": "https://github.com/cooperativ-labs/scribe/releases/tag/v1.2.3",
          "assets": []
        }
        """.utf8)

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)

        XCTAssertNil(release.installableArchiveURL)
    }

    func testReleaseVersionComparisonAcceptsOnlyNewerNumericVersions() {
        XCTAssertTrue(ScribeReleaseVersion.isNewer("v1.10.0", than: "1.9.9"))
        XCTAssertTrue(ScribeReleaseVersion.isNewer("1.2.1", than: "1.2"))
        XCTAssertFalse(ScribeReleaseVersion.isNewer("1.2.0", than: "1.2"))
        XCTAssertFalse(ScribeReleaseVersion.isNewer("1.2.0", than: "1.3"))
        XCTAssertFalse(ScribeReleaseVersion.isNewer("nightly", than: "1.2.0"))
    }

    func testManifestRoundTripAndStableConsumerFields() throws {
        let manifest = try fixture(named: "completed-metadata")
        let decoded = try RecorderSessionManifestCodec.decode(try RecorderSessionManifestCodec.encode(manifest))

        XCTAssertEqual(decoded, manifest)
        XCTAssertEqual(decoded.schemaVersion, RecorderSessionManifest.currentSchemaVersion)
        XCTAssertEqual(decoded.processing.state, .complete)
        XCTAssertEqual(decoded.tracks.finalTrack?.fileName, "final.flac")
        XCTAssertEqual(decoded.tracks.finalTrack?.checksum, "final-sha256")
    }

    func testManifestDecoderToleratesUnknownFields() throws {
        let fixtureData = try fixtureData(named: "completed-metadata")
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: fixtureData) as? [String: Any])
        object["futureTopLevelField"] = ["introducedIn": 2]
        var processing = try XCTUnwrap(object["processing"] as? [String: Any])
        processing["futureProcessingField"] = true
        object["processing"] = processing

        let data = try JSONSerialization.data(withJSONObject: object)
        let manifest = try RecorderSessionManifestCodec.decode(data)
        XCTAssertEqual(manifest.processing.state, .complete)
    }

    func testFixtureManifestsValidateAgainstBundledJSONSchema() throws {
        let schema = try XCTUnwrap(try JSONSerialization.jsonObject(with: RecorderSessionManifestSchema.data) as? [String: Any])
        for name in ["completed-metadata", "interrupted-metadata"] {
            let instance = try JSONSerialization.jsonObject(with: fixtureData(named: name))
            try JSONSchemaFixtureValidator(schema: schema).validate(instance)
        }
    }

    func testAtomicReplacementReplacesExistingManifest() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("metadata.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination)

        try AtomicReplaceFileWriter().write(Data("new".utf8), to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data("new".utf8))
    }

    func testAtomicReplacementFailureLeavesExistingManifestUntouched() throws {
        struct SimulatedFailure: Error {}
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("metadata.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination)
        let writer = AtomicReplaceFileWriter(commitOperation: { _, _ in throw SimulatedFailure() })

        XCTAssertThrowsError(try writer.write(Data("new".utf8), to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasPrefix(".metadata.json.") })
    }

    private func fixture(named name: String) throws -> RecorderSessionManifest {
        try RecorderSessionManifestCodec.decode(fixtureData(named: name))
    }

    private func fixtureData(named name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }
}

private struct JSONSchemaFixtureValidator {
    let schema: [String: Any]

    func validate(_ instance: Any) throws {
        try validate(instance, against: schema)
    }

    private func validate(_ value: Any, against schema: [String: Any]) throws {
        let resolved = try resolve(schema)
        if let alternatives = resolved["oneOf"] as? [[String: Any]] {
            guard alternatives.contains(where: { (try? validate(value, against: $0)) != nil }) else { throw ValidationError.noMatchingAlternative }
            return
        }
        if let constant = resolved["const"] as? Int, (value as? NSNumber)?.intValue != constant { throw ValidationError.invalidConstant }
        if let values = resolved["enum"] as? [String], !values.contains(value as? String ?? "") { throw ValidationError.invalidEnum }
        if let types = resolved["type"] as? [String] {
            guard types.contains(where: { matches(value, type: $0) }) else { throw ValidationError.invalidType }
        } else if let type = resolved["type"] as? String, !matches(value, type: type) {
            throw ValidationError.invalidType
        }
        guard let object = value as? [String: Any] else { return }
        for key in resolved["required"] as? [String] ?? [] where object[key] == nil { throw ValidationError.missingRequiredField(key) }
        for (key, propertySchema) in resolved["properties"] as? [String: [String: Any]] ?? [:] {
            if let property = object[key] { try validate(property, against: propertySchema) }
        }
    }

    private func resolve(_ schema: [String: Any]) throws -> [String: Any] {
        guard let reference = schema["$ref"] as? String else { return schema }
        guard reference.hasPrefix("#/$defs/"), let definition = self.schema["$defs"] as? [String: [String: Any]], let resolved = definition[String(reference.dropFirst("#/$defs/".count))] else { throw ValidationError.unsupportedReference }
        return resolved
    }

    private func matches(_ value: Any, type: String) -> Bool {
        switch type {
        case "object": return value is [String: Any]
        case "array": return value is [Any]
        case "string": return value is String
        case "integer": return value is NSNumber && floor((value as! NSNumber).doubleValue) == (value as! NSNumber).doubleValue
        case "number": return value is NSNumber
        case "null": return value is NSNull
        default: return false
        }
    }

    private enum ValidationError: Error { case noMatchingAlternative, invalidConstant, invalidEnum, invalidType, missingRequiredField(String), unsupportedReference }
}
