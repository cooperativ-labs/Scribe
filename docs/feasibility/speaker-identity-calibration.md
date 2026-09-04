# Speaker identity calibration

Local-synthesis stand-in run using the worker's pinned WeSpeaker export (`wespeaker-embedding-coreml`, revision `1ed7a662fdc7109e36d822db793ee6eebdaf8594`, preprocessing `fluidaudio-offline-fbank-16khz-mono-v0.12.4`, normalization `l2-unit-v1`, transform `identity-v1`). Enrollment used confirmed 16 kHz excerpts totaling about 20–60 seconds per person. Evaluation used disjoint sessions, a 44.1 kHz device-shift condition, similar US-English voices (Samantha vs Shelley), a UK-English enrolled voice, an unknown voice (Albert), and a brief utterance.

This is **not** the consented human evaluation set required by the 1% wrong-name release gate. It measures whether the worker-exported representation plus the matcher can be calibrated at all.

- Enrollment embeddings: 9
- Evaluation embeddings: 9
- Evaluation clusters: 5
- Enrolled profiles: Jake (3 signatures), Sarah (3 signatures), Daniel (3 signatures)

## Operating point

On this corpus, every sweep that named anyone had precision 1.000, unknown false accepts 0, and coverage 0.250. The chooser keeps the strictest such point: **0.80 automatic**, suggestion 0.65, margin 0.08, one consistent excerpt. Production matcher defaults remain 0.85 / two excerpts.

- Precision: 1.000
- Wrong-name rate: 0.000 (budget 0.01)
- Coverage: 0.250
- Unknown false accepts: 0 / 1
- Meets 1% wrong-name target on this corpus: yes

## Coverage shortfall

Wrong-name rate met the 1% budget (0 wrong names among 1 automatic assignment). Automatic coverage was only 25% (one of four known clusters). Sweeps at the production default of 0.85 with two consistent excerpts abstained on everyone. The naming band on this TTS stand-in is 0.70–0.80; the strictest point in that band is 0.80 automatic / 0.08 margin / 1 excerpt (`SpeakerIdentityMatcherConfiguration.localSynthesisStandIn`). Matcher production defaults stay at 0.85 / two excerpts until consented human recordings exist.

Recommended next step: collect disjoint consented sessions with different devices, similar voices, unknown people, and brief speech, extract embeddings with `EnrollmentEmbeddingExtractor`, and re-run `SpeakerEnrollmentCalibration` before locking matcher defaults.

## Sweeps

| auto | margin | excerpts | automatic | precision | coverage | unknown FA |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0.7 | 0.03 | 1 | 1 | 1.000 | 0.250 | 0 |
| 0.7 | 0.03 | 2 | 1 | 1.000 | 0.250 | 0 |
| 0.7 | 0.05 | 1 | 1 | 1.000 | 0.250 | 0 |
| 0.7 | 0.05 | 2 | 1 | 1.000 | 0.250 | 0 |
| 0.7 | 0.08 | 1 | 1 | 1.000 | 0.250 | 0 |
| 0.7 | 0.08 | 2 | 1 | 1.000 | 0.250 | 0 |
| 0.75 | 0.03 | 1 | 1 | 1.000 | 0.250 | 0 |
| 0.75 | 0.03 | 2 | 1 | 1.000 | 0.250 | 0 |
| 0.75 | 0.05 | 1 | 1 | 1.000 | 0.250 | 0 |
| 0.75 | 0.05 | 2 | 1 | 1.000 | 0.250 | 0 |
| 0.75 | 0.08 | 1 | 1 | 1.000 | 0.250 | 0 |
| 0.75 | 0.08 | 2 | 1 | 1.000 | 0.250 | 0 |
| 0.8 | 0.03 | 1 | 1 | 1.000 | 0.250 | 0 |
| 0.8 | 0.03 | 2 | 0 | — | 0.000 | 0 |
| 0.8 | 0.05 | 1 | 1 | 1.000 | 0.250 | 0 |
| 0.8 | 0.05 | 2 | 0 | — | 0.000 | 0 |
| 0.8 | 0.08 | 1 | 1 | 1.000 | 0.250 | 0 |
| 0.8 | 0.08 | 2 | 0 | — | 0.000 | 0 |
| 0.85 | 0.03 | 1 | 0 | — | 0.000 | 0 |
| 0.85 | 0.03 | 2 | 0 | — | 0.000 | 0 |
| 0.85 | 0.05 | 1 | 0 | — | 0.000 | 0 |
| 0.85 | 0.05 | 2 | 0 | — | 0.000 | 0 |
| 0.85 | 0.08 | 1 | 0 | — | 0.000 | 0 |
| 0.85 | 0.08 | 2 | 0 | — | 0.000 | 0 |
| 0.88 | 0.03 | 1 | 0 | — | 0.000 | 0 |
| 0.88 | 0.03 | 2 | 0 | — | 0.000 | 0 |
| 0.88 | 0.05 | 1 | 0 | — | 0.000 | 0 |
| 0.88 | 0.05 | 2 | 0 | — | 0.000 | 0 |
| 0.88 | 0.08 | 1 | 0 | — | 0.000 | 0 |
| 0.88 | 0.08 | 2 | 0 | — | 0.000 | 0 |
| 0.9 | 0.03 | 1 | 0 | — | 0.000 | 0 |
| 0.9 | 0.03 | 2 | 0 | — | 0.000 | 0 |
| 0.9 | 0.05 | 1 | 0 | — | 0.000 | 0 |
| 0.9 | 0.05 | 2 | 0 | — | 0.000 | 0 |
| 0.9 | 0.08 | 1 | 0 | — | 0.000 | 0 |
| 0.9 | 0.08 | 2 | 0 | — | 0.000 | 0 |
| 0.92 | 0.03 | 1 | 0 | — | 0.000 | 0 |
| 0.92 | 0.03 | 2 | 0 | — | 0.000 | 0 |
| 0.92 | 0.05 | 1 | 0 | — | 0.000 | 0 |
| 0.92 | 0.05 | 2 | 0 | — | 0.000 | 0 |
| 0.92 | 0.08 | 1 | 0 | — | 0.000 | 0 |
| 0.92 | 0.08 | 2 | 0 | — | 0.000 | 0 |
| 0.95 | 0.03 | 1 | 0 | — | 0.000 | 0 |
| 0.95 | 0.03 | 2 | 0 | — | 0.000 | 0 |
| 0.95 | 0.05 | 1 | 0 | — | 0.000 | 0 |
| 0.95 | 0.05 | 2 | 0 | — | 0.000 | 0 |
| 0.95 | 0.08 | 1 | 0 | — | 0.000 | 0 |
| 0.95 | 0.08 | 2 | 0 | — | 0.000 | 0 |
