import Foundation

/// A small stdin control plane that continues reading `cancel` envelopes while
/// a model stage is running on the request-processing task. Cancellation is
/// intentionally observed only between stages, where each prior result is
/// already an atomically committed file.
public final class WorkerRequestLoop: @unchecked Sendable {
    private let configuration: WorkerJobRunner.Configuration
    private let state = State()
    private let writer = EnvelopeWriter()

    public init(configuration: WorkerJobRunner.Configuration) {
        self.configuration = configuration
    }

    public func run() {
        let reader = Thread { [weak self] in self?.readStandardInput() }
        reader.name = "TranscriptionWorker stdin reader"
        reader.start()

        while let envelope = state.next() {
            guard envelope.kind == .request else {
                writer.write(WorkerProtocol.error(requestID: envelope.requestID, code: "invalid_request", message: "Only request and cancel envelopes may be sent to the worker."))
                continue
            }
            handle(envelope)
        }
    }

    private func readStandardInput() {
        var pending = Data()
        while true {
            let data = FileHandle.standardInput.availableData
            guard !data.isEmpty else { break }
            pending.append(data)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending.prefix(upTo: newline)
                pending.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                receive(Data(line))
            }
        }
        if !pending.isEmpty { receive(pending) }
        state.finish()
    }

    private func receive(_ data: Data) {
        do {
            let envelope = try WorkerProtocol.decode(data)
            if envelope.kind == .cancel {
                state.cancel(envelope.requestID)
                writer.write(WorkerEnvelope(kind: .stageResult, requestID: envelope.requestID, payload: .object([
                    "stage": .string("cancel"), "accepted": .bool(true),
                ])))
            } else {
                state.enqueue(envelope)
            }
        } catch let error as WorkerProtocolError {
            writer.write(WorkerProtocol.error(requestID: "unknown", code: "protocol_error", message: error.localizedDescription))
        } catch {
            writer.write(WorkerProtocol.error(requestID: "unknown", code: "worker_error", message: error.localizedDescription))
        }
    }

    private func handle(_ envelope: WorkerEnvelope) {
        guard let payload = envelope.payload.objectValue,
              let operation = payload["operation"]?.stringValue else {
            writer.write(WorkerProtocol.error(requestID: envelope.requestID, code: "invalid_request", message: "Expected payload.operation."))
            return
        }
        switch operation {
        case "handshake":
            writer.write(WorkerEnvelope(kind: .stageResult, requestID: envelope.requestID, payload: .object([
                "stage": .string("handshake"), "protocolVersion": .number(Double(WorkerEnvelope.currentVersion)),
                "workerVersion": .string("0.2.0"), "networking": .string("disabled"),
                "runtimeDownloads": .bool(false), "telemetry": .bool(false), "fluidAudio": .string("0.12.4"),
            ])))
        case "validate_assets":
            validateAssets(requestID: envelope.requestID)
        case "run":
            if state.isCancelled(envelope.requestID) {
                writer.write(WorkerProtocol.error(requestID: envelope.requestID, code: "cancelled", message: "The request was cancelled before its first stage boundary."))
                return
            }
            let runner = WorkerJobRunner(configuration: configuration)
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                await runner.run(requestID: envelope.requestID, payload: payload, isCancelled: { self.state.isCancelled(envelope.requestID) }, emit: { self.writer.write($0) })
                semaphore.signal()
            }
            semaphore.wait()
        default:
            writer.write(WorkerProtocol.error(requestID: envelope.requestID, code: "unsupported_operation", message: "Unsupported operation \(operation)."))
        }
    }

    private func validateAssets(requestID: String) {
        do {
            let manifest = try ModelManifest.load(from: configuration.manifestURL)
            guard !manifest.telemetry.enabled, !manifest.telemetry.runtimeDownloadsAllowed else {
                writer.write(WorkerProtocol.error(requestID: requestID, code: "unsafe_manifest", message: "The manifest must disable telemetry and runtime downloads.")); return
            }
            let report = manifest.validate(modelsDirectory: configuration.modelsDirectory)
            guard report.isValid else {
                let data = try JSONEncoder().encode(report)
                writer.write(WorkerProtocol.error(requestID: requestID, code: "model_setup_incomplete", message: "Required offline model assets are missing, corrupt, or unreadable.", details: try JSONDecoder().decode(JSONValue.self, from: data))); return
            }
            writer.write(WorkerEnvelope(kind: .stageResult, requestID: requestID, payload: .object([
                "stage": .string("asset_validation"), "status": .string("ready"), "modelsDirectory": .string(configuration.modelsDirectory.path), "declaredOnDiskBytes": .number(Double(manifest.totalDeclaredOnDiskBytes)),
            ])))
        } catch { writer.write(WorkerProtocol.error(requestID: requestID, code: "model_setup_incomplete", message: error.localizedDescription)) }
    }
}

private final class State: @unchecked Sendable {
    private let condition = NSCondition(); private var queue: [WorkerEnvelope] = []; private var cancelled = Set<String>(); private var closed = false
    func enqueue(_ envelope: WorkerEnvelope) { condition.lock(); defer { condition.unlock() }; queue.append(envelope); condition.signal() }
    func cancel(_ requestID: String) { condition.lock(); defer { condition.unlock() }; cancelled.insert(requestID) }
    func isCancelled(_ requestID: String) -> Bool { condition.lock(); defer { condition.unlock() }; return cancelled.contains(requestID) }
    func finish() { condition.lock(); defer { condition.unlock() }; closed = true; condition.broadcast() }
    func next() -> WorkerEnvelope? { condition.lock(); defer { condition.unlock() }; while queue.isEmpty && !closed { condition.wait() }; return queue.isEmpty ? nil : queue.removeFirst() }
}

private final class EnvelopeWriter: @unchecked Sendable {
    private let lock = NSLock()
    func write(_ envelope: WorkerEnvelope) {
        lock.lock(); defer { lock.unlock() }
        do { var data = try WorkerProtocol.encode(envelope); data.append(0x0A); FileHandle.standardOutput.write(data) }
        catch { FileHandle.standardError.write(Data("Failed to write worker response: \(error.localizedDescription)\n".utf8)) }
    }
}
