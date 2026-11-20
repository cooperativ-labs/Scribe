# Application video capture: what it would take

Status: evaluation only, nothing implemented. Question (coo:1319): what functionality
must Scribe add to capture the meeting application's video alongside its audio, and
what steps does that add to the processing pipeline?

## Where we start

- `Scribe/Capture/Sources/Capture/CaptureService.swift` already runs one `SCStream`
  filtered to the meeting app (`SCContentFilter(display:including:)`), with `.audio`
  and `.microphone` outputs. A `.screen` output exists only as an opt-in discard
  path (`registersMinimalScreenOutput`), configured at 2×2 px, 1 fps; frames are
  counted (`discardedScreenFrames`) and dropped.
- Screen Recording permission (TCC) is already required and handled
  (`screenRecordingPermissionDenied`), so video adds **no new permission prompt**.
- Audio is archived as CAF segments per track (`RecorderTrackKind`: `system`,
  `microphone`, `final`) with a `CaptureJournal` of runs/gaps/format changes, then
  `TimelineBuilder` → `MixdownService` (AEC + mix → `final.m4a`) →
  `FinalRecordingHandoff` → transcription worker → transcript/exports.

So the capture plumbing is ~70% there; the work is in encoding, storage, timing,
and the downstream stages.

## Capture functionality to add

1. **Real `.screen` output.** Replace the 2×2 configuration with a video profile:
   e.g. 1280×720 (or window's native size, capped), 2–5 fps default for meetings
   (slides/screen-share), optional 15–30 fps. `showsCursor` configurable,
   `pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` to feed the
   encoder without conversion, and a deeper `queueDepth` (5–8).
2. **Capture target choice.** Today's filter is *display ∩ app windows*. Video needs a
   decision: whole app (all windows on one display; current filter), a single window
   (`SCContentFilter(desktopIndependentWindow:)`, survives moves between displays),
   or the full display. Needs a window picker / `SCContentSharingPicker`, and
   handling of the meeting window moving displays, minimising, or closing
   (stream reconfigure via `updateContentFilter`, journal the change).
3. **Frame status handling.** Inspect `SCStreamFrameInfo.status`: keep `.complete`,
   treat `.idle` as "repeat previous frame" (no write), journal `.blank`/`.suspended`
   as video gaps. Idle frames are the common case for static slides and make low
   fps nearly free.
4. **Hardware encoding writer.** A `VideoSegmentWriter` using `AVAssetWriter`
   (HEVC or H.264 via VideoToolbox, `expectsMediaDataInRealTime = true`) writing
   fragmented MP4/MOV (`movieFragmentInterval` ~2–5 s) so a crash leaves a readable
   file — the video equivalent of the CAF segment + `recoveredActiveSegments` story.
   Rotate segments on size/format change exactly like audio. Must run on its own
   queue with its own byte budget; it must never back-pressure the audio queues
   (`BoundedBufferQueue`): on overload drop video frames, never audio.
5. **Journal + manifest.** Add `RecorderTrackKind.video` (or a separate
   `VideoTrackKind`), journal events for video segments, dropped frames, resolution
   changes, target changes; extend `RecorderSessionManifest.schema.json` (schema
   version bump) and `SessionStore` to describe video segments.
6. **Settings/UI.** Per-recording or per-app toggle "Record video", quality preset,
   capture target, recorder menu indicator, disk-usage estimate and retention
   policy. Meeting detection can stay audio-driven.
7. **Resource guards.** Free-disk check before/during recording (video is 100–600 MB/h
   at meeting settings vs ~30 MB/h for audio), energy/thermal backoff (drop fps),
   and pause support (`setPaused` already drops buffers; extend to video).

## Target use case: meeting + shared screen (demos)

The primary use case is team meetings where the user sometimes demos software:
record the meeting app *and* whatever screen the user is sharing. That changes the
design in these ways:

- **Two video sources, two streams.** A *meeting* stream filtered to the meeting
  app's main window (`desktopIndependentWindow`, captures it even when covered by
  the demo, not when minimised) and a *share* stream on the shared display or
  window. Separate `SCStream`s let each have its own fps/resolution and keep a
  stall in one from affecting the other or the audio stream.
- **Knowing what is shared.** Scribe cannot read which window/display Zoom, Meet or
  Teams is sharing. Options, simplest first: (a) record the display the user works
  on (covers any window they share, also shows anything else on it); (b) a "Start
  demo" action in the recorder menu that opens `SCContentSharingPicker` so the user
  picks the same window they share; (c) heuristics (meeting app's share toolbar /
  red border windows appearing) to auto-start/stop the share stream. Recommend (b)
  with (a) as the default if no pick is made, and (c) later.
- **Share periods, not the whole meeting.** The share stream runs only while
  sharing (start/stop journaled as share segments), saving disk and avoiding
  recording private screens outside the demo.
- **Demo-grade quality for the share stream.** UI demos need legible text and
  motion: native resolution capped at 1080p/1440p, 15–30 fps, cursor shown. The
  meeting stream can stay at 720p / 5–10 fps. Rough budget: share 0.5–1.5 GB/h
  while active, meeting 150–300 MB/h.
- **Self-view caveat.** While sharing, meeting apps often shrink to a floating
  thumbnail strip; the meeting stream then shows that small view. Acceptable, and
  the composite below favours the share anyway.

**Meeting and demo as tabs in one browser window.** ScreenCaptureKit captures
windows, not tabs, and a browser window only renders its active tab. Capturing that
window gives one stream showing whichever tab is in front: the meeting while you
talk, the demo while you share (a "what I saw" recording). The meeting video is not
recorded during the demo, but its audio still is, because the system audio comes
from the browser, not the tab. That audio includes any sound from the demo tab.
Two streams make sense only if the meeting runs in its own window. Options:
- Default: one window stream; detect the tab switch from frame content or the share
  toolbar, and cut chapters there.
- Pop the meeting out to its own window (Meet/Teams/Zoom web support
  picture-in-picture or a pop-out); Scribe then sees two windows of the same app and
  records two streams.
- Later, a Chrome extension using `chrome.tabCapture` could record the meeting tab
  while it is in the background. That is a separate component with its own permission
  and timing problems, and is not worth it for v1.

Pipeline consequences: align both video tracks to the audio clock; output either
one MP4 with two video tracks (lossless, few players switch tracks) or a rendered
**composite** — share full-frame with the meeting as picture-in-picture during
share periods, meeting full-frame otherwise. The composite needs a real re-encode
(`AVMutableVideoComposition`), so run it as a background job after transcription.
Keyframe/OCR extraction should focus on the share stream (demo screens, URLs,
error messages), and transcript chapters can be cut at share start/stop.

## Processing pipeline steps to add

Current: segments → `TimelineBuilder` → `MixdownService` (`final.m4a`) → handoff →
transcription → transcript/exports → cleanup.

New steps:

1. **Video timeline alignment** (alongside `TimelineBuilder`). Map video PTS onto the
   same session clock as audio (all `SCStream` outputs share the host clock, so this
   is mostly offset + gap bookkeeping from the journal). Produce an edit list of
   video segments with gaps filled by held/black frames.
2. **Mux** (after `MixdownService`). Combine video segments with `final.m4a` into
   `final.mp4` via `AVMutableComposition` + `AVAssetExportSession` passthrough (no
   re-encode when segments share format). Audio stays authoritative; the transcript
   pipeline continues to consume `final.m4a` unchanged, so video failure must never
   block transcription — it is a separate, optional stage with its own state in
   `ProcessingState`.
3. **Keyframe / slide extraction** (optional, high value). Sample frames, detect scene
   changes (perceptual hash / frame diff, cheap because content is mostly static),
   and save thumbnails with timestamps. Enables a visual timeline in
   `TranscriptWindow` and "slide at 12:34" references.
4. **On-screen text (OCR)** (optional). Run Vision `VNRecognizeTextRequest` on the
   extracted keyframes only; attach text to the canonical transcript as timed
   "screen" annotations. Useful context for Assist summaries and for names on
   participant tiles to feed speaker labelling (`Speakers` module).
5. **Exports / handoff.** Extend `CanonicalTranscript`/`ExportJSON` with keyframe and
   OCR annotations; SRT already exists and can pair with `final.mp4`. Decide whether
   the Knowledgebase exporter / MCP plugin exposes video (currently "No audio is
   exposed" — likely keep video local, expose only keyframes/OCR text).
6. **Cleanup & retention.** `RecorderSessionCleanup` must remove video segments once
   `final.mp4` is verified (checksum in manifest, like `FinalRecordingHandoff` does for
   audio); add a retention policy (e.g. drop video after N days, keep transcript).

## Risks and open questions

- **Disk and CPU**: HEVC hardware encode at 720p/5 fps is a few % CPU; the bigger
  cost is storage. Default to low fps + idle-frame skipping.
- **Privacy/consent**: recording others' video has stronger consent implications
  than audio; needs a visible indicator and probably an explicit per-meeting opt-in.
- **Stream coupling**: adding a real `.screen` output to the same `SCStream` puts
  audio at risk if the video path stalls. Mitigation: separate queues/budgets as
  above, or run video on a second `SCStream` with the same filter (cleaner
  isolation; validate with `Tools/CaptureCoexistence` first).
- **Window churn**: meeting apps open/close windows (screen-share, pop-out); the
  app-level filter handles this better than a single-window filter.

## Suggested sequencing

1. Spike in `Tools/CaptureIntegration`: real `.screen` output → fragmented MP4,
   measure CPU, disk/h and audio drift with video on (one vs two streams).
2. Capture: writer, journal/manifest schema, setting toggle.
3. Pipeline: alignment + mux to `final.mp4` as an independent optional stage.
4. Keyframes + OCR annotations into the transcript and exports.
