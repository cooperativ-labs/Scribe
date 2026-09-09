#!/usr/bin/env python3
"""Aggregate benchmark.py outputs and verify Python replay against actual Swift.

--private-output holds raw host replays; --output is transcript-free aggregate JSON.
All engines share one fixed ASR stream per recording. Held-out inputs without a
reference produce diagnostics only, never an inferred accuracy score.
"""
import argparse
import collections
import difflib
import itertools
import json
import math
import pathlib
import statistics
import subprocess

from benchmark import sha
from compare import assign, lexical, segments, legacy_sentence_segments


def group_metrics(groups):
    counts = [g['count'] for g in groups]
    return dict(segments=len(groups), single_word_segments=counts.count(1),
                median_words=statistics.median(counts) if counts else None)


def proxy(words, labels, reference):
    ids = {name: f'reference_{i+1}' for i, name in enumerate(dict.fromkeys(s['speaker'] for s in reference))}
    ref = [(token, ids[s['speaker']]) for s in reference for token in lexical(s['text'])]
    hyp = [(token, i) for i, word in enumerate(words) for token in lexical(word['text'])]
    matcher = difflib.SequenceMatcher(None, [x[0] for x in hyp], [x[0] for x in ref], autojunk=False)
    pairs = [(i+k, j+k) for i, j, n in matcher.get_matching_blocks() for k in range(n)]
    counts = collections.Counter((labels[hyp[i][1]], ref[j][1]) for i, j in pairs)
    speakers = sorted(set(labels)-{None})
    mappings = [dict(zip(speakers, perm)) for perm in itertools.permutations(
        list(ids.values()) + [None]*max(0, len(speakers)-len(ids)), len(speakers))]
    good = max((sum(n for (s, r), n in counts.items() if s is not None and m.get(s) == r)
                for m in mappings), default=0)
    unknown = sum(n for (s, r), n in counts.items() if s is None)
    matched = len(pairs)
    return dict(metric='exact-matched-text reference agreement proxy, not DER/WDER or human ground truth',
                matched_tokens=matched, hypothesis_tokens=len(hyp), reference_tokens=len(ref),
                unmatched_hypothesis_tokens=len(hyp)-matched, unmatched_reference_tokens=len(ref)-matched,
                words_without_matched_tokens=len(words)-len({hyp[i][1] for i, _ in pairs}),
                hypothesis_coverage_pct=round(100*matched/len(hyp), 3),
                reference_coverage_pct=round(100*matched/len(ref), 3),
                agreement_pct=round(100*good/matched, 3), unknown_pct=round(100*unknown/matched, 3),
                wrong_speaker_pct=round(100*(matched-good-unknown)/matched, 3),
                matched_correct=good, matched_unknown=unknown, matched_wrong=matched-good-unknown)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--meetings', type=pathlib.Path, required=True)
    p.add_argument('--results', type=pathlib.Path, required=True)
    p.add_argument('--host-replay', type=pathlib.Path, required=True)
    p.add_argument('--reference-run', required=True, help='Run UUID with the text-only reference')
    p.add_argument('--reference', type=pathlib.Path, required=True)
    p.add_argument('--transcript', type=pathlib.Path, required=True, help='Fixed fresh ASR for reference run')
    p.add_argument('--private-output', type=pathlib.Path, required=True)
    p.add_argument('--output', type=pathlib.Path, required=True)
    a = p.parse_args()
    a.private_output.mkdir(parents=True, exist_ok=True)
    reference = json.loads(a.reference.read_text())
    output = dict(schema_version=1, reference_sha256=sha(a.reference),
                  asr_transcript_sha256=sha(a.transcript),
                  human_audio_annotation=False, held_out_accuracy_coverage=0, runs=[])
    for run in sorted(a.meetings.glob('*/runs/*')):
        if not (run/'words.json').exists():
            continue
        is_reference = run.name == a.reference_run
        canonical = json.loads((run/'canonical-transcript.json').read_text())
        for engine, mode in itertools.product(['fluid', 'speakerkit'], ['automatic', 'exact-two']):
            key = f'{run.parent.parent.name}-{engine}-{mode}'
            path = a.results / f'{key}.json'
            diar = json.loads(path.read_text())
            if diar['benchmark']['exit_code']:
                raise ValueError(f'Failed benchmark: {key}')
            private = a.private_output / f'{key}.replay.json'
            with private.open('w') as stream:
                subprocess.run([str(a.host_replay), str(run), str(a.transcript) if is_reference else '--saved-words',
                                str(path)], stdout=stream, check=True)
            replay = json.loads(private.read_text())
            words, labels = replay['words'], replay['labels']
            python_labels = assign(words, diar['intervals'])
            stable_ids = {}
            for interval in sorted(diar['intervals'], key=lambda t: (math.floor(t['startSeconds']*1000+.5), math.floor(t['endSeconds']*1000+.5))):
                stable_ids.setdefault(interval['speakerID'], f'speaker_{len(stable_ids)+1}')
            python_labels = [stable_ids.get(label) for label in python_labels]
            if labels != python_labels:
                raise AssertionError(f'Python attribution differs from actual Swift: {key}')
            groups = segments(words, labels)
            swift_groups = replay['segments']
            if [g['count'] for g in groups] != [len(s.get('words', [])) for s in swift_groups]:
                raise AssertionError(f'Python grouping differs from actual Swift: {key}')
            occupancy = collections.defaultdict(float)
            for interval in diar['intervals']:
                occupancy[interval['speakerID']] += interval['endSeconds']-interval['startSeconds']
            bench = diar['benchmark']
            row = dict(recording=run.parent.parent.name, reference_available=is_reference,
                       source_duration_seconds=canonical['source']['duration_ms']/1000,
                       source_canonical_revision=canonical['revision'], source_canonical_sha256=sha(run/'canonical-transcript.json'),
                       audio_sha256=bench['audio_sha256'], engine=engine, mode=mode,
                       revision=bench['revision'], binary_sha256=bench['binary_sha256'],
                       process_wall_seconds=round(bench['process_wall_seconds'], 3),
                       asr='fresh FluidAudio 0.15.6 fixed across engines' if is_reference else 'saved words fixed across engines; historical duration limitations',
                       words=len(words), unknown_words=labels.count(None),
                       unknown_word_pct=round(100*labels.count(None)/len(words), 3),
                       paragraphs=group_metrics(groups),
                       known_paragraphs=group_metrics([g for g in groups if g['label'] is not None]),
                       unknown_paragraphs=group_metrics([g for g in groups if g['label'] is None]),
                       legacy_sentence_rows=group_metrics(legacy_sentence_segments(words, labels)),
                       emitted_speakers=len(occupancy), intervals=len(diar['intervals']),
                       interval_seconds_by_speaker={k:round(v, 3) for k,v in occupancy.items()},
                       dominant_interval_fraction=round(max(occupancy.values())/sum(occupancy.values()), 6) if occupancy else None,
                       overlap_intervals=sum(i.get('overlapsAnotherSpeaker', False) for i in diar['intervals']),
                       actual_swift_parity=True)
            for field in ['engine','configuration','clusteringDiagnostics']:
                if field in diar:
                    row['worker_'+field] = diar[field]
            if is_reference:
                row['proxy'] = proxy(words, labels, reference)
                row['timing'] = dict(first_word_ms=words[0]['startMs'], last_word_end_ms=words[-1]['endMs'],
                    longest_word_ms=max(w['endMs']-w['startMs'] for w in words),
                    words_over_one_second=sum(w['endMs']-w['startMs']>1000 for w in words),
                    adjacent_gaps_at_least_one_second=sum(y['startMs']-x['endMs']>=1000 for x,y in zip(words,words[1:])))
            output['runs'].append(row)
            print(key, row.get('proxy', {}).get('agreement_pct'), row['paragraphs'], flush=True)
    a.output.write_text(json.dumps(output, indent=2)+'\n')


if __name__ == '__main__':
    main()
