# AEC harness

`aec-harness` is the small offline feasibility tool for the pinned WebRTC AEC3 bridge. It accepts a system-playback reference and a microphone recording, processes both in a fixed 48 kHz / 480-frame streaming schedule, and writes a cleaned microphone WAV plus block-level JSON metrics.

Build the native dependency once from the repository root, then run the fixture that is already checked in:

```sh
Scripts/build-native-dependencies.sh webrtc-apm
swift run --package-path Tools/AECHarness aec-harness \
  --reference Tests/Fixtures/Generated/far-end-only/playback.wav \
  --microphone Tests/Fixtures/Generated/far-end-only/microphone.wav \
  --delay-samples 1440 \
  --output /tmp/aec-cleaned.wav \
  --report /tmp/aec-metrics.json
```

Inputs must already be on their reconstructed 48 kHz timeline. The reference can be mono or stereo; mono is duplicated for the bridge's stereo render configuration. The initial bridge configuration deliberately accepts only mono microphone input, since that is the configuration under test. A future timeline/reformatting stage owns resampling and multichannel capture policy.

`--delay-samples` is an acoustic render-to-capture delay from that timeline, never a measurement around a `processCaptureBlock` call. When it is omitted, the harness takes a bounded one-second calibration pass and uses normalized cross-correlation only if both tracks are active, the correlation is strong, and the winning lag has a clear margin over other lags. Silence, weakly correlated local speech, and ambiguous periodic playback are rejected. An uncertain estimate deliberately produces a marked pass-through (`uncertain-delay-bypass`) rather than guessing a zero-delay AEC configuration.

WebRTC's pinned API takes milliseconds, so the report records both the supplied or estimated sample delay and the one-time nearest-millisecond conversion (including its quantization error). While processing, a fresh confident estimate is sampled each second; a change of at least one 10 ms block resets AEC3, updates the stream delay, and records a reconvergence event. Use repeatable `--discontinuity-samples N` flags for reconstructed-timeline gaps, device changes, or route changes from capture metadata: every declared position resets AEC3 before that block and starts a new convergence interval. The harness sends `render,capture` for every 10 ms block; alternative orderings are rejected because AEC3 must analyze render before processing the corresponding capture block.

The harness never stores whole WAVs or the report's blocks in memory. WAV reading, output writing, and report writing are all streaming; its report records the bounded `maximumWorkingAudioSamples` figure. `blocks[].erleDb` is the direct per-block input/output energy reduction. It is intentionally calculated by the harness instead of treating AEC3's windowed/aggregated ERLE statistic as the fixture measurement; the latter remains available at `blocks[].aec3.reportedERLEDb`.
