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
