// swift-tools-version: 6.0
import Foundation
import PackageDescription

// The pinned WebRTC Audio Processing Module is not a Swift package and cannot be
// fetched by SwiftPM. It is produced by Scripts/build-native-dependencies.sh into
// Vendor/prefix/<platform>, and this manifest points the compiler and linker at
// whatever that build produced. Everything below is derived from the manifest's
// own location, so the package works from any checkout path.

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

#if arch(x86_64)
// Documented but not validated; see README.md, "Intel (x86_64) path".
let platformSlice = "macos-x86_64"
#else
let platformSlice = "macos-arm64"
#endif

let vendorDirectory = packageDirectory.appendingPathComponent("Vendor")
let prefixDirectory = vendorDirectory.appendingPathComponent("prefix/\(platformSlice)")
let includeDirectory = prefixDirectory.appendingPathComponent("include")
let moduleIncludeDirectory = includeDirectory.appendingPathComponent("webrtc-audio-processing-2")
let libraryDirectory = prefixDirectory.appendingPathComponent("lib")

/// Pull a value out of Vendor/webrtc-apm.lock so the provenance string compiled
/// into the bridge can never disagree with the pin the build script used.
func lockedValue(_ key: String) -> String {
    let lockFile = vendorDirectory.appendingPathComponent("webrtc-apm.lock")
    guard let contents = try? String(contentsOf: lockFile, encoding: .utf8) else { return "unknown" }
    for line in contents.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("\(key)=") else { continue }
        return String(trimmed.dropFirst(key.count + 1))
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
    return "unknown"
}

let upstreamRevision = """
webrtc-audio-processing \(lockedValue("WEBRTC_APM_VERSION")) \
(\(lockedValue("WEBRTC_APM_GIT_REV")), WebRTC \(lockedValue("WEBRTC_APM_UPSTREAM_WEBRTC_BRANCH")))
"""

// Abseil is discovered rather than hard-coded: the exact set of archives is a
// property of how the pinned release was configured, not something this manifest
// should assert independently and get wrong.
let abseilLibraryNames: [String] = {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: libraryDirectory.path)) ?? []
    return names
        .filter { $0.hasPrefix("libabsl_") && $0.hasSuffix(".a") }
        .map { String($0.dropFirst("lib".count).dropLast(".a".count)) }
        .sorted()
}()

if !FileManager.default.fileExists(atPath: libraryDirectory.appendingPathComponent("libwebrtc-audio-processing-2.a").path) {
    FileHandle.standardError.write(Data("""
        warning: the pinned WebRTC Audio Processing Module has not been built for \(platformSlice).
                 Run Scripts/build-native-dependencies.sh from the repository root first;
                 until then this package will fail to link.

        """.utf8))
}

// Static archives are searched in command-line order, and the abseil archives
// reference each other. Listing the set twice lets the linker close those cycles
// without force-loading everything into the binary.
let linkerFlags: [String] =
    ["-L\(libraryDirectory.path)", "-lwebrtc-audio-processing-2"]
    + abseilLibraryNames.map { "-l\($0)" }
    + abseilLibraryNames.map { "-l\($0)" }

let package = Package(
    name: "WebRTCBridge",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "WebRTCBridge", targets: ["WebRTCBridge"])
    ],
    targets: [
        // The C/Objective-C++ shim. Only this target sees WebRTC headers.
        .target(
            name: "CWebRTCAPM",
            cxxSettings: [
                .unsafeFlags([
                    "-I\(moduleIncludeDirectory.path)",
                    "-I\(includeDirectory.path)",
                ]),
                // Required by the module's public headers on Darwin; they come
                // from the pinned build's own pkg-config Cflags.
                .define("WEBRTC_MAC"),
                .define("WEBRTC_POSIX"),
                .define("SCRIBE_APM_UPSTREAM_REVISION", to: "\"\(upstreamRevision)\""),
            ],
            linkerSettings: [
                .unsafeFlags(linkerFlags),
                .linkedLibrary("c++"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Foundation"),
            ]
        ),
        // The Swift face of the bridge.
        .target(
            name: "WebRTCBridge",
            dependencies: ["CWebRTCAPM"]
        ),
        .testTarget(
            name: "WebRTCBridgeTests",
            dependencies: ["WebRTCBridge"]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
