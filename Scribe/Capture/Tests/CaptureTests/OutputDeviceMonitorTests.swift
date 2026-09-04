import Foundation
import ScribeAppCore
import Testing
@testable import Capture

@Test func outputDeviceMonitorEmitsOnlyIdentityChangesWithPreviousDevice() throws {
    let devices = DeviceBox(AudioDeviceIdentity(uniqueID: "builtin", name: "Built-in Output"))
    let changes = ChangeBox()
    let instant = Date(timeIntervalSince1970: 1_786_000_000)
    let monitor = OutputDeviceMonitor(
        deviceProvider: { devices.value },
        now: { instant },
        handler: { changes.append($0) }
    )

    monitor.refresh()
    #expect(changes.values.isEmpty)

    devices.value = AudioDeviceIdentity(uniqueID: "headphones", name: "Wired Headphones")
    monitor.refresh()
    monitor.refresh()

    let change = try #require(changes.values.only)
    #expect(change.occurredAt == instant)
    #expect(change.previousDevice?.uniqueID == "builtin")
    #expect(change.currentDevice.uniqueID == "headphones")
}

@Test func outputDeviceMonitorReportsADeviceAppearingAfterNoInitialRoute() throws {
    let devices = DeviceBox(nil)
    let changes = ChangeBox()
    let monitor = OutputDeviceMonitor(deviceProvider: { devices.value }) { changes.append($0) }

    devices.value = AudioDeviceIdentity(uniqueID: "bluetooth", name: "Bluetooth Audio")
    monitor.refresh()

    let change = try #require(changes.values.only)
    #expect(change.previousDevice == nil)
    #expect(change.currentDevice.uniqueID == "bluetooth")
}

private final class DeviceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: AudioDeviceIdentity?

    init(_ value: AudioDeviceIdentity?) { stored = value }

    var value: AudioDeviceIdentity? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class ChangeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [OutputDeviceChange] = []

    var values: [OutputDeviceChange] { lock.withLock { stored } }
    func append(_ change: OutputDeviceChange) { lock.withLock { stored.append(change) } }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
