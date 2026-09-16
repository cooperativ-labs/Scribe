# Transcript quality optimization and subsequent engine comparison

Created 2026-09-16 following the coo:1004 investigation. This plan defines two separate missions: optimize Scribe's existing FluidAudio pipeline, then compare the frozen optimized baseline with Argmax Pro and justified alternatives. All objectives are assigned to Codex with model `gpt-6-astra`. Creation does not start execution; objectives are sequential and auto-advance is off.

- Optimization mission: **coo:1016** — Optimize Scribe transcript quality with controlled experiments. Final baseline delivery: **coo:1016.a74j**.
- Engine comparison mission: **coo:1017** — Compare optimized FluidAudio with Argmax Pro and alternative engines. Its objective instructions require the coo:1016.a74j baseline before benchmarking; this is a documented prerequisite, not an automatically enforced cross-mission scheduler dependency.

## Goal

Improve word reconstruction, speaker attribution, and readable segmentation while determining which individual changes deliver the largest gains and which introduce errors. A reduction in unknown words or paragraph count is insufficient if it hides new speaker mistakes, removes words, or damages editing/export behavior.

Do not replace the transcription engine during the optimization mission. The comparison mission begins only after the optimization mission delivers a reproducible, frozen baseline. Its outcome is a supported engine recommendation, not automatic migration.

## Evidence and private inputs

- Prior mission: coo:1004. Read `docs/investigations/diarization-1004-plan.md`, the corresponding evidence JSON, and `Tools/DiarizationAnalysis/README.md`.
- Latest recording: `/Users/jake/Meeting Transcripts/meeting--68b03b5a278897e877fc4ec8b2f12784`.
- Run: `runs/487F2364-3579-4814-B06A-C4B3967DA074` within that recording.
- Comparison exports: prefer the user-provided copies `benchmark-files/Jake <> Neah/GroundTruth - Segements.json` and `benchmark-files/Jake <> Neah/GroundTruth - paragraph.json`; their hashes match the original `/Users/jake/Desktop/GroundTruth - Segements.json` and `/Users/jake/Desktop/GroundTruth - paragraph.json`.
- Detailed investigation: `/Users/jake/.codex/visualizations/2026/09/16/01a0a8f0-4789-7c51-a541-6052fe055744/scribe-macwhisper-comparison.md`. Aggregate, details, variants, sweep, short-turn, and transition JSON files are alongside it.
- Exploratory scripts, source copies, and private replay outputs: `/private/tmp/scribe-fragment-analysis-hjQmw0`. These are ephemeral aids, not durable dependencies; reimplement needed harness features in the repository.
- CAB comparison inputs: `benchmark-files/CAB/BENCHMARK CALL - Transcrpt segments.json` and `benchmark-files/CAB/BENCHMARK CALL - Paragraphs.json`, plus the saved run recorded in the coo:1004 evidence. The user reorganized the benchmark folders during planning; preserve that work. Resolve the recording from provenance rather than guessing a directory.

Use the user-provided `benchmark-files` references in place as the authoritative comparison inputs; Desktop copies are not required. Keep original recordings, saved runs, and reference files read-only. Use private evaluation directories for new inference, replay text, clips, or embeddings. Do not copy additional private transcript text/audio or model assets into tracked source. Store new aggregate results, hashes, tooling, and documentation in source control. If a required recording or repository reference is absent, identify it explicitly rather than silently substituting a corpus. Temporary exploratory files are optional and must not become a dependency.

Latest saved canonical SHA-256: `61fa4b95ef8cd9106e8450d81b8a865a851d3671c3d46c1ec5f4240e801074ff`.
Segment reference SHA-256: `02798ac0ba922bd0b12de0bde286291bfda783d27a3c06a706d86f4d0a33c532`.
Paragraph reference SHA-256: `46d0c8f7d307baf0f9be1318eb89b59452755991f310a1f928cf3c6dacbd0d74`.

## Starting observations

The latest recording uses FluidAudio 0.15.7 with attribution v3. Production replay reproduces saved text, timing, canonical identity, and effective identity. MacWhisper's two exports have identical normalized text and speaker assignments; they differ only in grouping. They are machine-generated comparison references, not independently listened-to ground truth.

| Output | Rows | One-word rows |
| --- | ---: | ---: |
| Scribe saved segments | 610 | 301 |
| MacWhisper segments | 534 | 96 |
| Scribe reading paragraphs | 240 | 62 |
| MacWhisper reading paragraphs | 191 | 31 |

Text alignment covers 5,104 tokens, 96.887% of Scribe and 97.053% of the reference. Effective attribution has 76 disagreeing and 112 unknown tokens. This is reference agreement, not independently established accuracy. Forty-one reference rows have zero duration because timestamps are rounded to whole seconds; text alignment is the primary comparison and time alignment is a sensitivity check.

Key hypotheses to test independently:

1. Word reconstruction inserts 203 obvious apostrophe-space forms absent from raw ASR. A scratch apostrophe correction reduced saved single-word segments 301 to 290 and reading rows 240 to 234, with unchanged disagreement count.
2. The embedding minimum also acts as a final diarization-duration floor. Lowering 1.0 s to 0.5 s recovered 90 unknown tokens and produced 197 reading paragraphs / 33 one-word main rows plus two one-word asides. Disagreements rose 76 to 81: 12 new disagreements offset by seven corrections. Separate short output retention from embedding-quality requirements if feasible.
3. 359 of 609 saved boundaries are explained solely by nearest-inference evidence changes. Thirty specifically separate same-speaker inferred words with different distances. The segment schema currently stores a single inference record, so deleting the guard would lose provenance.
4. All words share one enclosing ASR span. Pause-bounded phrases reach 631 words / 188.16 s. Sentence/40-word bounding changed disagreement count 76 to 74 but did not improve paragraph counts.
5. Gap sweeps at 0.1/0.25/0.5/0.75 s produced reading rows 240/234/226/200 and disagreements 76/75/76/78. Equal totals can mask new errors. Merely accepting inferred neighbors or removing overlap boundaries delivered smaller gains and sometimes new disagreements.

These exploratory results are hypotheses and controls to reproduce, not production acceptance thresholds or permission to ship all variants.

## Common experiment contract

Each candidate must be independently selectable in the evaluation harness without exposing experimental controls unnecessarily in the product UI. Preserve a named immutable baseline even as production code changes. Use the actual Swift production path or an explicitly labeled experimental variant, not a silent Python approximation of host behavior.

For every objective report:

- Change, rationale, source/config/model/binary hashes, corpus membership, and exact commands.
- Baseline versus candidate on the same inputs. Hold ASR words fixed for diarization or grouping experiments; regenerate words from identical raw tokens only for word-reconstruction changes. When word units change, compare common normalized lexical tokens and report alignment changes.
- Direct/canonical and effective speaker agreement separately, wrong/unknown counts and rates, alignment coverage, speaker mapping, per-speaker confusion, and transitions including newly wrong tokens versus corrected tokens. Keep mapping consistent when comparing individual changes.
- Saved rows, reading paragraphs, one-word and up-to-three-word rows, asides and their word counts, source-word conservation, and boundary agreement against paragraph references. Paragraph counts alone are not segmentation accuracy. Specify unmatched/ambiguous boundaries and alignment tolerances.
- Runtime and peak memory only under controlled serial runs with hardware, warm/cold state, and repetition policy recorded. Separate model loading, inference, and host processing. Do not claim speed improvements from runs competing with compilation.
- Focused regression tests and a concise accept/reject/needs-more-evidence decision. Retain rejected experiments as reproducible evidence without enabling their behavior by default.

Machine-reference comparisons must be labeled as such. Sparse manually edited subsets are not full-meeting ground truth. Preserve genuine one-word turns. Generate targeted local listening-review cases for changed or uncertain speaker boundaries; leave human annotation fields empty until actually reviewed. Do not optimize for a target row count or report confidence values as calibrated probabilities.

Use separate development and validation recordings. The latest recording and CAB have already informed tuning and are not pristine holdouts; call cross-validation between them a sensitivity check. Seek additional consented recordings or human adjudication for a true final holdout. If unavailable, deliver the measured limitations and retain conservative defaults rather than inventing validation or blocking unrelated implementation.

## Optimization objectives, in order

1. **Freeze baseline and build reusable attribution/boundary diagnostics.** Turn the useful exploratory analysis into reproducible harness capabilities, fixture tests, a corpus manifest, an experiment registry, and a private reviewer pack. Validate baseline reproduction and token/word conservation before experimenting.
2. **Correct word reconstruction.** Implement intraword apostrophe handling; independently assess hyphens and other punctuation. Preserve lexical timing, genuine quote boundaries, and vocabulary behavior. Measure each change and add meaningful tests for contractions, possessives, names, punctuation, and speaker-boundary suffixes.
3. **Retain short diarized speech.** Determine whether output filtering can be decoupled from the minimum reliable embedding duration in the pinned SDK. Prefer a bounded adapter solution or a documented minimal upstream change over an uncontrolled dependency upgrade. Test output floors and existing coupled settings independently, preserving overlap, cluster semantics, and provenance. Keep baseline defaults until the promotion objective.
4. **Separate speaker evidence from readable segment boundaries.** Design and implement the minimal lossless word/range evidence and display grouping change. Decide explicitly whether canonical schema needs migration or presentation grouping suffices; record the tradeoff. Preserve legacy decoding, uncertainty, source IDs, word timing, manual assignments, editing/splitting/undo, search/playback, and export contracts. Do not turn inferred identities into confirmed ones simply by merging text. Quantify saved versus display improvements separately.
5. **Bound phrase context.** Replace accidental whole-recording enclosing-span context with bounded linguistic/acoustic context; compare current, disabled, and bounded phrase attribution while holding other factors fixed. Prevent inappropriate carryover across speaker turns and preserve real interjections.
6. **Evaluate gap and fragment reconciliation independently.** Sweep diarizer gap, neighbor/hole bounds, inferred-neighbor evidence, overlap presentation, and backchannel eligibility as separate hypotheses, not a single permissive preset. Do not propagate inferred labels without independent support. Interactions with short-turn retention are measured later.
7. **Measure interactions and rank effects.** Run baseline, each candidate alone, the selected combination, and leave-one-out ablations of that combination. Use targeted pairwise tests for interacting factors rather than an unbounded combinatorial sweep. Evaluate the corpus and available validation material, review newly disagreeing cases, and rank quality gains, risks, latency/memory, and implementation cost. Distinguish confirmed fixes from candidates needing more evidence.
8. **Promote supported improvements and freeze the optimized baseline.** Enable only justified changes; retain conservative settings where evidence is insufficient. Complete proportionate end-to-end verification of new runs, legacy loading, reprocessing, speaker edits, reading/review views, playback, and exports. Document accepted/rejected configurations and migration behavior. Deliver a reproducible baseline with hashes, corpus manifest, evaluation commands, and known limits for the separate engine comparison mission.

## Separate engine-comparison mission

This mission depends on optimization objective 8. Do not retune Scribe after seeing competitor results without reporting a new experimental round. Its objectives are:

1. **Prepare fair adapters and access.** Inspect available licensed Argmax Pro access, including the installed MacWhisper CLI where appropriate, and document exact SDK/model versions and capabilities. Argmax's open-source SpeakerKit is not SpeakerKit Pro and must never be labeled as a substitute for it. Evaluate at most two additional justified local alternatives against quality, Apple Silicon / 16+ GB RAM, runtime, privacy/offline behavior, license, and maintenance constraints. Use existing access; request missing credentials or explicit purchase approval only when necessary, while completing unaffected work. Do not assume permission to buy a license, distribute models, or upload private audio.
2. **Run controlled component and end-to-end comparisons.** Where APIs expose enough information, hold words fixed and compare diarizers; hold diarization fixed and compare recognition/timing engines; then compare complete pipelines with equivalent grouping. Keep the optimized Scribe baseline and corpus frozen. If a product exposes only final transcripts, report it as end-to-end and do not claim to isolate its diarizer. Report coverage, speaker errors/unknowns, new disagreements, boundaries, timing, word recognition against adjudicated references where available, speed, memory, and cold/warm costs. Run inference serially and retain private review cases.
3. **Recommend the stack and migration decision.** Produce a decision matrix distinguishing measured advantages, tuning effects, model/SDK differences, uncertainty, operational constraints, and commercial cost. Recommend staying with FluidAudio, adopting a component, or further evaluation. Quantify confidence using available independent recordings and human-reviewed cases. Do not implement a production engine migration or purchase services as part of the recommendation objective.

Official background references: https://app.argmaxinc.com/docs/guides/managing-models, https://www.argmaxinc.com/blog/speakerkit, https://docs.macwhisper.com/article/57-macwhisper-command-line-tool. Recheck current APIs and terms at execution time.
