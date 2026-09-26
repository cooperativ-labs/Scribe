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
    private let modelsDirectoryProvider: @Sendable () async -> URL
    private var worker: WorkerClient?
    private var workerModelsDirectory: URL?
    private var warmTask: Task<WorkerClient, Error>?
    private var idleTask: Task<Void, Never>?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var keepLoaded = true
    private var idleMinutes = 10
    private var requestBusy = false
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var inFlight = false
    private var pendingUnload = false
    private var epoch = 0

    public init(
        installation: WorkerInstallation,
        modelsDirectoryProvider: @escaping @Sendable () async -> URL
    ) {
        self.installation = WorkerInstallation(
            executableURL: installation.executableURL,
            manifestURL: installation.manifestURL,
            modelsDirectoryURL: installation.modelsDirectoryURL,
            mode: "dictation"
        )
        self.modelsDirectoryProvider = modelsDirectoryProvider
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
        if let warmTask {
            let startedAtEpoch = epoch
            let client = try await warmTask.value
            guard epoch == startedAtEpoch else { throw CancellationError() }
            if worker == nil { worker = client }
            return
        }
        let startedAtEpoch = epoch
        let task = Task<WorkerClient, Error> {
            // Resolve the same folder Settings validates on every warm/dictate,
            // including while a helper is resident. Never use the helper's cwd.
            let modelsDirectory = await modelsDirectoryProvider()
            guard epoch == startedAtEpoch else { throw CancellationError() }
            if let worker, workerModelsDirectory == modelsDirectory, await worker.isRunning {
                return worker
            }
            if let worker {
                self.worker = nil
                await worker.shutdown()
            }
            guard epoch == startedAtEpoch else { throw CancellationError() }
            workerModelsDirectory = modelsDirectory
            let installation = WorkerInstallation(
                executableURL: self.installation.executableURL,
                manifestURL: self.installation.manifestURL,
                modelsDirectoryURL: modelsDirectory,
                mode: "dictation"
            )
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
            if epoch == startedAtEpoch { warmTask = nil }
            throw error
        }
    }

    public func dictate(audioURL: URL, runDirectoryURL: URL, language: String? = nil) async throws -> DictationTranscript {
        // Actors are reentrant across worker awaits. Serialize preview and final
        // requests, including a new session started before the old one drains.
        if requestBusy {
            await withCheckedContinuation { requestWaiters.append($0) }
        } else {
            requestBusy = true
        }
        defer {
            if requestWaiters.isEmpty { requestBusy = false }
            else { requestWaiters.removeFirst().resume() }
        }
        try Task.checkCancellation()
        try await warm()
        try Task.checkCancellation()
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
