# Benchmark files

Reusable inputs for diarization and ASR benchmarking. Git tracks the references,
scripts and manifests. The meeting snapshots, audio, engine outputs (`*.rttm`)
and `results/` stay local through `.gitignore`.

| Recording | Speakers | Length | Reference (tracked) | Local snapshot (ignored) |
|---|---:|---:|---|---|
| `cab` | 9 | 1 h 57 m | `CAB/BENCHMARK CALL - Transcrpt segments.json` (timestamped), `… - Paragraphs.json` | `CAB/meeting--cecb678e…/runs/C465C5EC…` |
| `latest` | 2 | — | `Jake <> Neah/GroundTruth - Segements.json`, `… - paragraph.json` | **missing**: `meeting--68b03b5a…` is not on disk |

`Tools/DiarizationAnalysis/experiments/corpus-v1.json` points at these
references, and its `cab` run points at the frozen snapshot. The snapshot is the
point: re-editing or reprocessing the meeting in the app changes
`canonical-transcript.json`, which the corpus checks by hash.

## Scoring

```sh
benchmark-files/scripts/score.sh cab                            # saved VBx baseline
benchmark-files/scripts/score.sh cab /path/to/candidate.json     # another diarizer
```

`score.sh` keeps the snapshot's ASR `transcript.json` fixed, so only the diarizer
changes. It runs `wder.py` in canonical and effective label modes and writes
transcript-free JSON to `CAB/results/`. `replay.py` gives `swiftc` a valid
temporary directory even when the caller inherited a stale session `TMPDIR`.

VBx baseline, FluidAudio 0.15.7, scored 2026-09-24:

| Labels | WDER | Wrong speaker | Unknown |
|---|---:|---:|---:|
| Canonical | 4.685% | 0.513% | 4.172% |
| Effective | 1.888% | 0.585% | 1.303% |

Both rows cover 19,488 scored words. Diarization took 65.8 s for 7,021 s of audio
(about 107× real time). Details are in
`docs/investigations/diarization-1049-nemotron3.md`.

## Candidate engines that emit RTTM

`scripts/rttm_to_diarization.py` converts RTTM into the worker's
`diarization.json`. It names speakers `speaker_N` by first appearance, derives
`overlapsAnotherSpeaker`, and records `engine.runtimeRevision`. RTTM has no
quality scores, so every interval gets `qualityScore: 1`.

A round trip of VBx's own intervals (worker JSON → RTTM → converter) scores
canonical 4.680% instead of 4.685%, a 1-word difference from quality scores, and
identical effective scores. Treat differences under about 0.01 pp as noise.

Nemotron 3, once a FluidAudio release contains PR #952:

```sh
REC=benchmark-files/CAB/meeting--cecb678e89d2e0bc89c9687e1c980d5b/runs/C465C5EC-6EFF-4C43-A472-2EB2367BFA78
fluidaudiocli nemotron3-diarize "$REC/prepared.wav" --variant offline --output benchmark-files/CAB/results/nemotron3-offline.rttm
benchmark-files/scripts/rttm_to_diarization.py benchmark-files/CAB/results/nemotron3-offline.rttm \
  --output benchmark-files/CAB/results/nemotron3-offline.json \
  --runtime "FluidAudio <tag> nemotron3 offline" --revision <fluidaudio-sha> --source-duration 7021.027
benchmark-files/scripts/score.sh cab benchmark-files/CAB/results/nemotron3-offline.json
```

## Restoring or adding a snapshot

`CAB/snapshot-manifest.json` lists the SHA-256 of every snapshot file. To restore
from the app's meeting folder, copy with APFS clones (`cp -c`, no extra disk
space) and verify the hashes:

```sh
M="$HOME/Meeting Transcripts/meeting--cecb678e89d2e0bc89c9687e1c980d5b"
D=benchmark-files/CAB/meeting--cecb678e89d2e0bc89c9687e1c980d5b
mkdir -p "$D/runs/C465C5EC-6EFF-4C43-A472-2EB2367BFA78"
cp -c "$M/source.mp4" "$M/import.json" "$D/"
cp -c "$M"/runs/C465C5EC-6EFF-4C43-A472-2EB2367BFA78/{canonical-transcript,diarization,job,prepare,transcript,words,speaker-recognition}.json \
      "$M/runs/C465C5EC-6EFF-4C43-A472-2EB2367BFA78/prepared.wav" "$D/runs/C465C5EC-6EFF-4C43-A472-2EB2367BFA78/"
```

`embeddings.json` (voiceprints) is left out on purpose because replay does not
need it. For a new recording, follow the same layout: `<Name>/` for tracked
references, and `<Name>/meeting--<id>/` for the ignored snapshot. Then add a
`score.sh` case and a `corpus-v1.json` entry.
