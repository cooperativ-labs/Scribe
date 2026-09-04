import CoreAudio
import Foundation
import ScribeAppCore

/// Watches the system's default output route so an active recording can mark
/// the point where its acoustic echo path changed.
///
/// ScreenCaptureKit keeps delivering audio across ordinary route changes, so
/// there is no stream callback from which this fact can be recovered. Core
/// Audio's default-output property is the source of truth for physical route
/// changes; duplicate callbacks are coalesced by device identity.
final class OutputDeviceMonitor: @unchecked Sendable {
    typealias DeviceProvider = @Sendable () -> AudioDeviceIdentity?
    typealias Handler = @Sendable (OutputDeviceChange) -> Void

    private let queue = DispatchQueue(label: "io.cooperativ.scribe.output-device-monitor")
    private let lock = NSLock()
    private let deviceProvider: DeviceProvider
    private let now: @Sendable () -> Date
    private let handler: Handler
    private var previousDevice: AudioDeviceIdentity?
    private var listener: AudioObjectPropertyListenerBlock?

    init(
        deviceProvider: @escaping DeviceProvider = OutputDeviceMonitor.systemDefaultOutput,
        now: @escaping @Sendable () -> Date = Date.init,
        handler: @escaping Handler
    ) {
        self.deviceProvider = deviceProvider
        self.now = now
        self.handler = handler
        previousDevice = deviceProvider()
    }

    func start() {
        lock.lock()
        guard listener == nil else {
            lock.unlock()
            return
        }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refresh()
        }
        listener = block
        lock.unlock()

        var address = Self.defaultOutputAddress
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            block
        )
        guard status != noErr else { return }
        lock.withLock { listener = nil }
    }

    func stop() {
        let block = lock.withLock { () -> AudioObjectPropertyListenerBlock? in
            defer { listener = nil }
            return listener
        }
        guard let block else { return }
        var address = Self.defaultOutputAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            block
        )
    }

    /// Re-reads the route after a Core Audio notification. Kept internal so the
    /// duplicate and previous/current semantics can be tested without changing
    /// the machine's real output device.
    func refresh() {
        guard let current = deviceProvider() else { return }
        let previous = lock.withLock { () -> AudioDeviceIdentity? in
            guard previousDevice != current else { return current }
            let old = previousDevice
            previousDevice = current
            return old
        }
        guard previous != current else { return }
        handler(OutputDeviceChange(occurredAt: now(), previousDevice: previous, currentDevice: current))
    }

    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func systemDefaultOutput() -> AudioDeviceIdentity? {
        var address = defaultOutputAddress
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &device
        ) == noErr, device != kAudioObjectUnknown,
        let uniqueID = stringProperty(kAudioDevicePropertyDeviceUID, of: device),
        let name = stringProperty(kAudioObjectPropertyName, of: device) else {
            return nil
        }
        return AudioDeviceIdentity(uniqueID: uniqueID, name: name)
    }

    private static func stringProperty(
        _ selector: AudioObjectPropertySelector,
        of device: AudioObjectID
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanaged: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &unmanaged) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return unmanaged?.takeRetainedValue() as String?
    }
}
