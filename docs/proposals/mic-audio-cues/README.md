# Air Ding v2 — selected mic cues

A soft ding with a rounded A4 body underneath the original A5 tone, a quiet
A3 foundation, softened upper shimmer, a hint of breath, and short stereo
reflections. Compared with v1, the lower notes carry more energy, the body
decays a little longer, and the onset and airy layer are softer. Peak level is
unchanged so this adds body through timbre rather than simply raising volume.
The onset gently rises into pitch and opens into
a fading tail. The stop cue is the exact sample-frame reversal of the start:
it gathers inward and closes with the same tone.

- `Scribe/App/Resources/ScribeMicStart.wav`: listening begins, 0.72 seconds.
- `Scribe/App/Resources/ScribeMicStop.wav`: listening ends, 0.72 seconds; exact reversed start.

All files are stereo 48 kHz, 16-bit PCM WAV, with a peak of -12 dBFS and
silent endpoints. Synthesized from scratch; no external audio samples.
Selected for the application on 2026-09-26. The approved WAVs are bundled as
`Scribe/App/Resources/ScribeMicStart.wav` and `ScribeMicStop.wav`, replacing
the system Tink/Pop cues. Playback respects the existing dictation sound
setting and trigger timing.
Earlier candidates and audition previews have been removed; only the two
application sound files are retained.

Regenerate from the repository root:

```sh
python3 docs/proposals/mic-audio-cues/generate.py
```

The generator writes directly to the two application resource paths above.

Play the pair:

```sh
afplay Scribe/App/Resources/ScribeMicStart.wav
sleep 0.45
afplay Scribe/App/Resources/ScribeMicStop.wav
```
