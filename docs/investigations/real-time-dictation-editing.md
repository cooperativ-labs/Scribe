# Real-time dictation with simultaneous keyboard editing

Investigation for coo:1073.5mjw (2026-09-26). No implementation was made.

## Conclusion

Scribe's macOS stack can support visible live dictation. It cannot get good
word-by-word results merely by changing the existing `dictate` call: that call
accepts a completed WAV and returns one final transcript. The currently
installed Parakeet TDT v3 model is offline; FluidAudio's `streamingEnabled`
setting for it means chunked processing of longer recordings, not a true
low-latency incremental decoder. FluidAudio 0.17.4 provides separate streaming
engines with partial-result callbacks, but they require separately installed,
validated model assets. The Parakeet EOU 120M option is English only. Preserve
the current Parakeet v3 path for final quality and multilingual dictation.

The harder part is letting a person edit the same text while recognition is
still revising it. Scribe can own that interaction reliably in a native
editable compose window. Updating text live in *arbitrary other apps* while
the person edits there is substantially harder: Accessibility support differs
by app, paste has no stable range identity, and later ASR revisions could
overwrite or duplicate text the person typed. This distinction should drive
the product decision before implementation.

## Existing path

| Component | Current behavior | Consequence |
| --- | --- | --- |
| `DictationAudioCapture` | `AVAudioEngine` tap converts to 16 kHz mono and keeps a bounded in-memory ring; `finish()` returns all samples. | Capture can expose incremental frames, but needs a bounded, nonblocking consumer instead of repeated full-ring snapshots. |
| `DictationCoordinator` | On listening end it writes a temporary WAV, calls the engine, then inserts once. State exposes sound level, not text. | Add a live session and separate provisional/final transcript state. |
| `DictationEngine` / `WorkerDictationSession` | Keeps Parakeet v3 resident, but worker protocol has only `warm`, `dictate`, `unload` in dictation mode. | Add start/audio/partial/finish/cancel semantics and worker-to-host events; retain current final call as a fallback. |
| `DictationIndicatorView` | Non-key floating capsule shows mic level/status. | Suitable for a read-only preview; it cannot itself accept keyboard editing. |
| `DictationTextInserter` | AX selected-text set with verification, then paste fallback. Inserts at the currently focused field. | Good for final insertion, but neither path tracks a dictation-owned range through concurrent user edits. |

Source: the corresponding files under `Modules/Dictation`,
`Scribe/UI/Sources/ScribeUI`, and
`Workers/TranscriptionWorker/Sources/TranscriptionWorkerSupport`.

## Feasible interaction designs

1. **Live preview, final insert.** Show provisional text in a larger
   non-activating panel, then keep today's final insertion on stop. This is the
   smallest and safest change, but it does **not** let the person edit the
   dictated words with the keyboard during capture.
2. **Scribe-owned compose window.** Start dictation into an editable text
   view. Keep recognized speech as a replaceable provisional tail and commit
   stable phrases as ordinary text. User edits take precedence: freeze any
   phrase they touch, restrict ASR revisions to the untouched tail, preserve
   selection and undo, and never replace the entire editor value after each
   partial. On stop, optionally run v3 over the captured audio and apply a
   correction only to untouched spans. Copy or insert the finished text into
   the original target. This meets the simultaneous-editing requirement
   reliably, with one extra Scribe window/final transfer step.
3. **Direct live insertion into other apps.** Commit stable phrases once,
   never send provisional revisions to the target, and track the focused
   element, selection and inserted range. If the target changes or range
   tracking cannot be verified, stop automatic insertion and keep subsequent
   speech in a Scribe preview for explicit insertion. This can work in tested
   native fields, but cannot promise seamless editing in every browser,
   Electron app, or rich-text editor. Frequent AX calls/pastes also need
   latency and clipboard behavior tests.

Recommendation: build design 2 for full simultaneous editing. Design 1 can
be an earlier milestone. Offer design 3 only as a guarded, app-tested mode;
do not silently replace a third-party field's full value.

## Recognition options

- **Parakeet EOU 120M via FluidAudio 0.17.4:** genuine streaming partial
  callbacks with 160/320/1280 ms model variants. The 320 ms variant is a
  reasonable first experiment. It is English only, needs a new offline model
  manifest/download/install path, and may add resident memory alongside v3.
  Treat EOU text as provisional and v3 text as final. The chunk interval is
  not a measured end-to-end UI latency.
- **Repeated v3 windows:** re-transcribe accumulating audio or speech turns
  through the current worker. It reuses installed assets and languages, but
  the signed-process investigation found empty output for a real three-second
  clip until it was padded to six seconds. Window overlap and changing
  hypotheses make word-by-word output and edit reconciliation unreliable.
  Useful as a low-cost prototype, not the promised final experience.
- **Apple `DictationTranscriber`:** progressive presets and volatile results
  provide an OS-managed live path on supported macOS versions. Scribe targets
  macOS 15, and this would add a second authorization/model behavior with
  different accuracy and vocabulary. It is an optional fallback experiment,
  not reuse of the current ASR stack.

FluidAudio's pinned source defines `StreamingAsrManager`,
`StreamingEouAsrManager`, and `StreamingModelVariant` in
`Workers/TranscriptionWorker/.build/checkouts/FluidAudio/Sources/FluidAudio/ASR/Parakeet/Streaming/`.
Upstream references:
[FluidAudio streaming API](https://github.com/FluidInference/FluidAudio/blob/v0.17.4/Sources/FluidAudio/ASR/Parakeet/Streaming/StreamingAsrManager.swift),
[FluidAudio model overview](https://github.com/FluidInference/FluidAudio),
[Apple volatile results](https://developer.apple.com/documentation/speech/dictationtranscriber/reportingoption/volatileresults).

## Scope estimate and validation

Engineering estimates, not measured implementation time:

| Scope | Estimate | Main work |
| --- | --- | --- |
| Live preview only | 3–6 engineer days | Stream audio/partials across the worker protocol, install/validate model, expand indicator, handle cancel/recovery. |
| Editable Scribe compose window | Additional 5–10 engineer days | Text ownership, provisional tail, selection/undo behavior, final-v3 reconciliation, transfer to target. |
| Broad direct live insertion | Additional 2–4+ weeks | Per-app AX behavior, range/change tracking, fallback UX, race testing; coverage remains app-dependent. |

Before promising latency or quality, run a signed-app spike with real microphone
speech (short English utterances, pauses, corrections, long toggle sessions)
and measure time from spoken word to visible text, memory with both models
resident, English accuracy vs final v3, worker crash/restart, and keyboard
edits during ASR revisions. Test target insertion in TextEdit, browsers,
Electron, and rich-text editors, including focus changes, selections,
secure fields, and active meeting recording. Set acceptance thresholds from
those measurements rather than model chunk size alone.
