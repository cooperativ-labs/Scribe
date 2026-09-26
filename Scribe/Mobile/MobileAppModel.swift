import AVFoundation
import Observation
import ScribeMobile
import SwiftUI

@MainActor @Observable
final class MobileAppModel {
    var meetings: [Meeting] = []
    var selection: UUID?
    var error: String?
    var modelsInstalled = false
    var checkingModels = true
    /// Non-nil while the pinned models are downloading into the Scribe folder.
    var modelDownload: ModelLibrary.DownloadProgress?
    var modelDownloadError: String?
    var busy = false
    var recordingID: UUID?
    var processingID: UUID?
    var playingID: UUID?
    var player: AVAudioPlayer?
    let store: MeetingStore
    let models: ModelLibrary
    let processor: MeetingProcessor
    let recorder = MicrophoneRecorder()
    private var work: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var downloadBackgroundTask = UIBackgroundTaskIdentifier.invalid
    private var downloadExpired = false

    init() throws {
        let root = try MeetingStore.defaultRoot()
        store = try MeetingStore(root: root.appending(path: "Meetings"))
        guard let manifest = Bundle.main.url(forResource: "model_manifest", withExtension: "json") else {
            throw MobileError.message("The model manifest is missing from this app.")
        }
        let modelsDirectory = try ModelLibrary.defaultDirectory()
        // Earlier builds kept models in private Application Support; move them into the Scribe folder.
        let legacy = root.appending(path: "Models")
        if FileManager.default.fileExists(atPath: legacy.path), !FileManager.default.fileExists(atPath: modelsDirectory.path) {
            try? FileManager.default.moveItem(at: legacy, to: modelsDirectory)
        }
        // Creating the folder up front makes Scribe appear in Files before the first download.
        try MeetingStore.privateDirectory(modelsDirectory)
        models = try ModelLibrary(directory: modelsDirectory, manifestURL: manifest)
        processor = MeetingProcessor(store: store)
        recorder.onStopped = { [weak self] notice in self?.recordingStopped(notice: notice) }
    }
    var selected: Meeting? { meetings.first { $0.id == selection } }
    var canStart: Bool { !busy && recordingID == nil && processingID == nil }
    func load() async {
        do { meetings = try await store.list(recoverInterrupted: true) }
        catch { self.error = error.localizedDescription }
        await refreshModels()
    }
    func refreshModels() async {
        guard modelDownload == nil else { return }
        checkingModels = true
        modelsInstalled = await models.isInstalled()
        checkingModels = false
    }
    private func update(_ meeting: Meeting) {
        if let index = meetings.firstIndex(where: { $0.id == meeting.id }) { meetings[index] = meeting }
        else { meetings.insert(meeting, at: 0) }
    }
    func record() {
        guard canStart else { return }
        busy = true; stopPlayback()
        work = Task {
            var pending: Meeting?
            defer { busy = false }
            do {
                let meeting = try await store.create(title: "Meeting \(Date().formatted(date: .abbreviated, time: .shortened))",
                                                     sourceFilename: "recording.caf", state: .recording)
                pending = meeting
                try await recorder.start(at: store.sourceURL(meeting))
                recordingID = meeting.id; selection = meeting.id; update(meeting)
            } catch {
                if let pending { try? await store.delete(pending.id) }
                self.error = error.localizedDescription
            }
        }
    }
    func stopRecording() { recorder.stop() }
    private func recordingStopped(notice: String?) {
        guard let id = recordingID else { return }
        recordingID = nil; busy = true
        work = Task {
            defer { busy = false }
            do {
                var meeting = try await store.load(id)
                meeting.state = .ready; meeting.notice = notice
                let source = try await store.sourceURL(meeting)
                if let audio = try? AVAudioFile(forReading: source) {
                    meeting.duration = Double(audio.length) / audio.processingFormat.sampleRate
                }
                try await store.save(meeting); update(meeting)
            } catch { self.error = error.localizedDescription }
        }
    }
    func importFile(_ url: URL) async {
        guard canStart else { return }
        busy = true; defer { busy = false }
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        var pending: Meeting?
        do {
            let suffix = url.pathExtension.filter { $0.isLetter || $0.isNumber }.prefix(12)
            var meeting = try await store.create(title: url.deletingPathExtension().lastPathComponent,
                                                 sourceFilename: "source.\(suffix.isEmpty ? "audio" : String(suffix))", state: .importing)
            pending = meeting
            let destination = try await store.sourceURL(meeting)
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            try StorageCapacity.require(Int64(size) + StorageCapacity.recordingReserve, at: destination.deletingLastPathComponent())
            // Keep the security-scoped access alive until a private local snapshot exists.
            try await Task.detached {
                let coordinator = NSFileCoordinator()
                var coordinationError: NSError?
                var copyError: Error?
                coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { readable in
                    do { try FileManager.default.copyItem(at: readable, to: destination); try MeetingStore.protectAudio(destination) }
                    catch { copyError = error }
                }
                if let error = coordinationError ?? copyError { throw error }
            }.value
            meeting.state = .ready
            try await store.save(meeting)
            update(meeting); selection = meeting.id
        } catch {
            if let pending { try? await store.delete(pending.id) }
            self.error = error.localizedDescription
        }
    }
    /// Downloads into the Scribe folder like the desktop installer. Verified files survive a
    /// cancellation or interruption, so tapping Download again resumes with the remaining files.
    func downloadModels() {
        guard downloadTask == nil, !busy else { return }
        modelDownloadError = nil; downloadExpired = false
        modelDownload = .init(completedBytes: 0, totalBytes: models.downloadBytes, file: "")
        // Keep the screen awake and ask for time to finish if Scribe briefly leaves the foreground.
        UIApplication.shared.isIdleTimerDisabled = true
        downloadBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Scribe model download") { [weak self] in
            MainActor.assumeIsolated {
                self?.downloadExpired = true
                self?.downloadTask?.cancel()
                self?.endDownloadBackgroundTask()
            }
        }
        downloadTask = Task {
            do {
                try await models.download { [weak self] progress in
                    Task { @MainActor in if self?.downloadTask != nil { self?.modelDownload = progress } }
                }
            } catch is CancellationError {
                if downloadExpired { modelDownloadError = "The download paused while Scribe was in the background. Download again to continue; finished files are kept." }
            } catch {
                modelDownloadError = error.localizedDescription
            }
            downloadTask = nil; modelDownload = nil
            UIApplication.shared.isIdleTimerDisabled = false
            endDownloadBackgroundTask()
            await refreshModels()
        }
    }
    func cancelModelDownload() { downloadTask?.cancel() }
    private func endDownloadBackgroundTask() {
        guard downloadBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(downloadBackgroundTask)
        downloadBackgroundTask = .invalid
    }
    func installModels(_ url: URL) async {
        guard canStart, modelDownload == nil else { return }
        busy = true; defer { busy = false }
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do { try await models.install(from: url); modelsInstalled = true; modelDownloadError = nil }
        catch { self.error = error.localizedDescription }
    }
    func process(_ meeting: Meeting) {
        guard canStart, modelDownload == nil else { return }
        processingID = meeting.id; stopPlayback()
        work = Task {
            defer { processingID = nil }
            do {
                let manifest = try await models.validatedManifest()
                let directory = await models.directory
                let inference = LocalMeetingInference(manifest: manifest, models: directory)
                try await processor.run(id: meeting.id, inference: inference) { [weak self] meeting in
                    await self?.update(meeting)
                }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    func pause() { work?.cancel() }
    func backgrounded() {
        if processingID != nil || (busy && recordingID == nil) { work?.cancel() }
        stopPlayback()
    }
    func renameSpeaker(_ id: String, name: String, meeting: Meeting) async {
        var meeting = meeting
        meeting.speakerNames[id] = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : name
        do { try await store.save(meeting); update(meeting) } catch { self.error = error.localizedDescription }
    }
    func delete(_ meeting: Meeting) async {
        guard canStart else { return }
        stopPlayback()
        do {
            try await store.delete(meeting.id)
            meetings.removeAll { $0.id == meeting.id }
            if selection == meeting.id { selection = nil }
        } catch { self.error = error.localizedDescription }
    }
    func play(_ meeting: Meeting, at seconds: Double? = nil) async {
        guard canStart else { return }
        do {
            if playingID != meeting.id || player == nil {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                try AVAudioSession.sharedInstance().setActive(true)
                let source = try await store.sourceURL(meeting)
                player = try AVAudioPlayer(contentsOf: source)
                playingID = meeting.id
            }
            if let seconds { player?.currentTime = seconds }
            if player?.isPlaying == true && seconds == nil { player?.pause() } else { player?.play() }
        } catch { stopPlayback(); self.error = error.localizedDescription }
    }
    func stopPlayback() {
        player?.stop(); player = nil; playingID = nil
        if recordingID == nil { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }
}
