#if os(iOS)
import AVFoundation
import Foundation
import UIKit

@MainActor
public final class MicrophoneRecorder: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var capacityMonitor: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    public var onStopped: ((String?) -> Void)?
    public var isRecording: Bool { recorder?.isRecording == true }
    public var duration: TimeInterval { recorder?.currentTime ?? 0 }
    public override init() {
        super.init()
        let center = NotificationCenter.default
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification,
                     AVAudioSession.mediaServicesWereResetNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let interrupted = notification.name == AVAudioSession.interruptionNotification
                    && (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
                let lostRoute = notification.name == AVAudioSession.routeChangeNotification
                    && (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
                let reset = notification.name == AVAudioSession.mediaServicesWereResetNotification
                if interrupted || lostRoute || reset {
                    Task { @MainActor [weak self] in self?.stop(notice: "Recording stopped because the audio session or input changed. Your recording has been saved.") }
                }
            })
        }
    }
    public func start(at url: URL) async throws {
        guard recorder == nil else { throw MobileError.message("A recording is already active.") }
        guard await AVAudioApplication.requestRecordPermission() else {
            throw MobileError.message("Microphone access is denied. Enable Scribe in Settings → Privacy & Security → Microphone. Importing files does not require microphone access.")
        }
        try Task.checkCancellation()
        guard UIApplication.shared.applicationState == .active else {
            throw MobileError.message("Open Scribe to start recording.")
        }
        let session = AVAudioSession.sharedInstance()
        do {
            try StorageCapacity.require(StorageCapacity.recordingReserve, at: url.deletingLastPathComponent())
            try session.setCategory(.record, mode: .default, options: [.allowBluetoothHFP])
            try session.setActive(true)
            let value = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
            value.delegate = self
            guard value.prepareToRecord() else { throw MobileError.message("Cannot create the recording. Check available storage.") }
            try MeetingStore.protectAudio(url)
            guard value.record() else { throw MobileError.message("Microphone recording could not start. Another app may be using the microphone.") }
            recorder = value
            capacityMonitor = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    do { try StorageCapacity.require(StorageCapacity.recordingReserve, at: url) }
                    catch { self?.stop(notice: "Recording stopped because storage is nearly full. Your recording has been saved."); return }
                }
            }
        } catch {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
    }
    public func stop(notice: String? = nil) {
        guard let value = recorder else { return }
        recorder = nil
        capacityMonitor?.cancel(); capacityMonitor = nil
        value.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        onStopped?(notice)
    }
    nonisolated public func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let identity = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in
            guard let self, let current = self.recorder, ObjectIdentifier(current) == identity else { return }
            self.stop(notice: flag ? nil : "Recording ended unexpectedly. Review the saved audio.")
        }
    }
    nonisolated public func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let message = error?.localizedDescription ?? "Recording failed. Check available storage."
        let identity = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in
            guard let self, let current = self.recorder, ObjectIdentifier(current) == identity else { return }
            self.stop(notice: message)
        }
    }
}
#endif
