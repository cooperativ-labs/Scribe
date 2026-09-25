import Dispatch
import Foundation
import Transcription

public struct DictationTranscript: Sendable, Equatable {
    public let text: String
    public let hasSpeech: Bool
    public init(text: String, hasSpeech: Bool) { self.text = text; self.hasSpeech = hasSpeech }
}

/// Owns a separate resident helper. A crashed helper is discarded and the next
/// warm or dictate call launches a new one; batch transcription is untouched.
public actor DictationEngine {
    private let installation: WorkerInstallation
    private var worker: WorkerClient?
    private var warmTask: Task<WorkerClient, Error>?
    private var idleTask: Task<Void, Never>?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var keepLoaded = true
    private var idleMinutes = 10
    private var inFlight = false
    private var pendingUnload = false
    private var epoch = 0

    public init(installation: WorkerInstallation) {
        self.installation = WorkerInstallation(
            executableURL: installation.executableURL,
            manifestURL: installation.manifestURL,
            modelsDirectoryURL: installation.modelsDirectoryURL,
            mode: "dictation"
        )
    }

    public func configure(keepLoaded: Bool, idleMinutes: Int) {
        self.keepLoaded = keepLoaded
        self.idleMinutes = max(1, idleMinutes)
        scheduleIdleUnload()
        if pressureSource == nil {
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global())
            source.setEventHandler { [weak self] in
                Task { await self?.unload() }
            }
            source.resume()
            pressureSource = source
        }
    }

    public func warm() async throws {
        if let worker, await worker.isRunning { return }
        if let warmTask {
            let startedAtEpoch = epoch
            let client = try await warmTask.value
            guard epoch == startedAtEpoch else { throw CancellationError() }
            if worker == nil { worker = client }
            return
        }
        let installation = self.installation
        let startedAtEpoch = epoch
        let task = Task<WorkerClient, Error> {
            let client = WorkerClient(configuration: .init(installation: installation))
            do {
                let handshake = try await client.handshake()
                guard handshake.networkingDisabled, handshake.runtimeDownloadsDisabled, handshake.telemetryDisabled else {
                    throw WorkerFailure(code: "unsafe_worker", message: "Dictation helper did not declare offline operation.")
                }
                _ = try await client.dictationCommand("warm")
                return client
            } catch {
                await client.shutdown()
                throw error
            }
        }
        warmTask = task
        do {
            let client = try await task.value
            guard epoch == startedAtEpoch else {
                await client.shutdown()
                throw CancellationError()
            }
            worker = client
            warmTask = nil
            scheduleIdleUnload()
        } catch {
            warmTask = nil
            throw error
        }
    }

    public func dictate(audioURL: URL, runDirectoryURL: URL, language: String? = nil) async throws -> DictationTranscript {
        try await warm()
        guard let worker else { throw WorkerFailure(code: "worker_unavailable", message: "Dictation helper is unavailable.") }
        var payload: [String: WorkerJSONValue] = [
            "audioPath": .string(audioURL.path),
            "runDirectory": .string(runDirectoryURL.path),
        ]
        if let language { payload["language"] = .string(language) }
        inFlight = true
        do {
            let response = try await worker.dictationCommand("dictate", payload: payload)
            inFlight = false
            if pendingUnload { await unload() }
            scheduleIdleUnload()
            return DictationTranscript(
                text: response["text"]?.stringValue ?? "",
                hasSpeech: response["status"]?.stringValue != "no_speech"
            )
        } catch {
            inFlight = false
            await worker.shutdown()
            self.worker = nil
            if pendingUnload { await unload() }
            throw error
        }
    }

    public func unload() async {
        if inFlight {
            pendingUnload = true
            return
        }
        pendingUnload = false
        epoch += 1
        idleTask?.cancel()
        idleTask = nil
        if let warmTask {
            _ = try? await warmTask.value
            self.warmTask = nil
        }
        if let worker {
            _ = try? await worker.dictationCommand("unload")
            await worker.shutdown()
        }
        worker = nil
    }

    private func scheduleIdleUnload() {
        idleTask?.cancel()
        guard !keepLoaded, worker != nil else { return }
        let minutes = idleMinutes
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard !Task.isCancelled else { return }
            await self?.unload()
        }
    }
}
