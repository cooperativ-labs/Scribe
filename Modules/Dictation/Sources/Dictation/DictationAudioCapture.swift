@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import AppKit

public enum DictationCaptureError: LocalizedError {
    case inputUnavailable
    case selectedMicrophoneUnavailable
    case conversionFailed
    case emptyRecording

    public var errorDescription: String? {
        switch self {
        case .inputUnavailable: "The microphone input is unavailable."
        case .selectedMicrophoneUnavailable: "The selected microphone is unavailable."
        case .conversionFailed: "Microphone audio could not be converted to 16 kHz mono."
        case .emptyRecording: "No microphone audio was captured."
        }
    }
}

/// Bounded five-minute PCM store. The input tap can append without hopping to
/// the main actor; snapshots and RMS reads take the same short lock.
private final class AudioRing: @unchecked Sendable {
    static let capacity = 16_000 * 60 * 5
    private let lock = NSLock()
    private var storage = [Float](repeating: 0, count: capacity)
    private var count = 0
    private var cursor = 0
    private var level: Float = 0

    func append(_ pointer: UnsafePointer<Float>, count incoming: Int) {
        lock.lock(); defer { lock.unlock() }
        guard incoming > 0 else { return }
        var sum: Float = 0
        for index in 0..<incoming {
            let sample = pointer[index]
            storage[cursor] = sample
            cursor = (cursor + 1) % Self.capacity
            count = min(Self.capacity, count + 1)
            sum += sample * sample
        }
        level = sqrt(sum / Float(incoming))
    }

    func snapshot() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        guard count > 0 else { return [] }
        let start = (cursor - count + Self.capacity) % Self.capacity
        return (0..<count).map { storage[(start + $0) % Self.capacity] }
    }

    func rms() -> Float { lock.lock(); defer { lock.unlock() }; return level }
}

@MainActor
public final class DictationAudioCapture {
    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var ring = AudioRing()
    private var selectedMicrophoneID: String?
    private(set) public var isRecording = false
    public var level: Float { ring.rms() }
    public var onRecoveryFailure: (@MainActor (String) -> Void)?

    public init() {}

    public func start(microphoneID: String?) throws {
        stop()
        selectedMicrophoneID = microphoneID
        ring = AudioRing()
        try startEngine()
        isRecording = true
        observeEngine()
    }

    private func observeEngine() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.restartAfterConfigurationChange() }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording else { return }
                self.stop()
                self.onRecoveryFailure?("Dictation stopped when the Mac went to sleep. Try again after waking.")
            }
        }
    }

    public func stop() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        sleepObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRecording = false
    }

    public func finish() throws -> [Float] {
        stop()
        let samples = ring.snapshot()
        guard !samples.isEmpty else { throw DictationCaptureError.emptyRecording }
        return samples
    }

    private func restartAfterConfigurationChange() {
        guard isRecording else { return }
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        do {
            try startEngine()
            observeEngine()
        }
        catch {
            stop()
            onRecoveryFailure?("The microphone changed during dictation. Select an available input and try again.")
        }
    }

    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let selectedMicrophoneID {
            guard let deviceID = Self.audioDeviceID(for: selectedMicrophoneID),
                  let audioUnit = input.audioUnit,
                  AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                                       kAudioUnitScope_Global, 0, [deviceID],
                                       UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
                throw DictationCaptureError.selectedMicrophoneUnavailable
            }
        }
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                               channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw DictationCaptureError.inputUnavailable
        }
        let ring = self.ring
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16_000 / inputFormat.sampleRate) + 64)
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if supplied { inputStatus.pointee = .noDataNow; return nil }
                supplied = true
                inputStatus.pointee = .haveData
                return buffer
            }
            if status != .error, let pointer = output.floatChannelData?[0] {
                ring.append(pointer, count: Int(output.frameLength))
            }
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    private static func audioDeviceID(for uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return nil }
        for device in devices {
            var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                       mScope: kAudioObjectPropertyScopeGlobal,
                                                       mElement: kAudioObjectPropertyElementMain)
            var value: Unmanaged<CFString>?
            var valueSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            if AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &valueSize, &value) == noErr,
               let value {
                let deviceUID = value.takeRetainedValue() as String
                if deviceUID == uid { return device }
            }
        }
        return nil
    }
}
