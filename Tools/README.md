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

Reports in `docs/feasibility` retain historical observations. Commands naming
retired tools describe those original runs and are no longer current commands.
Recorded fixtures remain under `Tests/Fixtures/real`.

The shared simulated recorder and ready-to-record fixture live in
`Scribe/Platform/Tests/Support`, exposed as `PlatformTestSupport` only to test
targets. Production targets depend on `Platform`.
