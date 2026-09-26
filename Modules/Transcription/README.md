# Transcription

Transcript import, canonical transcript model, export, and the review UI
(`Sources/Transcription/UI`).

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
