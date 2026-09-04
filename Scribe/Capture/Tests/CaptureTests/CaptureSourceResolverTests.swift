import Foundation
import Platform
import Testing
@testable import Capture

/// Source resolution is the part of starting a capture that decides *what* gets
/// recorded, and it is the part that must never guess. These run without any
/// Screen & System Audio Recording grant.
@Suite struct CaptureSourceResolverTests {
    private let running = [
        CaptureApplicationOption(bundleIdentifier: "com.google.Chrome", name: "Google Chrome", processIdentifier: 501),
        CaptureApplicationOption(bundleIdentifier: "com.apple.Safari", name: "Safari", processIdentifier: 340),
        CaptureApplicationOption(bundleIdentifier: "com.apple.finder", name: "Finder", processIdentifier: 120),
    ]

    @Test func resolvesTheRememberedApplicationToItsCurrentProcess() throws {
        let matches = try CaptureSourceResolver.resolveApplication(bundleIdentifier: "com.google.Chrome", among: running)
        #expect(matches.map(\.processIdentifier) == [501])

        let scope = CaptureSourceResolver.scope(bundleIdentifier: "com.google.Chrome", applications: matches)
        #expect(scope.applicationBundleIdentifiers == ["com.google.Chrome"])
        #expect(scope.processIdentifiers == [501])
    }

    /// A relaunched application arrives under a new pid, and a filter built from an
    /// earlier snapshot never picks it up -- it delivers exact digital silence with
    /// no error. Resolution must therefore read the pid that exists right now.
    @Test func resolvingAgainPicksUpTheRelaunchedProcess() throws {
        let relaunched = [CaptureApplicationOption(bundleIdentifier: "com.apple.Safari", name: "Safari", processIdentifier: 9_001)]
        let matches = try CaptureSourceResolver.resolveApplication(bundleIdentifier: "com.apple.Safari", among: relaunched)
        #expect(matches.map(\.processIdentifier) == [9_001])
    }

    @Test func multipleProcessesForOneIdentifierAreAllIncluded() throws {
        let candidates = running + [
            CaptureApplicationOption(bundleIdentifier: "com.google.Chrome", name: "Google Chrome", processIdentifier: 77)
        ]
        let matches = try CaptureSourceResolver.resolveApplication(bundleIdentifier: "com.google.Chrome", among: candidates)
        #expect(matches.map(\.processIdentifier) == [77, 501])
    }

    /// The plan's rule: never silently broaden capture to all system audio.
    @Test func anApplicationThatIsNotRunningIsASourceSelectionError() {
        #expect(throws: CaptureServiceError.self) {
            try CaptureSourceResolver.resolveApplication(bundleIdentifier: "us.zoom.xos", among: running)
        }
        do {
            _ = try CaptureSourceResolver.resolveApplication(bundleIdentifier: "us.zoom.xos", among: running)
            Issue.record("Expected a source-selection error.")
        } catch let error as CaptureServiceError {
            guard case let .sourceSelection(bundleIdentifier, message) = error else {
                Issue.record("Expected .sourceSelection, got \(error).")
                return
            }
            #expect(bundleIdentifier == "us.zoom.xos")
            #expect(message.contains("never falls back"))
            #expect(error.failure.code == "capture.sourceSelection")
            #expect(error.failure.recoveryHint?.isEmpty == false)
        } catch {
            Issue.record("Unexpected error \(error).")
        }
    }

    @Test func noSelectionAtAllIsAlsoASourceSelectionError() {
        for identifier in [nil, "", "   "] as [String?] {
            do {
                _ = try CaptureSourceResolver.resolveApplication(bundleIdentifier: identifier, among: running)
                Issue.record("Expected a source-selection error for \(String(describing: identifier)).")
            } catch let error as CaptureServiceError {
                guard case let .sourceSelection(bundleIdentifier, _) = error else {
                    Issue.record("Expected .sourceSelection, got \(error).")
                    continue
                }
                #expect(bundleIdentifier == nil)
            } catch {
                Issue.record("Unexpected error \(error).")
            }
        }
    }

    /// Helper processes are never named in a filter: ScreenCaptureKit attributes
    /// their audio to the owning application, and shared identifiers such as
    /// `com.apple.WebKit.GPU` are used by every WebKit host on the machine.
    @Test func sharedHelperIdentifiersAreNeverAddedToTheScope() throws {
        let candidates = running + [
            CaptureApplicationOption(bundleIdentifier: "com.apple.WebKit.GPU", name: "Mail Graphics and Media", processIdentifier: 812),
            CaptureApplicationOption(bundleIdentifier: "com.apple.WebKit.GPU", name: "Safari Graphics and Media", processIdentifier: 813),
        ]
        let matches = try CaptureSourceResolver.resolveApplication(bundleIdentifier: "com.apple.Safari", among: candidates)
        #expect(matches.map(\.bundleIdentifier) == ["com.apple.Safari"])
        #expect(!CaptureSourceResolver.scope(bundleIdentifier: "com.apple.Safari", applications: matches)
            .processIdentifiers.contains(812))
    }

    // MARK: - Microphone

    private let microphones = [
        CaptureMicrophoneOption(uniqueID: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone"),
        CaptureMicrophoneOption(uniqueID: "USB-Podmic-01", name: "Podcast Microphone"),
    ]

    @Test func resolvesTheRememberedMicrophone() throws {
        let resolved = try CaptureSourceResolver.resolveMicrophone(
            uniqueID: "USB-Podmic-01",
            among: microphones,
            systemDefault: microphones[0]
        )
        #expect(resolved.uniqueID == "USB-Podmic-01")
        #expect(resolved.name == "Podcast Microphone")
    }

    @Test func fallsBackToTheSystemDefaultOnlyWhenNothingIsRemembered() throws {
        let resolved = try CaptureSourceResolver.resolveMicrophone(uniqueID: nil, among: microphones, systemDefault: microphones[0])
        #expect(resolved.uniqueID == "BuiltInMicrophoneDevice")
    }

    /// `.microphone` binds its device once at stream start and never follows the
    /// system default, so quietly substituting another device would record the
    /// whole meeting from an input nobody chose.
    @Test func aDisconnectedRememberedMicrophoneIsAnErrorNotASubstitution() {
        do {
            _ = try CaptureSourceResolver.resolveMicrophone(
                uniqueID: "USB-Podmic-01",
                among: [microphones[0]],
                systemDefault: microphones[0]
            )
            Issue.record("Expected a microphone error.")
        } catch let error as CaptureServiceError {
            guard case let .microphoneUnavailable(uniqueID, message) = error else {
                Issue.record("Expected .microphoneUnavailable, got \(error).")
                return
            }
            #expect(uniqueID == "USB-Podmic-01")
            #expect(message.contains("Reconnect"))
        } catch {
            Issue.record("Unexpected error \(error).")
        }
    }

    @Test func noInputDeviceAtAllIsAnError() {
        #expect(throws: CaptureServiceError.self) {
            try CaptureSourceResolver.resolveMicrophone(uniqueID: nil, among: [], systemDefault: nil)
        }
    }

    // MARK: - Permission classification

    /// The exit criterion: a revoked Screen & System Audio Recording grant has to
    /// arrive as something a person can act on, not as a generic content failure.
    @Test func aRevokedScreenRecordingGrantBecomesAnActionableError() {
        let declined = NSError(
            domain: SCStreamErrorDomainForTests,
            code: -3801,
            userInfo: [NSLocalizedDescriptionKey: "The user declined TCCs for application, window, display capture"]
        )
        let error = CaptureServiceError.classifyShareableContentFailure(declined)
        guard case .screenRecordingPermissionDenied = error else {
            Issue.record("Expected .screenRecordingPermissionDenied, got \(error).")
            return
        }
        #expect(error.failure.code == "capture.permissionDenied")
        #expect(error.failure.recoveryHint?.contains("Screen & System Audio Recording") == true)
        #expect(error.failure.recoveryHint?.contains("System Settings") == true)
    }

    @Test func anUnrelatedContentFailureStaysAContentFailureWithAHint() {
        let unrelated = NSError(domain: "io.example", code: 42, userInfo: [NSLocalizedDescriptionKey: "the window server is unavailable"])
        let error = CaptureServiceError.classifyShareableContentFailure(unrelated)
        guard case let .shareableContent(message) = error else {
            Issue.record("Expected .shareableContent, got \(error).")
            return
        }
        #expect(message.contains("window server"))
        #expect(error.failure.recoveryHint?.isEmpty == false)
    }
}

/// `SCStreamError.errorDomain` spelled out, so the test states the value it
/// depends on rather than reflecting the implementation back at itself.
private let SCStreamErrorDomainForTests = "com.apple.ScreenCaptureKit.SCStreamErrorDomain"
