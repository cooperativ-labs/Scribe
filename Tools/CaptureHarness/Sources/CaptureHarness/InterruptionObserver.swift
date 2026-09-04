import AppKit
import CoreAudio
import CoreMedia
import Foundation

/// One observed system event, stamped on the host clock so it can be placed against the
/// buffer stream afterwards.
struct InterruptionMarker: Sendable {
    let name: String
    let detail: String
    let hostSeconds: Double
    let wallClock: String

    var journalObject: [String: Any] {
        ["record": "interruption", "event": name, "detail": detail, "hostSeconds": hostSeconds, "markerWallClock": wallClock]
    }
}

/// Watches the system conditions IMPLEMENTATION_PLAN.md section 8 requires a capture to be
/// probed against: output-route changes, microphone disconnection, screen lock, sleep/wake,
/// and exit or relaunch of the selected application.
///
/// NSWorkspace and distributed notifications are delivered through a run loop, and this tool's
/// main thread is parked in Swift concurrency rather than running one, so the observer owns a
/// dedicated thread with its own run loop. Core Audio property listeners take a dispatch queue
/// and need no run loop.
final class InterruptionObserver: @unchecked Sendable {
    private let handler: @Sendable (InterruptionMarker) -> Void
    private let watchedBundleIdentifiers: Set<String>
    private let audioQueue = DispatchQueue(label: "io.cooperativ.scribe.captureharness.interruptions")
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var tokens: [NSObjectProtocol] = []
    private var audioListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private let ready = DispatchSemaphore(value: 0)

    init(watching bundleIdentifiers: Set<String>, handler: @escaping @Sendable (InterruptionMarker) -> Void) {
        self.watchedBundleIdentifiers = bundleIdentifiers
        self.handler = handler
    }

    private func emit(_ name: String, _ detail: String) {
        handler(InterruptionMarker(
            name: name,
            detail: detail,
            hostSeconds: CMClockGetTime(CMClockGetHostTimeClock()).seconds,
            wallClock: Timestamp.iso8601()
        ))
    }

    func start() {
        startAudioListeners()
        let thread = Thread { [weak self] in
            guard let self else { return }
            self.runLoop = CFRunLoopGetCurrent()
            self.startNotificationObservers()
            self.ready.signal()
            // A port-less run loop returns immediately, so keep one source alive.
            let timer = Timer(timeInterval: 3600, repeats: true) { _ in }
            RunLoop.current.add(timer, forMode: .default)
            RunLoop.current.run()
        }
        thread.name = "capture-harness.interruption-observer"
        thread.start()
        self.thread = thread
        _ = ready.wait(timeout: .now() + 5)
    }

    func stop() {
        for (address, block) in audioListeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, audioQueue, block)
        }
        audioListeners.removeAll()
        for token in tokens {
            DistributedNotificationCenter.default().removeObserver(token)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        tokens.removeAll()
        if let runLoop { CFRunLoopStop(runLoop) }
        runLoop = nil
        thread = nil
    }

    // MARK: - Core Audio

    private func startAudioListeners() {
        addAudioListener(selector: kAudioHardwarePropertyDefaultOutputDevice, name: "output-route-changed") {
            "default output is now \(AudioDeviceCatalog.describeDefault(scope: .output))"
        }
        addAudioListener(selector: kAudioHardwarePropertyDefaultInputDevice, name: "input-route-changed") {
            "default input is now \(AudioDeviceCatalog.describeDefault(scope: .input))"
        }
        addAudioListener(selector: kAudioHardwarePropertyDevices, name: "audio-device-list-changed") {
            "devices now: \(AudioDeviceCatalog.deviceNames().joined(separator: ", "))"
        }
    }

    private func addAudioListener(selector: AudioObjectPropertySelector, name: String, detail: @escaping @Sendable () -> String) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.emit(name, detail())
        }
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, audioQueue, block)
        if status == noErr { audioListeners.append((address, block)) }
    }

    // MARK: - Notifications

    private func startNotificationObservers() {
        let distributed = DistributedNotificationCenter.default()
        for (notification, name) in [
            ("com.apple.screenIsLocked", "screen-locked"),
            ("com.apple.screenIsUnlocked", "screen-unlocked"),
        ] {
            tokens.append(distributed.addObserver(forName: Notification.Name(notification), object: nil, queue: nil) { [weak self] _ in
                self?.emit(name, notification)
            })
        }

        let workspace = NSWorkspace.shared.notificationCenter
        for (notification, name) in [
            (NSWorkspace.willSleepNotification, "system-will-sleep"),
            (NSWorkspace.didWakeNotification, "system-did-wake"),
            (NSWorkspace.screensDidSleepNotification, "screens-did-sleep"),
            (NSWorkspace.screensDidWakeNotification, "screens-did-wake"),
            (NSWorkspace.sessionDidResignActiveNotification, "session-resigned-active"),
            (NSWorkspace.sessionDidBecomeActiveNotification, "session-became-active"),
        ] {
            tokens.append(workspace.addObserver(forName: notification, object: nil, queue: nil) { [weak self] _ in
                self?.emit(name, notification.rawValue)
            })
        }

        guard !watchedBundleIdentifiers.isEmpty else { return }
        for (notification, name) in [
            (NSWorkspace.didTerminateApplicationNotification, "watched-application-exited"),
            (NSWorkspace.didLaunchApplicationNotification, "watched-application-launched"),
        ] {
            tokens.append(workspace.addObserver(forName: notification, object: nil, queue: nil) { [weak self] note in
                guard let self,
                      let application = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let identifier = application.bundleIdentifier,
                      self.watchedBundleIdentifiers.contains(identifier) else { return }
                self.emit(name, "\(identifier) pid \(application.processIdentifier)")
            })
        }
    }
}

enum AudioDeviceCatalog {
    enum Scope { case input, output }

    static func describeDefault(scope: Scope) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: scope == .output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else {
            return "unknown"
        }
        return "\(name(of: device)) (uid \(uid(of: device)), \(nominalSampleRate(of: device)) Hz)"
    }

    static func deviceNames() -> [String] {
        devices().map { "\(name(of: $0))" }
    }

    static func devices() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func name(of device: AudioObjectID) -> String { string(device, kAudioObjectPropertyName) ?? "unnamed" }
    static func uid(of device: AudioObjectID) -> String { string(device, kAudioDevicePropertyDeviceUID) ?? "unknown" }

    static func nominalSampleRate(of device: AudioObjectID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr else { return 0 }
        return rate
    }

    private static func string(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // Core Audio returns these string properties +1 retained, so the value has to come
        // back through Unmanaged rather than as a directly written managed reference.
        var unmanaged: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &unmanaged) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return unmanaged?.takeRetainedValue() as String?
    }
}
