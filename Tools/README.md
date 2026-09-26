# Development tools

These tools exercise current product code or maintain reproducible quality gates:

| Tool | Purpose |
| --- | --- |
| `CaptureIntegration` | Signed, real-device capture and recording-to-transcription handoff checks |
| `CaptureCoexistence` | Capture priority under transcription load and publication handoff tests |
| `TimelineHarness` | Production timeline reconstruction and mixdown fixture gates |
| `AudioMetrics` | Quantitative scoring of generated and recorded audio fixtures |
| `DiarizationAnalysis` | Saved-artifact replay, transcription benchmarks, and controlled quality comparisons |
| `ScribeProcess` | Standalone production audio processing |
| `ScribeVocabulary` | Shared vocabulary command line |

The worker's ASR, diarization, and short-turn benchmark executables remain inputs
to the quality tools. Speaker enrollment calibration remains available for
evaluating matcher thresholds against new recordings. These are development
executables; the app packages only `TranscriptionWorker`.

Completed feasibility probes were retired in coo:1071:

| Removed tool | Current coverage / replacement |
| --- | --- |
| `CaptureHarness` | `Scribe/Capture` and `Scribe/Processing` regression tests, plus `CaptureIntegration` for live capture |
| `AECHarness` | `Scribe/Processing` echo-cancellation tests and `TimelineHarness` mixdown gates |
| `DictationFeasibility` | `Modules/Dictation` and worker dictation tests; permission handling in `Scribe/Platform` |
| `DictationIndicatorHarness` | Production `DictationIndicatorView`; historical screenshots remain in `docs/feasibility/dictation-indicator` |
| `Native/FLACBridge`'s `FLACProbe` | FLAC encoder round-trip tests across sample rates, channel counts, and bit depths |

Reports in `docs/feasibility` retain historical observations. Commands naming
retired tools describe those original runs and are no longer current commands.
Recorded fixtures remain under `Tests/Fixtures/real`.

The shared simulated recorder and ready-to-record fixture live in
`Scribe/Platform/Tests/Support`, exposed as `PlatformTestSupport` only to test
targets. Production targets depend on `Platform`.
