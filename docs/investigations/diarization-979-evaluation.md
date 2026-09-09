# Combined evaluation and engine decision — coo:979.pmft

Evaluated 2026-09-08. **Retain FluidAudio 0.15.6 as the production engine. An immediate replacement is not supported.** Its verified current build fixes the original collapse. Keep SpeakerKit as the next integration candidate if reviewed recordings confirm that its smaller remaining advantage matters in use. No production engine replacement, license purchase, staging, or commit was performed.

## Correction to the earlier investigation

The earlier artifacts named `v0.15.6-automatic-metrics.json` and `v0.15.6-exact-two-metrics.json` reported 577/5 and 576/5 intervals and approximately 51% agreement. **Those are superseded as evidence about the current pinned engine.** They lacked executable provenance. The default `Workers/TranscriptionWorker/.build/out/Products/Debug` executables predate the successful upgrade build; reading the current `Package.resolved` does not establish what an existing executable contains. The precise binary used for those historical artifacts cannot be authenticated retrospectively.

This evaluation first ran the upgrade objective's verified compatibility build, whose FluidAudio checkout is exactly `4dbf4f9f9a5ff3a53ade848d7ba4e3df13db859b`. It then built **the current worker sources afresh in release mode**, against that same source, in an isolated directory. The dependency's only tracked local difference is package wiring to the official local binary artifact; its algorithm source is unchanged. Both builds produce **606 intervals, split 331/275** on this meeting. Current artifacts include the binary SHA-256, audio SHA-256, engine revision, applied configuration and occupancy diagnostics. ASR was also rerun using the verified upgrade executable; its adapter source matches the current adapter byte-for-byte.

The current benchmark initially failed to compile because its boolean parser lacked explicit returns in two switch branches. That small defect is fixed. A source pin, old build path, or handwritten revision label must never substitute for a successful rebuild and executable hash in a future evaluation.

## Controlled full-meeting comparison

All four rows below use **identical prepared audio, the same fresh Parakeet 0.15.6 tokens, and actual current Swift timing reconciliation, attribution and paragraph grouping**. Only diarization changes. SpeakerKit's own transcription/reconciliation/grouping is not used. Simultaneous intervals are retained; exclusive reconciliation is explicitly disabled.

| Diarizer / count | Matched-text agreement proxy | Wrong speaker proxy | Unknown proxy | All unknown words | Paragraphs | Single-word paragraphs | Process wall time |
|---|---:|---:|---:|---:|---:|---:|---:|
| FluidAudio automatic | 91.257% | 0.948% | 7.796% | 813 | 1,032 | 401 | 17.308 s |
| FluidAudio exact two | 91.257% | 0.948% | 7.796% | 813 | 1,032 | 401 | 17.305 s |
| SpeakerKit automatic | 94.304% | 0.765% | 4.932% | 511 | 988 | 446 | 9.023 s |
| SpeakerKit exact two | 94.304% | 0.765% | 4.932% | 511 | 988 | 446 | 8.273 s |

Automatic and exact-two produce identical intervals within each engine on this recording. Current FluidAudio yields 1,834 embeddings, no fallback masks in the log, 911/923 chunk assignments, and 52.90% dominant summed interval occupancy. `separationAppearsCollapsed` is false. Its automatic path uses constrained assignment; the known-count path disables that assignment option, but both end with the same two voices here. This is not evidence that exact count always enforces a particular emitted count: both engines emit just one voice on the shortest local recording even when two is requested.

SpeakerKit gains **283 matched correct tokens**: 266 move out of unknown and net wrong-speaker assignments fall by 17. This is a meaningful candidate improvement, but primarily a coverage/attribution difference rather than another wholesale clustering failure. It emits 226 intervals intersecting another speaker, versus FluidAudio's 13. These are model output counts, not verified overlap events or overlap accuracy.

Both are optimized release executables on an Apple M1 Pro, 32 GiB RAM, macOS 27.0 build 26A5425a. Measurements are serial, single-process runs with models already downloaded, include process/model startup, and exclude build/download/ASR/host replay. They are observed runtimes, not stable speed guarantees: model caches, worker parallelism and Core ML scheduling differ. The earlier 70–76 second unverified timings are not a valid current performance baseline. A prior debug compatibility control took approximately 24.55 seconds and produced the same FluidAudio intervals.

## Coverage and accuracy limits

The MacWhisper JSON has **no timestamps and is not human ground truth**. Exact lexical alignment matches 9,287 of 9,657 current hypothesis tokens and 9,543 reference tokens: **96.169% hypothesis coverage and 97.317% reference coverage**. It excludes 370 hypothesis tokens and 256 reference tokens; 370 reconstructed words have no matched reference token. Their speaker accuracy is unknown. Unknowns remain disagreements, and a globally optimal one-to-one label mapping removes arbitrary cluster names. Repeated phrases can align incorrectly. No DER, WDER, acoustic word-boundary accuracy, confidence interval, or human accuracy score is claimed.

The investigation meeting has been used repeatedly for development and is **not held out**. No new annotated multi-party accuracy dataset became available. Synthetic fixtures are not substituted for real speaker accuracy evidence.

## Timing and fragmentation versus the original baseline

| Metric | Original 0.12.4 replay | Combined current FluidAudio |
|---|---:|---:|
| Reconstructed words | 9,650 | 9,657 |
| First word start | 67,840 ms | 67,760 ms |
| Longest word | 16,640 ms | 1,760 ms |
| Words over one second | 440 | 28 |
| Adjacent word gaps at least one second | 0 | 168 |
| Paragraphs / legacy rows | 1,447 | 1,032 |
| Single-word paragraphs / rows | 577 | 401 |
| Known-speaker paragraphs / rows | 832 | 483 |
| Known-speaker median words | 9 | 15 |
| Single-word known-speaker paragraphs / rows | 92 | 9 |

The source timeline remains 3,487,171 ms and the expected opening silence is preserved. The fresh ASR has slightly different text/times (15,371 tokens versus 15,369), so the old bit-identical 0.12.4→0.12.5 timing result is not extended to 0.15.6. The current 80 ms earlier first word is decoder output, not a source offset change. Decoder bins remain approximate timing, not forced alignment.

Using the *same current words and FluidAudio attribution*, old sentence grouping would produce 1,343 rows/486 single-word rows. Current paragraph grouping produces 1,032/401: **311 fewer rows without altering word labels**. The original 1,447-row baseline also includes the old timing/clustering defects, so those improvements must not all be credited to grouping.

SpeakerKit's 988 paragraphs include **560 known paragraphs, median 12.5 words, and 80 single-word known paragraphs**, versus FluidAudio's 483/15/9. It resolves many unknown words but also introduces more short attributed turns. Listening is needed to determine whether these are correctly recovered acknowledgments or fragmentation. Neither output should be tuned to mimic the timestamp-free reference's 260 blocks.

## Available held-out diagnostics

These three recordings were not used to tune this evaluation. Their old saved words are fixed across both diarizers; they retain historical duration limitations. Speaker counts are **emitted counts**, not known truth; exact two is a sensitivity test, not an assertion about the recording.

| Recording prefix / duration | Engine | Auto→exact-two speakers | Unknown words | Auto→exact-two paragraphs | Auto→exact-two runtime |
|---|---|---:|---:|---:|---:|
| 2419c5a3 / 155.277 s | FluidAudio | 3→2 | 22/212 | 35→35 | 3.134→1.263 s |
| 2419c5a3 / 155.277 s | SpeakerKit | 3→2 | 19/212 | 30→30 | 0.675→0.577 s |
| 50e77e27 / 37.482 s | FluidAudio | 2→2 | 7/59 | 12→12 | 0.657→0.666 s |
| 50e77e27 / 37.482 s | SpeakerKit | 4→2 | 8/59 | 15→13 | 0.386→0.377 s |
| 53d2add9 / 7.827 s | FluidAudio | 1→1 | 1/14 | 2→2 | 0.400→0.402 s |
| 53d2add9 / 7.827 s | SpeakerKit | 1→1 | 1/14 | 2→2 | 0.309→0.300 s |

SpeakerKit is not uniformly better even on these diagnostics. Its four-versus-two result on the 37-second recording is unresolved without listening. **Held-out speaker accuracy coverage is zero**, including zero annotated three-/four-person meetings.

## Representative excerpt audit

Eight local clips and 100 ms RMS measurements were generated by `review_excerpts.py`. [Candidate annotations](diarization-979/excerpt-review-candidates.json) record exact source offsets and model observations. Raw clips and a blank `human-review.tsv` are local at `/private/tmp/coo979-pmft-review`; rerun the tool if temporary files are removed.

| Source interval (seconds) | Purpose and observed disagreement |
|---|---|
| 65–85 | Opening exchange: FluidAudio emits one voice, SpeakerKit two with overlap. The text-only reference is itself questionable here. |
| 79–101 | Historical swallowed pause: 183/220 RMS bins below −50 dBFS; acoustic energy supports a quiet region, but does not establish speech boundaries. |
| 2339.880–2352.600 | Long mid-recording decoder gap; both engines show two voices around it, only SpeakerKit flags overlap. |
| 604.760–611.080 | Short ASR acknowledgment: FluidAudio one voice versus SpeakerKit two. |
| 990.122–995.820 | Both engines flag overlap in the excerpt. |
| 214.469–219.980 | SpeakerKit flags overlap; FluidAudio does not. |
| 630.400–636.160 | Longest reconstructed word; both assign one voice. |
| 739–749 | Nominal chunk-grid boundary; both show one voice and multiple intervals. |

**Listening-based annotation remains incomplete.** This session has no audio-listening tool. These are inspected signal/model observations and explicit review candidates, not invented human judgments. RMS cannot identify speakers, acknowledgments, or overlapping speech; neither agreement between engines nor a low energy threshold makes a ground-truth label. All human annotation fields are null. Have a reviewer mark speaker changes, true pauses, acknowledgment ownership, overlap, and uncertainty before claiming acoustic accuracy or adopting the candidate on that basis.

## Alternative feasibility and decision gates

The tested alternative is **open-source SpeakerKit**, SDK commit `ea872ffd35705aa757f33033500b9b0d40bd38df`, not an authenticated copy of MacWhisper's Pro diarizer. Its source is MIT licensed; incorporated components have notices. The public Argmax model repository is accessible without purchase or credentials, and its May 7 commit removed a proprietary notice. The model card does not provide a complete redistribution license statement for every converted asset: public download access and the SDK's MIT license are not blanket clearance for bundling weights. Confirm those notices before redistribution. [SDK source/license](https://github.com/argmaxinc/argmax-oss-swift/tree/ea872ffd35705aa757f33033500b9b0d40bd38df), [model repository revision](https://huggingface.co/argmaxinc/speakerkit-coreml/tree/86ec9c929b52208b6656eb6a6361ed0d822a1f78).

Inference runs locally on Apple Silicon. A predownloaded `modelFolder` with downloads disabled needs no Pro subscription for the tested OSS path. Pro is separate: its documented initialization verifies subscription/device licensing over the network and communicates deidentified performance metrics. No Pro credential was used or account provisioned. [Pro installation](https://app.argmaxinc.com/docs/guides/upgrading-to-pro-sdk).

The inspected model configuration uses pyannote-v3 W8A16 segmenter/embedder assets with the pyannote-v4 W32A32 PLDA clusterer; broad “community-1” branding is less precise than those actual asset paths. File hashes are recorded. The CLI preserves overlap by default, but **the direct `PyannoteDiarizationOptions` initializer defaults exclusive reconciliation to true**; any integration must explicitly set it false to preserve Scribe's overlap semantics.

SpeakerKit exposes raw pre-PLDA per-speaker centroid embeddings and explicitly requires application-specific threshold calibration. **Existing FluidAudio enrollments are not compatible by assumption**, even if dimensionality or upstream model family matches. An integration needs a distinct model/preprocessing tuple, separate stored enrollments or re-enrollment, calibrated matching thresholds, and preservation of existing vectors. No conversion or relabeling of old voiceprints was attempted.

Retain the current production engine and diagnostics. The next accuracy work should review these disagreements and obtain independent annotated two-, three- and four-person meetings, including rare speakers and true overlap. Consider an **opt-in SpeakerKit integration only after** its advantage persists with identical ASR/grouping on that set, short-recording count errors are understood, and model redistribution/voiceprint migration are settled. The three-point development-recording proxy advantage is insufficient to justify replacing a now-working engine. Known-count controls remain useful but do not improve this particular current two-person result.

## Reproducibility and validation

See [tool instructions](../../Tools/DiarizationAnalysis/README.md), [16-case aggregates](diarization-979/combined-evaluation.json), and [provenance/model hashes](diarization-979/evaluation-provenance.json). Outputs contain no transcript text, names, audio, or voice embeddings. Raw benchmark and host replay files stay in private temporary storage. All 16 cases passed Python-versus-actual-Swift word attribution and paragraph-size parity; arbitrary cluster labels are normalized by first source appearance. Three metric contracts cover unmatched coverage, unknown labels, overlap ties and half-millisecond rounding. The rounding check fixed Python's ties-to-even discrepancy with Swift. All 32 selected host timing/attribution/grouping regressions pass, and the current release benchmark builds successfully.

The original investigation transcript remains revision 29, 1,447 segments, source duration 3,487,171 ms. Reprocessing was confined to scratch artifacts; no user meeting or enrolled voiceprint was written.
