import Foundation

/// How the helper left, for the message on a structured crash failure.
struct WorkerProcessExit: Sendable, Equatable {
    let status: Int32
    let wasSignal: Bool

    var summary: String {
        wasSignal ? "was killed by signal \(status)" : "exited with status \(status)"
    }
}

/// One item in the ordered stream of things that can arrive from the helper.
enum WorkerInboxItem: Sendable {
    case envelope(WorkerEnvelope)
    /// A framing or decoding fault. The transport stops after delivering one.
    case wireFault(WorkerWireFormatError)
    /// Standard output reached end of file: the helper is finished or gone.
    case closed
    /// The awaiting task was cancelled, not the helper.
    case cancelled
}

/// An ordered hand-off between the reader thread and the awaiting client.
///
/// A plain lock rather than an `AsyncStream` because framing order is the whole
/// point here: two `Task`s enqueuing into an actor have no defined order, and a
/// reordered record would silently corrupt the stage sequence.
final class WorkerMessageInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [WorkerInboxItem] = []
    private var waiter: CheckedContinuation<WorkerInboxItem, Never>?
    private var isClosed = false

    func deliver(_ item: WorkerInboxItem) {
        lock.lock()
        if case .closed = item {
            if isClosed { lock.unlock(); return }
            isClosed = true
        }
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: item)
            return
        }
        pending.append(item)
        lock.unlock()
    }

    func next() async -> WorkerInboxItem {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<WorkerInboxItem, Never>) in
                lock.lock()
                if !pending.isEmpty {
                    let item = pending.removeFirst()
                    lock.unlock()
                    continuation.resume(returning: item)
                    return
                }
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(returning: .cancelled)
                    return
                }
                waiter = continuation
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let waiting = waiter
            waiter = nil
            lock.unlock()
            waiting?.resume(returning: .cancelled)
        }
    }
}

/// Owns the child process, its pipes, and newline framing.
///
/// Standard output is read by a single dedicated thread so records reach the
/// client in the order the helper wrote them. Standard error is diagnostic
/// only; a bounded tail of it is kept to explain a crash.
final class WorkerProcessTransport: @unchecked Sendable {
    /// Enough standard-error text to explain a failure without letting a
    /// chatty helper grow the host's memory.
    static let retainedDiagnosticBytes = 8_192

    let inbox = WorkerMessageInbox()

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let diagnostics = Pipe()
    private let lock = NSLock()
    private var diagnosticTail = Data()
    private var started = false
    private var recordedExit: WorkerProcessExit?

    init(executableURL: URL, arguments: [String], environment: [String: String], currentDirectoryURL: URL?) {
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectoryURL
        process.standardInput = input
        process.standardOutput = output
        process.standardError = diagnostics
        // Recorded rather than waited for: `waitUntilExit` runs the calling
        // thread's run loop, which deadlocks a Swift concurrency thread.
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            lock.lock()
            recordedExit = WorkerProcessExit(status: process.terminationStatus, wasSignal: process.terminationReason == .uncaughtSignal)
            lock.unlock()
        }
    }

    func start() throws {
        try process.run()
        lock.lock(); started = true; lock.unlock()
        startThread(named: "TranscriptionWorker stdout reader", body: readStandardOutput)
        startThread(named: "TranscriptionWorker stderr reader", body: readStandardError)
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return started && process.isRunning
    }

    /// The child's process identifier, for host diagnostics and for a test that
    /// needs to end the helper the way the operating system would.
    var processIdentifier: Int32? {
        lock.lock(); defer { lock.unlock() }
        return started ? process.processIdentifier : nil
    }

    var diagnosticOutput: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: diagnosticTail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func send(_ envelope: WorkerEnvelope) throws {
        let record = try WorkerWireFormat.encode(envelope)
        try input.fileHandleForWriting.write(contentsOf: record)
    }

    /// Closes standard input so a helper that is waiting for more work exits.
    func closeInput() {
        try? input.fileHandleForWriting.close()
    }

    /// Ends the helper. `SIGTERM` first; the caller escalates by calling
    /// `kill()` when the helper does not leave within its grace period.
    func terminate() {
        guard isRunning else { return }
        process.terminate()
    }

    func kill() {
        guard isRunning else { return }
        Foundation.kill(process.processIdentifier, SIGKILL)
    }

    /// How the helper left, or nil while it is still running. Never blocks. A
    /// transport that was never started has nothing to wait for.
    var exitStatus: WorkerProcessExit? {
        lock.lock(); defer { lock.unlock() }
        return started ? recordedExit : WorkerProcessExit(status: 0, wasSignal: false)
    }

    private func startThread(named name: String, body: @escaping @Sendable () -> Void) {
        let thread = Thread(block: body)
        thread.name = name
        thread.start()
    }

    private func readStandardOutput() {
        let handle = output.fileHandleForReading
        var pending = Data()
        var faulted = false
        while !faulted {
            let data = handle.availableData
            guard !data.isEmpty else { break }
            pending.append(data)
            while let separator = pending.firstIndex(of: WorkerWireFormat.recordSeparator) {
                let record = Data(pending[pending.startIndex ..< separator])
                pending.removeSubrange(pending.startIndex ... separator)
                guard !record.isEmpty else { continue }
                do { inbox.deliver(.envelope(try WorkerWireFormat.decode(record))) }
                catch let error as WorkerWireFormatError { inbox.deliver(.wireFault(error)); faulted = true; break }
                catch { inbox.deliver(.wireFault(.malformedMessage(error.localizedDescription))); faulted = true; break }
            }
            // An unterminated record already past the bound can never become
            // valid, so refuse it now rather than buffering without limit.
            if !faulted, pending.count > WorkerWireFormat.maximumMessageBytes {
                inbox.deliver(.wireFault(.messageTooLarge(actualBytes: pending.count, limitBytes: WorkerWireFormat.maximumMessageBytes)))
                faulted = true
            }
        }
        inbox.deliver(.closed)
    }

    private func readStandardError() {
        let handle = diagnostics.fileHandleForReading
        while true {
            let data = handle.availableData
            guard !data.isEmpty else { break }
            lock.lock()
            diagnosticTail.append(data)
            if diagnosticTail.count > Self.retainedDiagnosticBytes {
                diagnosticTail.removeFirst(diagnosticTail.count - Self.retainedDiagnosticBytes)
            }
            lock.unlock()
        }
    }
}
