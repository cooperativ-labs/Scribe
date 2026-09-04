import Foundation

/// Runs recorder commands strictly one at a time, in submission order.
///
/// Menu clicks and global shortcuts both enqueue here, so a shortcut pressed
/// while a menu-issued start is still opening the capture cannot interleave
/// with it. Each unit of work awaits its predecessor, which keeps ordering
/// intact even when a command suspends.
@MainActor
public final class RecordingCommandQueue {
    /// Commands accepted so far, in order. Useful for asserting that a redundant
    /// command was still observed even though it did nothing.
    public private(set) var acceptedCommands: [RecordingCommand] = []

    private var tail: Task<Void, Never>?
    private var pendingCount = 0

    public init() {}

    public func enqueue(_ command: RecordingCommand, _ work: @escaping @MainActor () async -> Void) {
        acceptedCommands.append(command)
        pendingCount += 1
        let previous = tail
        tail = Task { @MainActor in
            await previous?.value
            await work()
            pendingCount -= 1
        }
    }

    /// Awaits every command enqueued so far, including work enqueued while
    /// waiting. Tests use this instead of sleeping.
    public func waitUntilIdle() async {
        while pendingCount > 0, let task = tail {
            await task.value
        }
        tail = nil
    }
}
