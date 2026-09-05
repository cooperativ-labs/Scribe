import AppKit
import CoreAudio
import Foundation
import os

// MARK: - Probes

/// A process that currently has an audio input device running.
public struct AudioInputProcess: Equatable, Hashable, Sendable {
    public let processIdentifier: pid_t
    public let bundleIdentifier: String

    public init(processIdentifier: pid_t, bundleIdentifier: String) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
    }
}

/// Answers "who has the microphone open right now?".
///
/// Behind a protocol so the detector's decisions can be exercised without a
/// real call in progress.
public protocol MicrophoneActivityProbing: Sendable {
    func processesRunningInput() -> [AudioInputProcess]
}

/// What a browser said about its open tabs.
public enum BrowserTabProbeResult: Equatable, Sendable {
    case urls([URL])
    /// The tabs could not be read. The message is shown in Settings so a person
    /// can grant Automation access; detection falls back to microphone use alone.
    case unavailable(String)
}

/// Reads the addresses of a browser's open tabs.
public protocol BrowserTabURLProbing: Sendable {
    func tabURLs(ofApplicationWithBundleIdentifier bundleIdentifier: String) async -> BrowserTabProbeResult
}

/// Whether an application is installed, from Launch Services.
public protocol InstalledApplicationChecking: Sendable {
    func isInstalled(_ application: MeetingApplication) -> Bool
}

// MARK: - Detector

/// Notices calls in the applications the person chose, and says which one.
///
/// The signal is the operating system's own accounting of microphone use:
/// CoreAudio publishes a process object for every audio client, with a flag
/// for whether it is running input. A calling application that has the
/// microphone open is on a call; when it lets go, the call is over. Nothing here
/// depends on window titles or on the application's own scripting.
///
/// For a browser the microphone alone says "some tab is on a call". The tab's
/// address decides whether it is one of the chosen domains.
@MainActor
public final class MeetingDetector: ObservableObject {
    @Published public private(set) var detectedMeeting: DetectedMeeting?
    /// Why a browser's tabs could not be read, if that happened. Cleared once a
    /// probe succeeds again.
    @Published public private(set) var browserProbeIssue: String?
    public var onChange: (@MainActor (DetectedMeeting?) -> Void)?

    /// How long the microphone may be closed before the call is considered
    /// over. Muting does not close the device, but a reconnecting call briefly
    /// does, and that should not read as two meetings.
    public let endGracePeriod: TimeInterval
    public let pollInterval: TimeInterval
    /// How often a browser on a live call is re-asked which tabs it has open.
    public let browserRefreshInterval: TimeInterval

    private let settings: ScribeSettings
    private let microphoneProbe: any MicrophoneActivityProbing
    private let browserProbe: any BrowserTabURLProbing
    private let now: @MainActor () -> Date
    private let logger = Logger(subsystem: "com.scribe.app", category: "MeetingDetector")
    /// Only ever touched on the main actor; marked so `deinit` may invalidate it.
    nonisolated(unsafe) private var timer: Timer?
    private var pollTask: Task<Void, Never>?
    private var lastSeenActive: Date?
    private var lastBrowserRefresh: Date?

    public init(
        settings: ScribeSettings,
        microphoneProbe: any MicrophoneActivityProbing = CoreAudioMicrophoneActivityProbe(),
        browserProbe: any BrowserTabURLProbing = AppleEventBrowserTabURLProbe(),
        pollInterval: TimeInterval = 2,
        endGracePeriod: TimeInterval = 5,
        browserRefreshInterval: TimeInterval = 10,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.settings = settings
        self.microphoneProbe = microphoneProbe
        self.browserProbe = browserProbe
        self.pollInterval = pollInterval
        self.endGracePeriod = endGracePeriod
        self.browserRefreshInterval = browserRefreshInterval
        self.now = now
    }

    deinit {
        timer?.invalidate()
        pollTask?.cancel()
    }

    /// Begins polling. Cheap enough to leave running for the life of the app:
    /// one CoreAudio property read every couple of seconds, and a browser is
    /// asked about its tabs only while it has the microphone open.
    public func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedulePoll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        schedulePoll()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        pollTask?.cancel()
        pollTask = nil
    }

    private func schedulePoll() {
        guard pollTask == nil else { return } // A slow browser must not stack polls.
        pollTask = Task { [weak self] in
            await self?.poll()
            self?.pollTask = nil
        }
    }

    /// One detection pass. Public so tests drive it directly with a stubbed clock.
    public func poll() async {
        guard settings.meetingDetectionEnabled else {
            publish(nil)
            return
        }

        let processes = microphoneProbe.processesRunningInput()
        let candidates = matches(in: processes)
        let time = now()

        // Stay with the current call while it is still live, even if a second
        // application has opened the microphone too: what the person is being
        // offered must not change under them.
        if let current = detectedMeeting,
           let stillLive = candidates.first(where: { $0.application == current.application }) {
            guard current.application.isBrowser,
                  time.timeIntervalSince(lastBrowserRefresh ?? .distantPast) >= browserRefreshInterval else {
                lastSeenActive = time
                return
            }
            // A browser is re-asked about its tabs only now and then: the answer
            // costs a process launch, and a tab does not change domain often.
            lastBrowserRefresh = time
            if let refreshed = await resolve(stillLive, at: current.detectedAt) {
                if refreshed.domain != current.domain { publish(refreshed) }
                lastSeenActive = time
            } else {
                // The browser answered and no tab is on a chosen domain any more:
                // the meeting tab was closed and the microphone is open for
                // something else. That is definite, so no grace period applies.
                publish(nil)
            }
            return
        }

        for candidate in candidates {
            if candidate.application.isBrowser { lastBrowserRefresh = time }
            if let meeting = await resolve(candidate, at: time) {
                lastSeenActive = time
                publish(meeting)
                return
            }
        }

        // Nothing is on a call. End the current detection only after the grace
        // period so a device reopening mid-call is not reported as a new call.
        guard detectedMeeting != nil else { return }
        if let lastSeenActive, time.timeIntervalSince(lastSeenActive) < endGracePeriod { return }
        publish(nil)
    }

    private struct Candidate {
        let application: MeetingApplication
        let bundleIdentifier: String
        let process: AudioInputProcess
    }

    /// Enabled catalog applications with the microphone open, in catalog order.
    private func matches(in processes: [AudioInputProcess]) -> [Candidate] {
        MeetingApplication.catalog.compactMap { application in
            guard settings.isMeetingDetectionEnabled(for: application) else { return nil }
            guard let process = processes.first(where: { application.matches(processBundleIdentifier: $0.bundleIdentifier) }) else { return nil }
            let mainBundle = application.bundleIdentifiers.first { identifier in
                process.bundleIdentifier.lowercased().hasPrefix(identifier.lowercased())
            } ?? application.bundleIdentifiers[0]
            return Candidate(application: application, bundleIdentifier: mainBundle, process: process)
        }
    }

    /// Confirms a candidate, asking a browser about its tabs when domains are configured.
    private func resolve(_ candidate: Candidate, at time: Date) async -> DetectedMeeting? {
        func meeting(domain: String?) -> DetectedMeeting {
            DetectedMeeting(
                application: candidate.application,
                bundleIdentifier: candidate.bundleIdentifier,
                processIdentifier: candidate.process.processIdentifier,
                domain: domain,
                detectedAt: time
            )
        }

        guard candidate.application.isBrowser else { return meeting(domain: nil) }
        let domains = settings.meetingDomains
        // With no domains chosen, a browser is treated like any other application.
        guard !domains.isEmpty else { return meeting(domain: nil) }

        switch await browserProbe.tabURLs(ofApplicationWithBundleIdentifier: candidate.bundleIdentifier) {
        case .urls(let urls):
            if browserProbeIssue != nil { browserProbeIssue = nil }
            guard let domain = urls.lazy.compactMap({ MeetingDomain.matchingDomain(for: $0, among: domains) }).first else {
                return nil
            }
            return meeting(domain: domain)
        case .unavailable(let reason):
            // The microphone says a call is on; without the address the domain
            // filter cannot be applied, and missing a meeting is the worse error.
            let message = "\(candidate.application.name)'s tabs could not be read, so any call in it is reported: \(reason)"
            if browserProbeIssue != message {
                browserProbeIssue = message
                logger.notice("\(message, privacy: .public)")
            }
            return meeting(domain: nil)
        }
    }

    private func publish(_ meeting: DetectedMeeting?) {
        guard meeting != detectedMeeting else { return }
        detectedMeeting = meeting
        if meeting == nil { lastSeenActive = nil }
        if let meeting {
            logger.info("Detected a call: \(meeting.displayName, privacy: .public) (pid \(meeting.processIdentifier))")
        } else {
            logger.info("Call ended")
        }
        onChange?(meeting)
    }
}

// MARK: - CoreAudio probe

/// Lists processes running audio input through CoreAudio's process objects.
///
/// Available since macOS 14.2 and needing no permission: it is the same
/// accounting the orange microphone indicator is drawn from.
public struct CoreAudioMicrophoneActivityProbe: MicrophoneActivityProbing {
    public init() {}

    public func processesRunningInput() -> [AudioInputProcess] {
        processObjects().compactMap { object in
            guard uint32(of: object, selector: kAudioProcessPropertyIsRunningInput) == 1 else { return nil }
            guard let pid = pid(of: object) else { return nil }
            // Some audio clients have no bundle; they cannot be a catalog application.
            guard let bundle = bundleIdentifier(of: object), !bundle.isEmpty else { return nil }
            return AudioInputProcess(processIdentifier: pid, bundleIdentifier: bundle)
        }
    }

    private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private func processObjects() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private func uint32(of object: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private func pid(of object: AudioObjectID) -> pid_t? {
        var address = address(kAudioProcessPropertyPID)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private func bundleIdentifier(of object: AudioObjectID) -> String? {
        var address = address(kAudioProcessPropertyBundleID)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

// MARK: - Browser probe

/// Asks a Chromium browser for its tab addresses over Apple Events.
///
/// Every Chromium browser ships Chrome's scripting dictionary, and Arc does
/// too, so one script serves them all. The event is sent from a short-lived
/// `osascript` so a stalled browser can be cut off without blocking the app;
/// macOS attributes the request to Scribe and asks the person once, per
/// browser, whether to allow it.
public struct AppleEventBrowserTabURLProbe: BrowserTabURLProbing {
    public let timeout: TimeInterval

    public init(timeout: TimeInterval = 4) {
        self.timeout = timeout
    }

    public func tabURLs(ofApplicationWithBundleIdentifier bundleIdentifier: String) async -> BrowserTabProbeResult {
        let script = """
        with timeout of \(Int(timeout.rounded(.up))) seconds
            tell application id "\(bundleIdentifier)"
                set addresses to {}
                repeat with aWindow in windows
                    repeat with aTab in tabs of aWindow
                        set end of addresses to (URL of aTab as text)
                    end repeat
                end repeat
            end tell
        end timeout
        set AppleScript's text item delimiters to linefeed
        return addresses as text
        """
        do {
            let output = try await ScriptRunner.run(arguments: ["-e", script], timeout: timeout + 1)
            let urls = output.split(separator: "\n").compactMap { URL(string: String($0).trimmingCharacters(in: .whitespaces)) }
            return .urls(urls)
        } catch let error as ScriptRunner.Failure {
            return .unavailable(error.explanation)
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }
}

/// Runs `osascript` with a deadline.
enum ScriptRunner {
    struct Failure: Error {
        let status: Int32
        let stderr: String
        let timedOut: Bool

        /// The user-facing reason, recognising the Automation refusal that a
        /// person can fix in System Settings.
        var explanation: String {
            if timedOut { return "the browser did not answer in time." }
            if stderr.contains("-1743") {
                return "allow Scribe to control it under System Settings › Privacy & Security › Automation."
            }
            if stderr.contains("-600") { return "the browser is not running." }
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "osascript exited with status \(status)." : trimmed
        }
    }

    static func run(arguments: [String], timeout: TimeInterval) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        let outcome = Outcome()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            process.terminationHandler = { process in
                // Read only after exit: the child has closed its end, so this
                // returns without waiting for more output.
                let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let timedOut = outcome.didTimeOut()
                if process.terminationStatus == 0, !timedOut {
                    continuation.resume(returning: out)
                } else {
                    continuation.resume(throwing: Failure(status: process.terminationStatus, stderr: err, timedOut: timedOut))
                }
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                outcome.markTimedOut()
                process.terminate()
            }
        }
    }

    /// Whether the deadline fired, shared between the timeout and the exit handler.
    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var timedOut = false
        func markTimedOut() { lock.withLock { timedOut = true } }
        func didTimeOut() -> Bool { lock.withLock { timedOut } }
    }
}

// MARK: - Installed applications

/// Launch Services' answer to "is this installed?", used to decide which
/// browsers Settings offers.
public struct LaunchServicesInstalledApplicationChecker: InstalledApplicationChecking {
    public init() {}

    public func isInstalled(_ application: MeetingApplication) -> Bool {
        application.bundleIdentifiers.contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    }
}
