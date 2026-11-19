# Transcription

Transcript import, canonical transcript model, export, and the review UI
(`Sources/Transcription/UI`).

## Paste a transcript

In the Transcripts window, choose **+ → Paste Transcript…**, enter a title,
select **Fireflies** in the import format menu, and paste turns such as
`Mary Laut (01:35): Waiting.`. Timestamps may use `MM:SS` or `HH:MM:SS`;
wrapped text stays with its speaker. Invalid or decreasing timestamps are
reported before anything is saved.

Import adds a completed transcript to the durable library and selects it.
It supports the usual editing, TXT, Scribe JSON, Knowledgebase JSON, SRT, and
**Send to Agent** actions. Speaker labels come from the pasted headers; Scribe
does not infer identities from the spoken text. No audio or word timings are
imported. Turn end times use the next turn start (at least one millisecond),
and the last turn is assigned one second. The transcript retains a warning
that end times and duration are estimated. The original paste is kept beside
the saved run as `imported-fireflies.txt`.

## Meeting drafts

Every recording made in Scribe has a `MeetingDraft` (`Sources/Transcription/Drafts`),
opened once per recorder session ID when capture is active and stored by
`MeetingDraftStore` as `~/Library/Application Support/Scribe/drafts/<draftID>.json`
(owner-only, atomic, written ~500 ms after the last change and at stop,
handoff and termination). Identities:

- The recorder's handoff request ID is `TranscriptionRequest.recorderRequestID(forSession:)`,
  a version-5 UUID of the session ID. `TranscriptionCoordinator.enqueue` returns the
  persisted job for a request ID it has seen instead of allocating another run.
- `TranscriptionRequest.draftID` (optional; absent in older outbox and job files)
  is copied into the job record, and reprocess/retranscribe keep it, so a run can
  always be traced back to its draft. The source checksum is never the binding.
- `TranscriptReviewFile.id` is the row key: the draft ID for recordings made in
  Scribe, the run ID otherwise. Run operations use `TranscriptReviewFile.runID`.

`MeetingDraftReconciler` joins session manifests, outbox requests, job records
and drafts and is run at launch and after every capture, processing and job
change; `MeetingDraftLifecycle` applies its actions and mirrors the store for
review. `MeetingDraftReviewMerger` builds the sidebar rows.

### Meeting notes

- `MeetingNotesText` holds the paragraph grouping and stamping rules (first
  character stamps, join keeps the earlier stamp, split keeps it on both halves,
  a paste is one moment), independent of AppKit. `MeetingNotesEditor` is the
  `NSTextView` (TextKit 1) wrapper: each note's ID and stamp ride on its text as
  an attribute, so undo/redo restores them; inserted text is stripped of that
  attribute unless the change is an undo or redo; marked (IME) text is ignored
  until committed. The stamp is read from a clock closure at the edit, never
  from a timer. The gutter is a sibling view of `NSButton`s (accessibility
  label, press action, key view loop after the text).
- The clock is `RecordingTimestamp.noteOffsetMilliseconds` (Platform): the
  Paste Timestamp figure as milliseconds, nil unless capture is running.
- Before the run is terminal, notes live in `MeetingDraft.notes`. Attachment
  (`MeetingDraftLifecycle.attach`) writes them into
  `<meeting>/meeting-notes.json` (`MeetingNotesSidecar`, schema 1, entries keyed
  by draft ID, 0600, never creating a missing meeting directory), then marks the
  draft `.attached` and empties its notes, only if the draft revision is
  unchanged. Reconciliation re-runs it for an attached draft that still holds
  notes. Afterwards edits go to the sidecar (debounced, flushed on selection
  change, editor close and termination).
- `MeetingNotesEditorPane` is the editor bound to one draft ID through the
  `TranscriptViewModel`; it is its own view so a keystroke redraws only it.
  `TranscriptViewModel.setNotes` bumps `notesRevision`, which
  `notesContent(draftID:)` reads, so every pane showing the draft reloads text
  changed elsewhere (caret kept; never while IME text is marked).
- `MeetingNotesPanelController` owns the floating notes panel
  (`MeetingNotesPanel`: titled utility `NSPanel`, `.nonactivatingPanel`,
  `.floating`, `.canJoinAllSpaces` + `.fullScreenAuxiliary`,
  `hidesOnDeactivate = false`, frame autosaved as `ScribeMeetingNotesPanel`).
  It hosts `MeetingNotesEditorPane` and the full `AgentHandoffTray` for
  `.draft(id)` on the host's review model, so the panel and the window share
  one draft session. The panel sends ⌘W and the editing commands itself,
  since the main menu is not reliably consulted while Scribe is inactive.
  `MeetingNotesPanelClosePolicy` is decision 13 as a pure function: close
  automatically only when the transcript became ready while the panel was
  open, nothing has focus (panel key, child popover, sheet or modal dialog),
  no IME text is marked, nothing is unsaved (`MeetingDraftEditing.hasUnsavedEdits`,
  flushed before the final check) and the tray state is `.manual(nil)`.
- `TranscriptStore.combineRecordings` stages both meetings' sidecars into the
  new meeting (second shifted by the join offset, `ownerDraftID` set to the
  first draft's ID) before removing the originals and refuses when either is
  unreadable; the combined job carries the owner's `draftID`.
  `MeetingDraftEditing.prepareForCombine` / `finishCombine` flush notes, refuse
  while `MeetingSend.blocksCombine`, clear the owner's handoff settings and
  delete the other draft record.

### Notes in exports and the relay

- `TranscriptExportNote` (Export) is a note as it leaves Scribe: `id`, `text`,
  `offsetMs` (recording time or nil) and `draftID`. Nothing else from the draft
  can be expressed in it, which is what keeps the prompt, MCP URL and send state
  out of every export and relay answer.
- `TranscriptExporter.export(_:as:notes:)` and the per-format entry points take
  the meeting's notes, defaulting to none. With none, every format is byte for
  byte what it was before notes (the goldens do not change). TXT appends a
  `Notes` section (`TranscriptExportNote.paragraph`, shared with
  `AgentHandoffPayload.notesBlock`); Scribe JSON appends a top-level `notes`
  array (`id`, `text`, `offset_ms`, `draft_id`) after `warnings`, outside
  `CanonicalTranscript`, whose schema allows extra top-level members, so
  `CanonicalTranscriptCodec` decodes the document to the same transcript;
  Knowledgebase writes `pipeline.extensions["ai.scribe"].notes`
  (`id`, `text`, `offset_ms`) and stays `kb.transcript-upload/1`. Knowledgebase's
  importer (`packages/web/src/features/transcripts/import.ts`) rejects unknown
  top-level and segment members but accepts any object under a namespaced
  extension and keeps `pipeline.extensions` on the imported
  `kb.meeting-transcript/1`, so no `/2` was needed. SRT ignores notes. Notes
  with no words are dropped, and note text is trimmed per line with blank lines
  removed.
- `TranscriptExportWriting.write(_:notes:…)` carries the notes to the file
  writer. `TranscriptViewModel` takes them from `MeetingDraftEditing.exportNotes`
  for the selected row (none for rows without a draft). On an unreadable sidecar
  it exports without notes and the toast says they were left out.
  `MeetingDraftLifecycle.exportNotes` returns the row's current notes,
  unsaved edits included, attributed per note to its source draft through
  `MeetingNotesSidecar.exportNotes(_:shownBy:recorderSessionID:)`, which uses
  the same entry rule as `setNotes`.
- The agent handoff's transcript file is still the Knowledgebase export without
  notes: the notes travel in the prompt (or `<operationID>.notes.txt`) under the
  sender's label, so the agent reads them once.
- `TranscriptStore.confinedCompletedRuns()` reads each meeting's
  `meeting-notes.json` under the same rules as the runs (real path inside the
  store, `O_NOFOLLOW`, regular file, size cap) and fills
  `ConfinedTranscriptRun.notes` with `MeetingNotesSidecar.exportNotes(forRunDraft:)`:
  the row of `job.draftID` when the sidecar has one, else every entry. A missing,
  unreadable, newer-schema or escaping file yields no notes and never skips the
  run. `Workers/ScribeMCP` serves these, and `Integrations/scribe/src/store.js`
  implements the same rule for the Node server; the conformance test compares
  them.

### Agent handoff

- `AgentHandoffTray` (UI) is the one handoff surface: a full tray under a
  placeholder meeting's notes and in `TranscriptAgentSheet` (notes preview plus
  tray), a compact one-line tray under a finished meeting's notes. Pills open
  popovers, not menus. Imports and pasted transcripts get the tray with no
  notes area and send immediately.
- Every call is bound to an `AgentHandoffTarget`: `.draft(id)` reads and writes
  `MeetingDraft.handoff` through `MeetingDraftEditing.handoffSettings` /
  `setHandoffSettings` (debounced like notes, excluded from row facts);
  `.transcript(rowID)` keeps in-memory settings for rows with no draft. The view
  model holds no window-wide agent, model, folder or prompt. Settings are seeded
  once per draft from `TranscriptAgentPreferences` at capture start.
- `MeetingHandoffFolder.unset` resolves to the first reachable connected folder;
  `.none` is No folder; an explicit folder that is no longer connected (or an
  agent that is not installed) is reported, never replaced. A prompt whose
  `promptOrigin` is not `.edited` follows the resolved folder's last prompt,
  else `TranscriptAgentRequest.defaultInstruction`.
- `TranscriptAgentRequest` carries `operationID` and `notes`. `AgentHandoffPayload`
  (Handoff) writes `<operationID>.kb.json` and, when the notes block exceeds
  `inlineNotesLimit`, `<operationID>.notes.txt` (0600 in a 0700 folder), composes
  the prompt (prompt, notes labelled as the sender's, transcript path,
  `untrustedTranscriptStatement`, MCP URL, report location) and the Latch
  manifest, and prunes handoff files older than `retention` (7 days).
- Preference history is written only after the dispatcher reports a created
  session. A manual send's Sent / Couldn't send state is per target and in
  memory; a queued send's lives in the draft.
- `AgentHandoffLatchIntegrationTests` starts real Latch sessions with a
  stand-in agent: `SCRIBE_LATCH_INTEGRATION=1 swift test --filter AgentHandoffLatchIntegrationTests`
  (`SCRIBE_LATCH_PATH` for another `latch`). The second test kills `latch
  create --request-id` once the session exists, re-issues it, and checks one
  session in a throwaway `LATCH_HOME`.

### Queued send

- `MeetingDraft.send: MeetingSend` is `.notQueued`, `.queued(operationID,
  queuedAt)`, `.held(operationID, reason, queuedAt)`, `.claimed(operationID,
  snapshot, claimedAt)`, `.sent(…)` or `.failed(operationID?, message,
  definite, retry)`. `MeetingDraft.stopReason` keeps how the recording ended
  after the phase moves on. Both decode as absent from older drafts.
- `QueuedHandoffRunner` (Handoff) is owned by the host and runs after every
  reconciliation (`reconcile(runs:)`). A queued send becomes eligible once its
  draft is attached, the run is complete or complete with warnings, the
  person's title is on the transcript, the notes are in the meeting and nothing
  is "Not saved". No speech, failed and cancelled runs end it as a definite
  failure. Decision 7 holds it (`.interrupted` stop reason, queued before this
  process started → `.recovered`, older than `queuedSendReconfirmAfter` (4 h) →
  `.stale`); otherwise it is claimed, unless `isCaptureActive`.
- A claim reads the dispatcher's environment, builds `MeetingSendSnapshot` from
  the draft as it is then, and is written to disk
  (`MeetingDraftLifecycle.transitionSend`, flushed and checked saved) before the
  dispatcher is called. The operation ID is Latch's `--request-id`. A
  `.claimed` draft with no dispatch in this process (a crash) is re-issued with
  the same ID and snapshot. An unknown outcome (`failureIsDefinite == false`)
  is `.failed(definite: false, retry: snapshot)`; `retrySend` re-issues it.
  In-process duplicates are prevented by `inFlight`, checked before any await.
- `MeetingSendControlling` (queue, cancel before claim, confirm a held send,
  retry, clear an outcome) is what the tray and notifications call; the host
  implements it over the runner. Deleting a draft waits for an in-flight
  dispatch (`waitForInFlight`). `TranscriptAgentRequest.delivery` is
  `.background` for sends nobody is watching: the app's dispatcher then never
  activates Latch and refuses unless `latch capabilities` lists
  `create-request-id`.
- `QueuedHandoffNotice` (sent, held, failed) goes to a `QueuedHandoffNotifying`
  (the app's `QueuedHandoffNotifications`); the draft and row are the record.

## Transcripts window design system

`UI/TranscriptDesign.swift` holds the tokens, type roles, review and speaker
colours, glass surfaces, and small reusable views (chip, flag dot, speaker dot)
that the Transcripts window is built from. Screens use those rather than their
own numbers and colours.

### Glass rules

- **Glass for controls.** The toolbar, the transport capsule, toasts, the hover
  tool pill on a row, and the sidebar draw on `glassSurface(shape:)`.
- **Flat tints for content.** Turn rows, chips, and sheets sit on the window
  background with plain tints, never glass. Glass on glass hides the material
  beneath it, which is what glass is for.
- **Tint only for meaning.** Orange means check this (uncertain or inferred
  speaker, estimated timing); red means overlapping speech; the accent means
  playing or selected; a speaker colour means who spoke. Nothing else is tinted.
- **macOS 15 fallback.** `glassEffect` needs macOS 26. On macOS 15 the same
  shapes are drawn in `.regularMaterial` with a hairline and shadow, and both
  must look equivalent at a glance.

### Speaker colours

Speakers are coloured by their position in the transcript's speaker table
(blue, teal, orange, purple, then pink, indigo, green, brown, repeating), so a
rename never changes a colour and reopening a file gives the same ones. An
unknown speaker has no colour and is drawn as a dashed neutral dot.
`TranscriptViewModel.color(forSpeakerID:)` exposes the palette to views.
