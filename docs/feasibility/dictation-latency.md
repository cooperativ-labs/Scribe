# Resident dictation ASR and VAD feasibility (macOS 27)

## Setup

- 25 September 2026; MacBookPro18,3 (M1 Pro, 32 GB), macOS 27.0, Xcode 27.0.
- `Tools/DictationFeasibility` is an isolated Swift 6 package using the worker's `OfflineModelLoader`, the installed Parakeet TDT 0.6B v3 Core ML assets, and FluidAudio **0.15.7**. The package resolves the exact source from the existing release build and links its locally cached text-processing binary; it does not change the app or worker.
- Source: the first 30 seconds of `benchmark-files/CAB/meeting--cecb678e89d2e0bc89c9687e1c980d5b/runs/C465C5EC-6EFF-4C43-A472-2EB2367BFA78/prepared.wav`, cropped to 3, 10 and 30 seconds as 16 kHz mono Float32 WAV with FFmpeg. The 3-second clip contains speech (mean −25 dBFS), and the 10-second transcript begins with that speech.
- `DictationLatencyProbe` calls `OfflineModelLoader.loadASR`, creates one `AsrManager`, calls `loadModels`, then transcribes each URL with fresh `TdtDecoderState`. It drops the manager and models, then loads both again. The VAD path uses FluidAudio `VadManager` with its 256 ms Silero v6.2.1 Core ML model. That public 1 MB model was staged only under `/private/tmp/scribe-vad`; `ModelHub.offlineMode` remained on for the measurements. The installed worker manifest contains ASR and diarization assets, **not** this VAD asset.
- Timings are wall clock seconds from `ContinuousClock`. RSS comes from `MACH_TASK_BASIC_INFO`; peak RSS is `getrusage(ru_maxrss)`. They describe this process, not total GPU or Neural Engine memory. Values below are observed runs, not a statistical distribution.

## ASR results

| Condition | Model load | 3 s clip | 10 s clip | 30 s clip | Peak RSS | RSS after 10 s idle | Reload after release |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Unrestricted process, first run | 39.43 s | 0.136 s¹ | 0.130 s | 0.272 s | 524 MB | 202 MB | 1.42 s |
| Unrestricted process, cached run | 0.42 s | 0.134 s¹ | 0.130 s | 0.274 s | 454 MB | 110 MB | 0.43 s |
| Restricted tool process | 7.81 s | 0.707 s | 0.622 s | 1.765 s | not sampled | 2.24 GB immediately after 30 s clip | 7.77 s |

¹ The 3-second result was **empty** in unrestricted runs, including when it followed a 10-second utterance. The existing `ASRBenchmark` also returned empty for that clip in an unrestricted process (both `cpuAndNeuralEngine` and `cpuOnly`). The same clip produced “Good afternoon or morning everyone” in the restricted process. This is an unresolved correctness discrepancy, so the fast 3-second figure must not be presented as successful dictation latency. The 10-second and 30-second results contained speech in both environments. The latter used `AsrManager`'s in-memory path at its default 30-second threshold; the existing `ParakeetAdapter` uses a 15-second disk-backed threshold. A production dictation path should explicitly choose and test its intended buffer or URL mode.

The unrestricted process took about 0.01–0.02 seconds to drop model and manager references; RSS fell by roughly 50 MB immediately. The warm-cache reload numbers do not predict a load after memory pressure or reboot. The wide 0.42–39.43 second observed load range makes the proposal's “several seconds” warm-up wording too optimistic as a guarantee. A separate cold `ASRBenchmark` process took 11.1–11.3 seconds end to end for 3- and 10-second clips in the restricted tool environment; this includes manifest validation, model load and inference.

The unrestricted peak RSS of 454–524 MB is near the proposal's 465 MB estimate, but its **steady** RSS after ten seconds was 110–202 MB. The restricted process reported over 2 GB RSS; that environment also printed a Core ML sandbox-extension warning and ran several times slower. Do not use either number as a universal resident-memory promise. Measure memory in the signed worker under release conditions before choosing defaults for 8 GB Macs.

## VAD results

The model was absent from Scribe's staged assets and from FluidAudio's local cache. After staging the public v6.2.1 Core ML directory in temporary storage, two offline runs gave:

| Input | VAD chunks | Run 1 | Run 2 |
| --- | ---: | ---: | ---: |
| 3 s speech | 12 | 5.69 ms | 5.46 ms |
| 10 s speech | 40 | 10.49 ms | 9.62 ms |
| 30 s speech | 118 | 27.88 ms | 28.26 ms |
| 0.5 s zero silence | 2 | 0.418 ms | 0.444 ms |

VAD initialization took 325 ms on the first run and 39 ms with filesystem caches warm. The call uses `VadManager.process(URL)` for speech, so the speech timings include file reading and conversion; silence used `process([Float])`. They are therefore conservative for an in-memory capture path, but the two input paths are not perfectly comparable.

## Proposal changes needed

1. Section 7.1 should call 465 MB an approximate **peak process RSS**, not memory held continuously. Keep the idle-unload option, show a warming state, and avoid promising a fixed warm-up time.
2. Section 7 / the resident-engine objective must stage and validate the Silero VAD asset explicitly, or use an alternate gate. Merely depending on FluidAudio 0.15.7 does not make `VadManager` available offline; its convenience initializer otherwise tries the download path that Scribe forbids at runtime.
3. Before release, resolve the empty 3-second result on a signed, unrestricted worker with a representative dictation capture buffer. The current 3-second number cannot support a short-utterance latency claim.

## Reproduction

The harness source is `Tools/DictationFeasibility/Sources/DictationLatencyProbe/main.swift`. The app and worker packages were unchanged. Its `--vad <model-directory> <clips…>` mode runs offline. The model was intentionally left out of the repo; the only repo additions are the throwaway source and this report.
