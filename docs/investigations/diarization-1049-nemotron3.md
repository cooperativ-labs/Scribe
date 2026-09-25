# Nemotron 3 Diarization and Qwen3-ASR evaluation — coo:1049

Investigated 2026-09-24, one day after both NVIDIA's Nemotron 3 Diarization release
and FluidAudio v0.17.0/v0.17.1. No production code was changed.

**Decision: do not switch now. Keep FluidAudio's offline VBx pipeline as the
production diarizer.** Add Nemotron 3 as a benchmark engine once upstream fix
FluidAudio #952 ships in a tagged release. Only then decide, using Scribe's own
recordings.

## 1. The framing: Nemotron 3 *vs* FluidAudio is not the choice

FluidAudio is a runtime, not a model. Scribe pins FluidAudio 0.15.7 and uses its
**offline VBx** stack: pyannote community-1 segmentation, WeSpeaker embeddings, and
AHC warm start followed by VBx clustering (`OfflineDiarizationAdapter`).

FluidAudio **v0.17.0 (2026-09-23) already ships `Nemotron3Diarizer`** (PR #883). It
comes with converted CoreML presets at `FluidInference/nemotron-3-diarization-coreml`,
which are public, ungated and OpenMDW-1.1 (commercial use OK). So adopting
Nemotron 3 means a FluidAudio pin bump plus a new adapter, not a new dependency.
The real choice is **VBx (community-1) vs Nemotron 3, both inside FluidAudio**.

## 2. What Nemotron 3 Diarization is

- About 100M-parameter end-to-end Streaming Sortformer successor, with an
  arrival-order speaker cache.
- No separate segmentation, embedding or clustering stages, so nothing to tune.
- **Hard cap of 8 speakers.** Output is `[T, 8]` per-frame speaker probabilities at
  10 ms resolution, and it handles overlapping speech natively.
- Streaming or offline presets range from 0.32 s to 30.4 s latency.

Published DER from the NVIDIA card (forced-alignment references, collar 0):

| Set | Offline (30.4 s) | Lowest-latency preset |
|---|---:|---:|
| AMI test MHM | 9.25 | 10.05 (0.32 s) |
| AMI test SDM | 11.14 | 12.95 (0.32 s) |
| CALLHOME part 2 | 9.10 | 10.29 (1.04 s) |
| DIHARD III | 12.73 | 13.55 (0.32 s) |

FluidAudio's CoreML port, measured on AMI MHM on an M5 Pro, lands about 0.25 DER
above NVIDIA (fp16 vs bf16), with speed between 31x and 904x real time:

| Preset | DER | Speed (× real time) |
|---|---:|---:|
| `fast128` | 9.36 | 546x |
| `offline` | 9.47 | 904x |
| `fast32-split-w8a8` (95 MB weights) | 9.76 | 185x |

Speaker counting is the weak spot on short windows: 68.8–75% of meetings get the
right count, versus 87.5–100% on longer windows.

**Comparison to what Scribe runs today.** FluidAudio reports its offline VBx pipeline
at **10.62% DER on the full AMI SDM 16-meeting set**, with 12/16 meetings getting the
right speaker count, at 69.8x real time. The scoring references differ (the
standard AMI annotations vs NVIDIA's forced-alignment references), so the numbers
are not strictly comparable. But on published evidence the two engines sit in the
**same accuracy band**, not a clear step up. Baseten's launch comparison agrees:
Nemotron 3 beats Meta's model at every latency, but **loses to pyannote
community-1 on AMI**, which is the recipe Scribe's VBx path uses.

## 3. Why it is unlikely to fix Scribe's actual errors

The coo:979 and coo:1004 measurements put Scribe's clustering error at 0.5–0.95%
wrong-speaker words. The dominant residual is **unknown words (3.6–7.8%)** created
by the per-word attribution rule meeting approximate TDT word boundaries. A
lower-DER diarizer mostly attacks speaker confusion, which is already small.

Two Nemotron properties *could* help at the margins, but neither is measured:

- 10 ms frame output with native overlap handling might cut boundary unknowns.
- Nemotron should be free of VBx's cluster-collapse failure mode (coo:979).

## 4. Integration costs and risks

1. **No speaker embeddings.** `Nemotron3Diarizer` returns only activity
   probabilities or segments. `SpeakerLibrary` identity matching and enrollment
   depend on the per-cluster WeSpeaker vectors in `embeddings.json`. Adopting
   Nemotron means a hybrid pipeline: Nemotron segments, then a WeSpeaker embedding
   pass per Nemotron speaker. That hybrid is new representation work (a new
   `preprocessingVersion`) and voiceprints would have to be re-enrolled, as in
   coo:979.
2. **8-speaker cap.** The coo:1004 timestamped benchmark meeting had **9** named
   speakers. Past 8, speakers are forced into existing arrival-order slots, which
   silently mislabels them. VBx has no fixed cap. A production switch needs a
   fallback, for example staying on VBx when the known count is above 8.
3. **Known-count controls do not map.** Sortformer has no
   `withSpeakers(exactly:)` equivalent, and the import/reprocess speaker-count UI
   relies on that behavior.
4. **Day-one runtime bug that hits this machine class.** Stock v0.17.1 crashes on
   the first prediction with `Output backing for feature named 'speaker_preds' is
   not compatible` on M3 Max with `.cpuAndNeuralEngine`, and on **an M5 running
   macOS 27 with the default `.all`** (#951). Fix PR #952 is open and unmerged. The
   `ANECCompile()` failure on M3 is tracked separately. Scribe's worker defaults to
   `.cpuAndNeuralEngine` on macOS 27.
5. **Compatibility surface.** The FluidAudio pin is exact on purpose (ASR token
   timing, long-file merge, diarization). Moving 0.15.7 → 0.17.x also changes the
   ASR path Scribe relies on, and needs the full coo:1004 re-validation.

## 5. Benchmark setup and VBx baseline (CAB call)

The Nemotron 3 engine itself has not been run. Building the unreviewed upstream
PR #952 branch was blocked by this session's permission policy, and stock v0.17.1
is the build affected by #951.

**The CAB call is restored for benchmarking.** It is a 9-speaker, 1 h 57 m call:

- Meeting `meeting--cecb678e89d2e0bc89c9687e1c980d5b`, run
  `C465C5EC-6EFF-4C43-A472-2EB2367BFA78`.
- It was freshly re-imported on 2026-09-24 with the pinned FluidAudio 0.15.7.
- The source checksum matches `canonical-transcript.json`.

`Tools/DiarizationAnalysis/experiments/corpus-v1.json` now points its `cab` entry at a
**frozen, gitignored snapshot** of this run in
`benchmark-files/CAB/meeting--cecb678e…/`. Hashes are in
`benchmark-files/CAB/snapshot-manifest.json`, and the canonical SHA-256 is
`9e7a1140…ed25`. Future app edits to the meeting cannot invalidate the benchmark.
The committed `benchmark-files/CAB` references are unchanged and still match their
recorded hashes. Historical evidence JSONs keep the old `01D75E08` run on purpose.

The corpus's other recording, `latest` (`meeting--68b03b5a…`), is **not on disk**.
Until it is restored, `quality.py`'s full-corpus baseline cannot run; `wder.py`
works per run.

**Fresh VBx baseline** (`wder.py` against the timestamped segment reference;
evidence in [diarization-1049-cab-vbx-baseline.json](diarization-1049-cab-vbx-baseline.json)).
Alignment covers 19,488 scored words (96.9% of replay words, 94.9% of reference
segments):

| Labels | Correct | Wrong speaker | Unknown | WDER |
|---|---:|---:|---:|---:|
| Canonical | 95.315% | 0.513% | 4.172% | 4.685% |
| Effective (after reconciliation) | 98.112% | 0.585% | 1.303% | 1.888% |

This is consistent with the 2026-09-01 scoring of the earlier run: 4.094% and
1.808% WDER.

VBx produced 10 clusters for 9 real speakers; the extra cluster holds 1.7 s. The
smallest real speaker says **232 of 19,578 reference words (1.19%)**. Nemotron's 8
slots force at least that share onto another speaker, so on this call its
wrong-speaker rate starts at about **2× VBx's entire 0.585%** before any error of
its own. That makes the CAB call a decisive test of the 8-speaker cap. A 2–6
speaker meeting is needed to judge Nemotron on its merits.

Reproduce with `benchmark-files/scripts/score.sh cab`. See `benchmark-files/README.md`
for scoring any RTTM-emitting engine, including the Nemotron 3 commands. The RTTM
converter was validated by a VBx round trip: canonical 4.680% vs 4.685% (one word,
due to RTTM carrying no quality scores), and identical effective scores.

Nemotron plan, once #952 is in a tagged release: build that tag's `fluidaudiocli`
in an isolated scratch path and record its SHA-256. Then run the three commands in
`benchmark-files/README.md` for the `offline` and `fast128` variants, and compare
wrong-speaker %, unknown %, speaker count and wall time (VBx: 65.8 s) against the
table above. Also score a 2–6 speaker meeting once one has a reference.

Adopt only if Nemotron (plus the WeSpeaker pass) beats VBx on WDER without
losing more than 8-speaker meetings.

## 6. Qwen3-ASR (requested during the investigation)

**Decision: do not replace Parakeet TDT v3.** At most, run a small offline
benchmark of the Qwen3-ForcedAligner as a timing-refinement pass.

What it is:

- Open-weight models `Qwen3-ASR-0.6B` and `Qwen3-ASR-1.7B`, plus
  `Qwen3-ForcedAligner-0.6B`. All Apache-2.0, released 2026-01-29 (arXiv 2601.21337).
- `Qwen3-ASR-Flash` is available only through the DashScope API.
- Architecture is an audio encoder feeding a Qwen3 LLM decoder. It covers 30
  languages and accepts free-form context prompting.
- Each call handles at most **20 minutes** of audio.
- The ASR model produces **no word or token timestamps**. Timestamps need the
  separate aligner, which works on at most about **300 s per window** at 80 ms slots.

Open ASR Leaderboard WER (2026-09-19), as gathered by research. The Qwen/Parakeet
ordering is consistent with speech-swift's on-device numbers:

| Model | Avg | AMI | Earnings22 | Speed (× real time, GPU) |
|---|---:|---:|---:|---:|
| Qwen3-ASR-1.7B | 4.31 | 8.31 | 5.84 | 820 |
| Qwen3-ASR-0.6B | 5.05 | 9.33 | 7.83 | 744 |
| **Parakeet TDT v3 (current)** | 4.86 | 9.42 | 5.85 | 6076 |
| Cohere transcribe 03-2026 | 4.67 | 7.02 | 7.88 | 907 |

- **The 0.6B model is no upgrade over Parakeet.** It roughly ties on AMI and is
  worse overall.
- **The 1.7B model gains about 1.1 WER on AMI** and ties on Earnings, at about
  3× the parameters.
- **On Apple silicon it is slower and heavier.** speech-swift measured it on an
  M5 Pro against Parakeet's CoreML port (117x, 0.9 GB):

  | Build | Speed (× real time) | Memory |
  |---|---:|---:|
  | 0.6B, MLX 8-bit | 66x | 1.3 GB |
  | 1.7B, MLX 8-bit | 30x | 2.7 GB |
  | 0.6B, CoreML INT8 (also less accurate) | 10x | 1.4 GB |

Why it does not fit Scribe:

- **FluidAudio removed its experimental Qwen3 ASR backend** in commit `17081252`
  (PR #676, merged 2026-06-10), calling it slow and little used. There is no
  maintained Swift/CoreML path. The options are a new MLX-Swift dependency
  (soniqo/speech-swift) or a Python sidecar, and both are poor fits for the
  local-only, exact-pin worker.
- **Timing becomes Scribe's problem.** Scribe would have to split audio with VAD
  for ASR, run the aligner in its own windows, then rebase and merge the seams,
  replacing FluidAudio's validated chunk merge (`docs/feasibility/asr-timing.md`).
- **Custom vocabulary does not carry over.** The CTC-rescoring design in
  `docs/decisions/custom-transcription-vocabulary.md` does not apply. Qwen's
  prompt biasing is unmeasured.
- **The LLM decoder hallucinates.** Repetition loops on silence are documented,
  and the aligner stamps the first word near 0 s when audio starts with silence.

The one interesting piece is the aligner. English mean boundary error is 37.5 ms,
vs WhisperX at 92 ms and NeMo NFA at 108 ms. Scribe's biggest residual error is
unknown words at diarization boundaries, caused by TDT's quantized 80–320 ms
durations. A benchmark that re-times *Parakeet's* text with the Qwen3 aligner and
scores it with `wder.py` would directly test whether better word boundaries reduce
unknowns.

If meeting WER itself becomes the bottleneck, evaluate **Cohere transcribe**
before Qwen. It is the AMI leader above, and FluidAudio already ships a CoreML
port.

## Sources

- [nvidia/Nemotron-3-Diarization model card](https://huggingface.co/nvidia/Nemotron-3-Diarization)
- [Baseten launch post](https://www.baseten.co/blog/nvidia-nemotron-3-diarization/)
- [Unite.AI release coverage](https://www.unite.ai/nvidia-releases-nemotron-3-diarization-open-weight-speaker-model/)
- FluidAudio [v0.17.0 release](https://github.com/FluidInference/FluidAudio/releases/tag/v0.17.0), [PR #883](https://github.com/FluidInference/FluidAudio/pull/883), [issue #951](https://github.com/FluidInference/FluidAudio/issues/951), [PR #952](https://github.com/FluidInference/FluidAudio/pull/952)
- FluidAudio `Documentation/Benchmarks.md` (offline VBx AMI SDM 10.62%) and `Documentation/Diarization/Nemotron3.md`
- Qwen: [QwenLM/Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR), [Qwen3-ASR-1.7B](https://huggingface.co/Qwen/Qwen3-ASR-1.7B), [Qwen3-ForcedAligner-0.6B](https://huggingface.co/Qwen/Qwen3-ForcedAligner-0.6B), [arXiv 2601.21337](https://arxiv.org/abs/2601.21337), [Open ASR Leaderboard](https://huggingface.co/spaces/hf-audio/open_asr_leaderboard), [soniqo/speech-swift](https://github.com/soniqo/speech-swift), FluidAudio [PR #676](https://github.com/FluidInference/FluidAudio/pull/676)
- Local: `docs/investigations/diarization-979.md`, `diarization-1004-recommendations.md`, `diarization-1004-wder-cab-2026-09-01.json`
