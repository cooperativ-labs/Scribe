import Foundation
import XCTest
@testable import ScribeAppCore

final class ApplicationUpdaterTests: XCTestCase {
    func testArchiveSelectionRejectsUnrelatedZIPAndInsecureURL() throws {
        let release = try JSONDecoder().decode(GitHubRelease.self, from: Data("""
        {"tag_name":"v2.0","html_url":"https://github.com/cooperativ-labs/scribe",
         "assets":[
          {"name":"other.zip","browser_download_url":"https://github.com/cooperativ-labs/scribe/releases/download/v2.0/other.zip"},
          {"name":"Scribe-2.0-macos.zip","browser_download_url":"http://github.com/cooperativ-labs/scribe/releases/download/v2.0/Scribe-2.0-macos.zip"}]}
        """.utf8))
        XCTAssertNil(release.installableArchiveURL)
    }

    func testBundleValidationRejectsWrongIdentityVersionAndDowngrade() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let current = try bundle(root, name: "Current", version: "2.0")
        let good = try bundle(root, name: "Good", version: "3.0")
        XCTAssertNoThrow(try ApplicationUpdater.validateBundle(good, current: current, version: "3.0"))
        XCTAssertThrowsError(try ApplicationUpdater.validateBundle(good, current: current, version: "4.0"))
        let old = try bundle(root, name: "Old", version: "1.0")
        XCTAssertThrowsError(try ApplicationUpdater.validateBundle(old, current: current, version: "1.0"))
        let wrong = try bundle(root, name: "Wrong", version: "3.0", identifier: "com.other.app")
        XCTAssertThrowsError(try ApplicationUpdater.validateBundle(wrong, current: current, version: "3.0"))
    }

    func testArchiveExtractionRejectsTraversal() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("bad.zip")
        try XCTUnwrap(Data(base64Encoded: "UEsDBBQAAAAAAGBHJV37OSuCAwAAAAMAAAAKAAAALi4vZXNjYXBlZGJhZFBLAQIUAxQAAAAAAGBHJV37OSuCAwAAAAMAAAAKAAAAAAAAAAAAAACAAQAAAAAuLi9lc2NhcGVkUEsFBgAAAAABAAEAOAAAACsAAAAAAA==" )).write(to: archive)
        XCTAssertThrowsError(try ApplicationUpdater.extractArchive(archive, to: root.appendingPathComponent("extracted")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped").path))
    }

    func testExtractionReadsReleasePackagingFormat() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try bundle(root, name: "Scribe", version: "3.0")
        let archive = root.appendingPathComponent("release.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", app.path, archive.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let extracted = root.appendingPathComponent("extracted")
        try ApplicationUpdater.extractArchive(archive, to: extracted)
        let current = try bundle(root, name: "Current", version: "2.0")
        XCTAssertNoThrow(try ApplicationUpdater.validateBundle(extracted.appendingPathComponent("Scribe.app"), current: current, version: "3.0"))
    }

    func testInstallerNeverReplacesApplicationWhenQuitDoesNotFinish() throws {
        try exerciseInstaller(failValidation: false, failLaunch: false, failMove: false, expected: "old", status: 1, parentAlive: true)
    }

    func testInstallerReplacesApplicationAndCleansStaging() throws {
        try exerciseInstaller(failValidation: false, failLaunch: false, failMove: false, expected: "new", status: 0)
    }

    func testInstallerVerificationFailurePreservesOriginal() throws {
        try exerciseInstaller(failValidation: true, failLaunch: false, failMove: false, expected: "old", status: 1)
    }

    func testInstallerLaunchFailureRestoresOriginal() throws {
        try exerciseInstaller(failValidation: false, failLaunch: true, failMove: false, expected: "old", status: 1)
    }

    func testInstallerMoveFailureRestoresOriginal() throws {
        try exerciseInstaller(failValidation: false, failLaunch: false, failMove: true, expected: "old", status: 1)
    }

    // Run the production transaction against isolated fake bundles. Only signing,
    // Launch Services, and the alert are stubbed; renames/rollback/cleanup are real.
    private func exerciseInstaller(failValidation: Bool, failLaunch: Bool, failMove: Bool, expected: String, status: Int32, parentAlive: Bool = false) throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("stage with ' quotes")
        let destination = root.appendingPathComponent("Scribe with ' quotes.app")
        let candidate = staging.appendingPathComponent("Scribe.app")
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination.appendingPathComponent("version"))
        try Data("new".utf8).write(to: candidate.appendingPathComponent("version"))
        var script = try String(contentsOf: XCTUnwrap(ApplicationUpdater.installerResource), encoding: .utf8)
        script = script.replacingOccurrences(of: "/usr/bin/codesign", with: failValidation ? "/usr/bin/false" : "/usr/bin/true")
            .replacingOccurrences(of: "/usr/sbin/spctl", with: "/usr/bin/true")
            .replacingOccurrences(of: "/usr/bin/open", with: failLaunch ? "/usr/bin/false" : "/usr/bin/true")
            .replacingOccurrences(of: "/usr/bin/osascript", with: "/usr/bin/true")
        if parentAlive {
            script = script.replacingOccurrences(of: "/bin/sleep", with: "/usr/bin/true")
        }
        if failMove {
            script = script.replacingOccurrences(of: "/bin/mv \"$candidate\" \"$destination\"", with: "/usr/bin/false")
        }
        let scriptURL = root.appendingPathComponent("installer.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path, parentAlive ? String(ProcessInfo.processInfo.processIdentifier) : "2147483647", staging.path, candidate.path, destination.path, "unused test requirement"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, status)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("version"), encoding: .utf8), expected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func bundle(_ root: URL, name: String, version: String, identifier: String = "com.scribe.app") throws -> URL {
        let url = root.appendingPathComponent("\(name).app")
        let contents = url.appendingPathComponent("Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let executable = macOS.appendingPathComponent("Scribe")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let plist = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version,
                     "CFBundleExecutable": "Scribe", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        return url
    }
}
