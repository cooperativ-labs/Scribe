# capture-coexistence

The capture-coexistence gate for
[TRANSCRIPTION_IMPLEMENTATION_PLAN.md](../../TRANSCRIPTION_IMPLEMENTATION_PLAN.md)
section 11: *no additional capture gaps in a controlled two-hour recording test
with queued transcription; enforce recording priority if resource contention
appears.*

It drives the shipping objects, not copies of them:

- `SessionStore` archives real CAF segments through the real timeline journal.
- `ProcessingQueue` is the real `ProcessingScheduler`.
- `TranscriptionCoordinator` asks that scheduler for permission exactly as
  `TranscriptionHostService` does in the app, and its host stages —
  `TranscriptAssemblyStageRunner` — produce real canonical transcripts.

Two things are stood in for, both deliberately:

- **`SCStream`.** A bare Mach-O executable cannot be granted Screen & System
  Audio Recording by any route
  ([capture-permissions.md](../../docs/feasibility/capture-permissions.md)), so
  buffers are synthesized at exactly the rate and in exactly the layouts
  ScreenCaptureKit was measured to deliver
  ([capture-timing.md](../../docs/feasibility/capture-timing.md)): 960 frames of
  48 kHz stereo system audio and 512 frames of 48 kHz mono microphone. The
  writer side is the recorder's own: a sample handler that only bounds and
  enqueues, and a separate serial writer queue that drains into the store.
- **The Core ML stages.** They are replaced by a CPU and memory load whose size
  the run prints, so the gate can run on a machine with no models installed and
  so the load is a stated number rather than something that varies with whatever
  recording the helper was given.

## What a gap means here

Exactly what it means in `CaptureService`: a buffer the bounded 4 MB queue
refused because the writer had fallen behind. A late-but-accepted buffer costs
no audio, so producer lateness is reported separately and does not fail a run.

## Running it

```sh
swift build -c release --package-path Tools/CaptureCoexistence
BIN=Tools/CaptureCoexistence/.build/release/capture-coexistence

# The release gate.
"$BIN" run --seconds 7200 --jobs 4 \
    --load-seconds 20 --load-threads 16 --load-memory-mb 2048 \
    --output /tmp/coexistence --report /tmp/coexistence.json
```

One continuous recording, split at the midpoint. Nothing is queued during the
first half; the transcription jobs are queued during the second. Comparing the
halves of a single recording controls for whatever else the machine was doing
far better than two separate runs would. A job is also started *before* the
recording, so the run covers suspension of work already in flight as well as
deferral of work offered during capture.

The gate passes when:

- the recording lost no buffers at all,
- the second half lost no more than the first,
- no transcription stage started while the recording was running,
- and every queued job completed once the recording stopped.

## The control run

```sh
"$BIN" run --seconds 120 --jobs 2 \
    --load-seconds 20 --load-threads 16 --load-memory-mb 2048 --ignore-scheduler
```

`--ignore-scheduler` builds the coordinator with no scheduler, so transcription
runs during capture. It exists because a gate that passes either way measures
nothing. On an 8-core, 32 GB Apple Silicon machine that control lost 9,151
buffers with the queue pinned at its bound, while the same load with the
scheduler enforced lost none.

## The fast tests around it

`Modules/Transcription/Tests/TranscriptionTests/CaptureCoexistenceContractTests.swift`
pins the contract itself — deferral, suspension at the next persisted stage
boundary, and resumption — in milliseconds rather than hours, so a regression is
caught long before this gate is run.

`Tests/CaptureCoexistenceCoreTests/PublicationHandoffTests.swift` lives here
because this package is the one place that links the recorder and the
transcription module together. It drives the other milestone 5 exit criterion —
a published recording transcribing automatically — through the real
`FinalRecordingHandoff`, the real `TranscriptionRequestOutbox`, and the real
coordinator, and out to TXT, JSON, and SRT.
