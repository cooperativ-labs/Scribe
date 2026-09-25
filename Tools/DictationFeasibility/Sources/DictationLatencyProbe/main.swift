@preconcurrency import AVFoundation
import Darwin
import FluidAudio
import Foundation
import TranscriptionWorkerSupport

@main struct DictationLatencyProbe {
    static func main() async throws {
        if CommandLine.arguments.dropFirst().first == "--vad" {
            await runVad(
                modelDirectory: URL(fileURLWithPath: CommandLine.arguments[2]),
                clips: CommandLine.arguments.dropFirst(3).map { URL(fileURLWithPath: $0) }
            )
            return
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let clips = CommandLine.arguments.dropFirst(2).map { URL(fileURLWithPath: $0) }
        let manifest = try ModelManifest.load(from: root.appending(path: "model_manifest.json"))
        let modelsURL = root.appending(path: "models", directoryHint: .isDirectory)
        print("baseline_rss_bytes=\(rss()) peak_bytes=\(peak())", terminator: "\n")
        let started = ContinuousClock.now
        var models: AsrModels? = try await OfflineModelLoader.loadASR(manifest: manifest, modelsDirectory: modelsURL)
        print("load_seconds=\(seconds(since: started)) rss_bytes=\(rss()) peak_bytes=\(peak())")
        var manager: AsrManager? = AsrManager(config: ASRConfig(sampleRate: ASRConstants.sampleRate, streamingEnabled: true))
        let managerStart = ContinuousClock.now
        try await manager!.loadModels(models!)
        print("manager_load_seconds=\(seconds(since: managerStart)) rss_bytes=\(rss()) peak_bytes=\(peak())")
        for clip in clips {
            var state = TdtDecoderState.make(decoderLayers: models!.version.decoderLayers)
            let start = ContinuousClock.now
            let result = try await manager!.transcribe(clip, decoderState: &state)
            print("clip=\(clip.lastPathComponent) seconds=\(seconds(since: start)) processing=\(result.processingTime) rss_bytes=\(rss()) peak_bytes=\(peak()) text=\(result.text.prefix(100))")
            fflush(stdout)
        }
        try await Task.sleep(for: .seconds(10))
        print("idle_10s_rss_bytes=\(rss()) peak_bytes=\(peak())")
        let unloadStart = ContinuousClock.now
        manager = nil
        models = nil
        print("unload_seconds=\(seconds(since: unloadStart)) rss_bytes=\(rss()) peak_bytes=\(peak())")
        let reloadStart = ContinuousClock.now
        models = try await OfflineModelLoader.loadASR(manifest: manifest, modelsDirectory: modelsURL)
        manager = AsrManager(config: ASRConfig(sampleRate: ASRConstants.sampleRate, streamingEnabled: true))
        try await manager!.loadModels(models!)
        print("reload_seconds=\(seconds(since: reloadStart)) rss_bytes=\(rss()) peak_bytes=\(peak())")
    }

    static func runVad(modelDirectory: URL, clips: [URL]) async {
        ModelHub.offlineMode = true
        do {
            let started = ContinuousClock.now
            let vad = try await VadManager(modelDirectory: modelDirectory)
            print("vad_load_seconds=\(seconds(since: started))")
            for clip in clips {
                let start = ContinuousClock.now
                let results = try await vad.process(clip)
                print("vad_clip=\(clip.lastPathComponent) seconds=\(seconds(since: start)) chunks=\(results.count)")
            }
            let start = ContinuousClock.now
            let silence = try await vad.process([Float](repeating: 0, count: 8_000))
            print("vad_silence_seconds=\(seconds(since: start)) chunks=\(silence.count)")
        } catch {
            print("vad_unavailable=\(error)")
        }
    }

    static func seconds(since start: ContinuousClock.Instant) -> Double {
        let c = start.duration(to: .now).components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }

    static func rss() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    static func peak() -> UInt64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return UInt64(usage.ru_maxrss)
    }
}
