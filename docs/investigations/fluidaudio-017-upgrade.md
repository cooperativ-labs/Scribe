# FluidAudio 0.17 upgrade recommendation — coo:1069

Investigated 2026-09-25. This is a dependency assessment; no worker pin or
production behavior changed.

## Recommendation

Evaluate an **exact pin to v0.17.2** in an isolated worker build, then promote it
only if the ASR, VBx, dictation, and offline packaging checks below pass. Keep
the current VBx diarizer during this dependency upgrade. Treat Nemotron 3 as a
separate benchmark and product decision. Do not pin v0.17.0 or v0.17.1: their
Nemotron 3 output backing can crash on relevant Apple hardware. v0.17.2 contains
the fix, with no public API change for that patch.

The upgrade is worth testing now: v0.15.8 includes several long-form and
streaming ASR seam fixes that may improve Scribe's transcript boundaries, and
v0.17.2 removes the previously identified Nemotron 3 runtime blocker. Neither
release note establishes that Scribe's word timings, diarization quality, or
dictation latency remain acceptable. An unconditional production bump is not
justified by the available evidence.

## Scribe compatibility surface

| Surface | Current dependency | Upgrade concern |
|---|---|---|
| Offline ASR | `ParakeetAdapter` uses `AsrManager.transcribe(URL, decoderState:)` and serializes source-relative `ASRResult.tokenTimings`. | v0.15.8 changes streaming seam decisions, final-window alignment, blank-window recovery, and punctuation token lookup. Recheck token identity, order, start/end times, pauses, English/German text, and chunk boundaries. |
| Diarization | `OfflineDiarizationAdapter` uses `OfflineDiarizerManager`, exact/max speaker controls, overlap, `speakerDatabase`, and per-chunk embeddings. | Keep the VBx model and config fixed; remeasure WDER, speaker count, overlap, and exported vector compatibility before reusing voiceprints or calibration thresholds. |
| Offline models | `OfflineModelLoader` constructs `AsrModels` and `OfflineDiarizerModels` from staged local files. | Compile against the new API, then verify a clean packaged worker runs with networking blocked and never enters a download fallback. Upstream's immutable diarization artifact pin concerns its download path; Scribe's staged assets already have their own manifest. |
| Dictation | The in-progress dictation session uses `AsrManager` on short buffers and explicitly loaded Silero VAD. | Check short speech, silence, language selection, repeated warm/dictate/unload, token times, and latency on the signed app. |
| Provenance and packaging | Worker and dictation probe SwiftPM pins, resolved revisions, runtime version/revision fields, and notices describe v0.15.7. | Update them together after validation. An isolated build must confirm the actual linked revision; `Package.resolved` alone does not prove it. |

Current exact pin: `Workers/TranscriptionWorker/Package.swift` and
`Tools/DictationFeasibility/Package.swift` use v0.15.7, revision
`41540ea237350afe5117a082b5c28eda642d0612`; the Xcode and SwiftPM
resolution files agree. The worker package is deliberately exact because token
timing and diarization are part of its protocol contract. The dictation source
is currently concurrent work in the shared checkout, so it should be included
in the eventual integration review without changing it for this assessment.

## Release evidence and constraints

- [v0.15.8 release](https://github.com/FluidInference/FluidAudio/releases/tag/v0.15.8): fixes streaming seam reconciliation by word text, re-decodes windows with fresh state and final-window alignment, adds blank-window recovery, resolves punctuation IDs from the loaded vocabulary, and pins diarization downloads to an immutable revision.
- [v0.16.1 release](https://github.com/FluidInference/FluidAudio/releases/tag/v0.16.1): fixes Mac Catalyst slices in the text-processing framework; the notes describe no API change. Scribe targets macOS, but this still merits a packaging/link check.
- [v0.17.0 release](https://github.com/FluidInference/FluidAudio/releases/tag/v0.17.0): adds Nemotron 3 diarization and an ASR array-copy performance change. Neither requires switching Scribe's VBx adapter.
- [v0.17.1 release](https://github.com/FluidInference/FluidAudio/releases/tag/v0.17.1): CocoaPods metadata correction only; SwiftPM users were unaffected.
- [v0.17.2 release](https://github.com/FluidInference/FluidAudio/releases/tag/v0.17.2): fixes Nemotron 3 output backing rejection seen on M5/macOS 27 and M3 Max. M3 ANE compilation remains an upstream issue; Core ML falls back. This is relevant only if Scribe later adopts Nemotron 3.
- [coo:1049 investigation](diarization-1049-nemotron3.md): Nemotron 3 has an eight-speaker ceiling, no speaker embeddings, and no exact-speaker-count control. Scribe's CAB fixture has nine named speakers. The new runtime fix does not remove these product constraints.

## Promotion checks

1. Build the worker and the dictation probe from v0.17.2 in scratch output,
   compile worker tests, and record the resolved full commit hash and binary
   hash. Make necessary API adjustments without changing model assets.
2. Run the existing timing and transcript fixtures plus real short and long
   English/German recordings. Compare tokens and words at chunk seams,
   punctuation, silence, final windows, empty/blank decodes, and processing
   time against v0.15.7. Inspect any changed output rather than accepting a
   successful compile as proof of equivalence.
3. Run VBx on the frozen CAB fixture using the same prepared audio and score it
   against the [v0.15.7 baseline](../../benchmark-files/README.md): canonical
   WDER 4.685%, effective WDER 1.888%, 19,488 scored words, and 65.8 seconds
   diarization time for 7,021 seconds of audio. Check speaker count, overlaps,
   and a cross-version embedding comparison before carrying forward saved
   voiceprints or enrollment thresholds.
4. Exercise dictation in the signed app with silence, short speech, repeated
   requests, and both supported language modes. Confirm bundled VAD loading,
   latency, and token times. Run the packaged worker with networking blocked.
5. Only after those checks, update both exact pins and resolution files, runtime
   provenance, and versioned notices/docs in one change. Leave Nemotron 3 behind
   its own benchmark decision.

No v0.17.2 compile or audio benchmark was performed for this assessment. The
local SwiftPM checkout is v0.15.7, and direct GitHub Git access from this
session returned HTTP 403. Release claims above are from tagged upstream notes;
performance and compatibility claims about Scribe remain unverified until the
promotion checks run.
