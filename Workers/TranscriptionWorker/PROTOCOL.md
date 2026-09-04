# Transcription worker protocol (v1)

`TranscriptionWorker` reads and writes UTF-8 JSON objects on standard input and
standard output. One object occupies one newline-delimited record. Diagnostic
text is written only to standard error. The protocol version is an integer in
every envelope; v1 only accepts `version: 1`.

```json
{
  "version": 1,
  "kind": "request",
  "requestID": "a-host-generated-id",
  "payload": { "operation": "handshake" }
}
```

Each record is capped at 1,048,576 bytes. `kind` is one of `request`,
`progress`, `stage_result`, `error`, or `cancel`. Responses retain the request
identifier. Invalid JSON, an unsupported version, and oversize records produce
a structured `error` response with `code: "protocol_error"`.

## Operations

`handshake` returns a `stage_result` containing protocol and worker versions,
the pinned FluidAudio version, and explicit `networking: "disabled"`,
`runtimeDownloads: false`, and `telemetry: false` declarations. It performs no
model loading and is safe to use as a launch check on a machine without models.

`validate_assets` reads the local manifest and model root supplied at worker
launch. It returns `stage_result` / `asset_validation` only when every required
local path and checksum is present. Otherwise it returns the structured
`model_setup_incomplete` error whose `details.failures` values name the asset,
path, and reason. It never attempts a model download.

`run` executes one offline job. Its payload requires absolute local
`sourcePath` and `runDirectory` values; it may include a positive integer
`knownSpeakerCount`. The worker creates the supplied run directory when needed,
then runs these sequential stages:

1. `prepare` writes `prepared.wav` (16 kHz mono) and `prepare.json`.
2. `transcribe` writes `transcript.json`.
3. `diarize` writes overlap-preserving intervals to `diarization.json`.
4. `embed` writes compatible speaker vectors to `embeddings.json`.

Every completed stage emits a `progress` envelope when it starts and a
`stage_result` with the relative result file name and SHA-256 when its JSON
checkpoint is atomically committed. ASR and diarization model managers are
scoped to their respective stages, so their heavy model sets do not coexist.
The final `stage_result` names `complete`; all large data stays on disk.

`cancel` is acknowledged by the concurrent input reader immediately. The job
observes it at the next stage boundary, returns structured `code: "cancelled"`
with the completed stage name and `checkpointsPreserved: true`, and leaves all
earlier stage files intact. An unexpected process termination follows the same
checkpoint rule: a stage only replaces its result after successful completion,
so a later crash never corrupts an earlier output.

## Paths and large data

Paths are JSON string values (`--manifest` and `--models-directory` at process
launch; later job requests use `sourcePath` and `runDirectory` values). The
host must launch the worker directly with an argument vector, not interpolate
these values into a shell command. The worker does not execute a shell.

Large transcripts, token arrays, diarization intervals, and embeddings are
written into the host-supplied `runDirectory`. A `stage_result` carries the
relative result file name and a checksum instead of returning the data inline.
This keeps both directions inside the record limit and leaves completed stage
files intact for cancellation/crash recovery.

## Integration test

`swift test` drives the compiled worker binary through stdin/stdout with
`SCRIBE_TRANSCRIPTION_WORKER_TEST_MODE=1`, which is a test-only guarded
deterministic pipeline. It verifies all four stage files on a short fixture, a
boundary cancellation that preserves the prepare checkpoint, and an abrupt
failure during the following transcription stage that preserves that same
checkpoint. The production `run` path has no test mode and never enables
downloads, networking, or telemetry.

## Offline launch check

```sh
cd Workers/TranscriptionWorker
swift build
printf '%s\n' '{"version":1,"kind":"request","requestID":"handshake-1","payload":{"operation":"handshake"}}' \
  | .build/debug/TranscriptionWorker
```

No network permission is needed for this command after package resolution. To
check a staged installation, add `--models-directory /absolute/local/models`
and send `validate_assets`. Use `Scripts/package-transcription-models.sh` only
during development/release preparation to stage the pinned model snapshots.
