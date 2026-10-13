import Dispatch
import Foundation
import os
import Vocabulary
import Transcription

public struct DictationTranscript: Sendable, Equatable {
    public var rawText: String?
    public var vocabularyWarning: String?
    public let text: String
    public let hasSpeech: Bool
    public init(text: String, hasSpeech: Bool) { self.text = text; self.hasSpeech = hasSpeech }
}

/// Owns a separate resident helper. A crashed helper is discarded and the next
/// warm or dictate call launches a new one; batch transcription is untouched.
///
/// A cold helper needs tens of seconds before its first request: the ASR
/// weights are mapped and the Neural Engine programs compiled. So a helper is
/// never thrown away while a request is using it. An unload that arrives
/// mid-request is applied once the request has finished, and cancelling a
/// request abandons its result without ending the helper.
///
/// The optional vocabulary booster is a second model with its own cold start.
/// A warm sends the current snapshot so the helper prepares it too, and the
/// helper is not called ready while a snapshot with terms still needs it.
/// Logs carry reasons, readiness and timings, never transcript or vocabulary text.
public actor DictationEngine {
    private static let logger = Logger(subsystem: "com.scribe.app", category: "DictationHelper")
    private let vocabularySnapshot: @Sendable () throws -> VocabularySnapshot
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
    /// A request, including the warm it may need first, is using the helper.
    private var inFlight = false
    private var pendingUnload = false
    private var pendingUnloadReason = "requested"
    private var epoch = 0
    /// The booster readiness the current helper last reported, and for which
    /// snapshot. Cleared whenever the helper is replaced.
    private var boosterReadiness: String?
    private var boosterSnapshot: VocabularySnapshot?
    /// Why the previous helper went away, for the next launch's log line.
    private var lastHelperExit: String?

    public init(
        installation: WorkerInstallation,
        modelsDirectoryProvider: @escaping @Sendable () async -> URL,
        vocabularySnapshot: @escaping @Sendable () throws -> VocabularySnapshot = { .init(revision: nil, terms: []) }
    ) {
        self.installation = WorkerInstallation(
            executableURL: installation.executableURL,
            manifestURL: installation.manifestURL,
            modelsDirectoryURL: installation.modelsDirectoryURL,
            mode: "dictation"
        )
        self.modelsDirectoryProvider = modelsDirectoryProvider
        self.vocabularySnapshot = vocabularySnapshot
    }

    public func configure(keepLoaded: Bool, idleMinutes: Int) {
        self.keepLoaded = keepLoaded
        self.idleMinutes = max(1, idleMinutes)
        scheduleIdleUnload()
        if pressureSource == nil {
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global())
            source.setEventHandler { [weak self, weak source] in
                let critical = source?.data.contains(.critical) ?? false
                Task { await self?.memoryPressureChanged(critical: critical) }
            }
            source.resume()
            pressureSource = source
        }
    }

    /// Whether a dictate call can be answered without launching or warming a
    /// helper. The coordinator uses this to say "Loading model…" rather than
    /// "Transcribing…" for the tens of seconds a cold start takes.
    public func isReady() async -> Bool {
        guard warmTask == nil, let worker else { return false }
        guard await worker.isRunning else { return false }
        return boosterSettled(for: (try? vocabularySnapshot()) ?? .init(revision: nil, terms: []))
    }

    /// Nothing more to prepare for this snapshot: it has no terms, the helper
    /// retains a ready booster, the assets are unavailable (dictation reports
    /// the warning and stays fast), or the helper found no usable term in it.
    func boosterSettled(for snapshot: VocabularySnapshot) -> Bool {
        if snapshot.isEmpty { return true }
        switch boosterReadiness {
        case "ready", "unavailable": return true
        case "not_needed": return boosterSnapshot == snapshot
        default: return false
        }
    }

    /// Only text and aliases cross to the helper; notes stay in the library.
    static func warmPayload(_ snapshot: VocabularySnapshot) -> [String: WorkerJSONValue] {
        guard !snapshot.isEmpty else { return [:] }
        var vocabulary: [String: WorkerJSONValue] = [
            "terms": .array(snapshot.terms.map { .object(["text": .string($0.text), "aliases": .array($0.aliases.map { .string($0) })]) }),
        ]
        if let revision = snapshot.revision { vocabulary["revision"] = .string(revision) }
        return ["vocabulary": .object(vocabulary)]
    }

    private func recordWarm(_ response: [String: WorkerJSONValue], snapshot: VocabularySnapshot, pid: Int32?) {
        let booster = response["vocabularyBooster"]?.objectValue
        if let readiness = booster?["readiness"]?.stringValue {
            boosterReadiness = readiness
            boosterSnapshot = snapshot
        } else if snapshot.isEmpty == false {
            // An older helper that ignores the snapshot: do not wait on it forever.
            boosterReadiness = "unavailable"
            boosterSnapshot = snapshot
        }
        let total = response["timings"]?.objectValue?["totalSeconds"]?.numberValue ?? -1
        Self.logger.notice("Dictation helper \(pid ?? -1, privacy: .public) warm: speech \(response["speech"]?.stringValue ?? "unknown", privacy: .public), vocabulary booster \(booster?["readiness"]?.stringValue ?? (snapshot.isEmpty ? "not_requested" : "unknown"), privacy: .public) (\(booster?["source"]?.stringValue ?? "none", privacy: .public), model load \(booster?["modelLoadSeconds"]?.numberValue ?? 0, format: .fixed(precision: 3), privacy: .public) s), total \(total, format: .fixed(precision: 3), privacy: .public) s")
    }

    /// A warning releases a helper the person did not ask to keep; only
    /// critical pressure overrides "keep model loaded". Neither interrupts a
    /// request in flight, which `unload` lets finish first.
    func memoryPressureChanged(critical: Bool) async {
        guard critical || !keepLoaded else {
            Self.logger.notice("Memory pressure warning ignored: keep model loaded is on")
            return
        }
        await unload(reason: critical ? "memory_pressure_critical" : "memory_pressure_warning")
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
        let snapshot = (try? vocabularySnapshot()) ?? .init(revision: nil, terms: [])
        let task = Task<WorkerClient, Error> {
            // Resolve the same folder Settings validates on every warm/dictate,
            // including while a helper is resident. Never use the helper's cwd.
            let modelsDirectory = await modelsDirectoryProvider()
            guard epoch == startedAtEpoch else { throw CancellationError() }
            if let worker, workerModelsDirectory == modelsDirectory, await worker.isRunning {
                // Speech is resident; prepare a booster the snapshot now needs.
                if !boosterSettled(for: snapshot) {
                    let response = try await worker.dictationCommand("warm", payload: Self.warmPayload(snapshot))
                    guard epoch == startedAtEpoch else { throw CancellationError() }
                    recordWarm(response, snapshot: snapshot, pid: await worker.processIdentifier)
                }
                return worker
            }
            let launchReason: String
            if let worker {
                launchReason = workerModelsDirectory == modelsDirectory ? "helper_not_running" : "models_directory_changed"
                self.worker = nil
                await worker.shutdown()
            } else {
                launchReason = lastHelperExit.map { "after_\($0)" } ?? "first_use"
            }
            boosterReadiness = nil
            boosterSnapshot = nil
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
                let pid = await client.processIdentifier
                Self.logger.notice("Dictation helper \(pid ?? -1, privacy: .public) launched: \(launchReason, privacy: .public)")
                let response = try await client.dictationCommand("warm", payload: Self.warmPayload(snapshot))
                guard epoch == startedAtEpoch else { throw CancellationError() }
                recordWarm(response, snapshot: snapshot, pid: pid)
                return client
            } catch {
                Self.logger.error("Dictation helper warm failed: \(String(describing: type(of: error)), privacy: .public)")
                lastHelperExit = "warm_failed"
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
            // A standalone warm applies an unload that waited for it; a
            // request's warm leaves that to `endRequest`.
            if pendingUnload, !inFlight { await unload(reason: pendingUnloadReason) } else { scheduleIdleUnload() }
        } catch {
            if epoch == startedAtEpoch { warmTask = nil }
            if pendingUnload, !inFlight { await unload(reason: pendingUnloadReason) }
            throw error
        }
    }

    public func dictate(audioURL: URL, runDirectoryURL: URL, language: String? = nil) async throws -> DictationTranscript {
        let snapshot = try vocabularySnapshot()
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(to: runDirectoryURL.appendingPathComponent("vocabulary.json"), options: .atomic)
        inFlight = true
        do {
            try await warm()
            try Task.checkCancellation()
        } catch {
            await endRequest()
            throw error
        }
        guard let worker else {
            await endRequest()
            throw WorkerFailure(code: "worker_unavailable", message: "Dictation helper is unavailable.")
        }
        var payload: [String: WorkerJSONValue] = [
            "vocabularyPath": .string("vocabulary.json"),
            "audioPath": .string(audioURL.path),
            "runDirectory": .string(runDirectoryURL.path),
        ]
        if let language { payload["language"] = .string(language) }
        // The helper answers this request whether or not the caller still wants
        // the answer. Cancelling waits for it, a few seconds of inference at
        // most, rather than ending a helper that took tens of seconds to warm.
        let command = Task { try await worker.dictationCommand("dictate", payload: payload) }
        let outcome = await command.result
        switch outcome {
        case let .success(response):
            await endRequest()
            try Task.checkCancellation()
            var transcript = DictationTranscript(
                text: response["text"]?.stringValue ?? "",
                hasSpeech: response["status"]?.stringValue != "no_speech"
            )
            transcript.rawText = response["rawText"]?.stringValue
            transcript.vocabularyWarning = response["vocabularyWarning"]?.stringValue
            await recordDictation(response, snapshot: snapshot, worker: worker)
            return transcript
        case let .failure(error):
            // The channel or the helper failed; the next request launches anew.
            let pid = await worker.processIdentifier ?? -1
            Self.logger.error("Dictation helper \(pid, privacy: .public) failed during a request; it will be relaunched")
            if self.worker === worker {
                self.worker = nil
                boosterReadiness = nil
                boosterSnapshot = nil
                lastHelperExit = "helper_failure"
            }
            await worker.shutdown()
            await endRequest()
            throw error
        }
    }

    private func recordDictation(_ response: [String: WorkerJSONValue], snapshot: VocabularySnapshot, worker: WorkerClient) async {
        let booster = response["vocabularyBooster"]?.objectValue
        let readiness = booster?["readiness"]?.stringValue
        let source = booster?["source"]?.stringValue
        if self.worker === worker, let readiness {
            if boosterReadiness == "ready", readiness == "ready", let source, source != "retained" {
                // The process stayed; only its booster had to be loaded again.
                let pid = await worker.processIdentifier ?? -1
                Self.logger.notice("Vocabulary booster \(source, privacy: .public) inside resident helper \(pid, privacy: .public)")
            }
            if readiness != "not_needed" || boosterReadiness == nil {
                boosterReadiness = readiness
                boosterSnapshot = snapshot
            }
        }
        guard let timings = response["timings"]?.objectValue else { return }
        func value(_ key: String) -> Double { timings[key]?.numberValue ?? 0 }
        Self.logger.notice("Dictation timings: speech recognition \(value("speechRecognitionSeconds"), format: .fixed(precision: 3), privacy: .public) s, VAD \(value("vadSeconds"), format: .fixed(precision: 3), privacy: .public) s, vocabulary \(readiness ?? "none", privacy: .public)/\(source ?? "none", privacy: .public) preparation \(value("vocabularyPreparationSeconds"), format: .fixed(precision: 3), privacy: .public) s (model load \(value("vocabularyModelLoadSeconds"), format: .fixed(precision: 3), privacy: .public) s), acoustic spotting \(value("acousticSpottingSeconds"), format: .fixed(precision: 3), privacy: .public) s, candidate comparison \(value("candidateComparisonSeconds"), format: .fixed(precision: 3), privacy: .public) s, helper total \(value("totalSeconds"), format: .fixed(precision: 3), privacy: .public) s")
    }

    public func unload() async {
        await unload(reason: "requested")
    }

    func unload(reason: String) async {
        // A request or a warm in progress finishes first; the helper is then
        // released by `endRequest` or `warm`.
        if inFlight || warmTask != nil {
            pendingUnload = true
            pendingUnloadReason = reason
            Self.logger.notice("Dictation helper unload deferred until the current request finishes: \(reason, privacy: .public)")
            return
        }
        pendingUnload = false
        epoch += 1
        idleTask?.cancel()
        idleTask = nil
        // Detached before any await so a request arriving meanwhile launches its
        // own helper instead of sharing one that is on its way out.
        guard let departing = worker else { return }
        worker = nil
        workerModelsDirectory = nil
        boosterReadiness = nil
        boosterSnapshot = nil
        lastHelperExit = reason
        let pid = await departing.processIdentifier ?? -1
        Self.logger.notice("Dictation helper \(pid, privacy: .public) unloading: \(reason, privacy: .public)")
        if await departing.isRunning {
            _ = try? await departing.dictationCommand("unload")
        }
        await departing.shutdown()
    }

    private func endRequest() async {
        inFlight = false
        if pendingUnload { await unload(reason: pendingUnloadReason) } else { scheduleIdleUnload() }
    }

    private func scheduleIdleUnload() {
        idleTask?.cancel()
        guard !keepLoaded, worker != nil else { return }
        let minutes = idleMinutes
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard !Task.isCancelled else { return }
            await self?.unload(reason: "idle_timer_\(minutes)_minutes")
        }
    }
}
