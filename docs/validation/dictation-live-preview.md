# Optional Live Preview

Implemented for coo:1073.wb1j.

Enable **Settings → Dictation → Indicator → Live Preview**. The preference is
persisted and defaults to off, including for existing installations. Changes
apply to the next dictation session. When indicator position is Off, an enabled
preview appears at the bottom of the screen.

The non-activating panel shows a read-only draft of recent speech. It does not
accept keyboard edits or insert partial text into another app. Stopping runs
the existing full-recording transcription and insertion path. Cancel, secure
input, and capture recovery failure discard the preview.

## Implementation choice

This first version reuses the installed multilingual offline Parakeet model.
Every two seconds after the preceding inference completes, it transcribes at
most the most recent 15 seconds. No requests overlap, and no audio backlog is
queued. This is periodic preview, not word-by-word streaming. Longer speech
rolls out of the preview; the full capture remains available for final output.
The existing worker pads short speech after VAD acceptance.

Reusing the model avoids another model download and an English-only streaming
path. Tradeoffs are additional inference cost, revisable/cut-off words near
window boundaries, and variable latency. A running preview request drains
before final inference can start. Preview errors disable preview for that
session, but final transcription still runs. Temporary preview WAVs are removed
when each request finishes or fails. Session and cancellation checks suppress
late draft results.

## Automated validation

- Dictation package: 21 tests passed, including bounded ring snapshots across
  wraparound, preservation of final audio, concurrent requests, cancellation,
  and worker reuse.
- Settings: 9 tests passed, including default-off and persistence in both
  directions.
- ScribeUI package: 77 tests passed.
- Full Debug app build with the Scribe Xcode scheme passed.
- `git diff --check` passed.

## Interactive checks

Live microphone latency, recognition quality, and visual placement have not
been measured in this session. For signed-app QA: test hold and toggle modes,
long speech and silence, Escape during inference, rapid restart, preview failure,
secure entry, display edges, and position Off. Confirm the panel never takes
keyboard focus and final insertion occurs once with the complete transcript.
