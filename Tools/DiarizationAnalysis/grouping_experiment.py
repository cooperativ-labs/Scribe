#!/usr/bin/env python3
"""Independent sentence/turn presentation experiment; fixed canonical sources."""
import argparse
import collections
import pathlib
import shutil
import subprocess
import sys
from types import SimpleNamespace
from quality import ROOT, compare, digest, read, sha256, verify_bundle, write, rows_metrics, boundary_causes


def evidence_conservation(before, after):
    for field in ('words', 'segments', 'reconciled_segments', 'labels', 'effective_labels'):
        if before[field] != after[field]:
            raise ValueError('Presentation changed canonical semantics: ' + field)
    sources = {s['id']: s for s in before['reconciled_segments']}
    rows = after['display_paragraphs'] + after['display_asides']
    evidence = after['display_attribution_ranges']
    if len(rows) != len(evidence):
        raise ValueError('Missing evidence rows')
    seen = []
    for row, entry in zip(rows, evidence):
        if row['source_segment_ids'] != entry['source_segment_ids']:
            raise ValueError('Evidence row order mismatch')
        if [r['source']['id'] for r in entry['ranges']] != row['source_segment_ids']:
            raise ValueError('Evidence source order mismatch')
        cursor = 0
        for item in entry['ranges']:
            source = item['source']; seen.append(source['id'])
            if source != sources[source['id']]:
                raise ValueError('Lost source evidence')
            words = source.get('words', [])
            if words:
                if (item['word_start'], item['word_end']) != (cursor, cursor + len(words)):
                    raise ValueError('Invalid word range')
                if row['words'][cursor:cursor + len(words)] != words:
                    raise ValueError('Changed range word timing/content')
                cursor += len(words)
            elif item['word_start'] is not None or item['word_end'] is not None:
                raise ValueError('Invented word timing')
        if cursor != len(row['words']):
            raise ValueError('Incomplete evidence coverage')
    if collections.Counter(seen) != collections.Counter(sources.keys()):
        raise ValueError('Missing/duplicated source evidence')
    def row_owners(replay):
        return {source: i for i, row in enumerate(replay['display_paragraphs'] + replay['display_asides'])
                for source in row['source_segment_ids']}
    baseline_owners, candidate_owners = row_owners(before), row_owners(after)
    nearest_only = [(a['id'], b['id']) for a, b in zip(before['segments'], before['segments'][1:])
                    if boundary_causes(dict(segments=[a,b]))['combinations'] == {'nearest_evidence_change': 1}]
    return dict(nearest_only_saved_boundaries=len(nearest_only),
                nearest_only_joined_in_reading=sum(baseline_owners[a] == baseline_owners[b] for a,b in nearest_only),
                nearest_only_joined_in_sentence_turns=sum(candidate_owners[a] == candidate_owners[b] for a,b in nearest_only),
                canonical_and_reconciled_segments_identical=True, labels_identical=True,
                evidence_snapshots_exact=True, word_ranges_exact=True,
                source_ranges=len(seen), saved=rows_metrics(before['segments']),
                reading_baseline=rows_metrics(before['display_paragraphs']),
                sentence_turns=rows_metrics(after['display_paragraphs']))


def boundary_review(before, after, audio):
    old = {r['source_segment_ids'][0] for r in before['display_paragraphs']}
    new = {r['source_segment_ids'][0] for r in after['display_paragraphs']}
    changed = old ^ new
    sources = before['reconciled_segments']
    return dict(annotation_status='not reviewed', audio_path=audio, cases=[dict(
        source_segment_id=s['id'], change='added' if s['id'] in new else 'removed',
        clip_start_ms=max(0, s['start_ms']-2000), clip_end_ms=s['end_ms']+2000,
        context=sources[max(0, i-1):i+2], human_boundary=None, human_speaker=None,
        reviewer=None, notes=None) for i, s in enumerate(sources) if s['id'] in changed])


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--bundle', type=pathlib.Path, required=True)
    p.add_argument('--private-output', type=pathlib.Path, required=True)
    p.add_argument('--output', type=pathlib.Path, required=True)
    args = p.parse_args()
    lock = ROOT/'docs/investigations/transcript-quality-baseline-v1.json'
    manifest = verify_bundle(args.bundle, lock)
    private = args.private_output.resolve()
    if private.is_relative_to(ROOT) or private.is_relative_to(args.bundle.resolve()):
        raise ValueError('Private output must be outside source and baseline')
    if args.output.resolve().is_relative_to(args.bundle.resolve()):
        raise ValueError('Never overwrite baseline artifacts')
    private.mkdir(parents=True, exist_ok=False, mode=0o700)
    source = private/'source'
    for name in manifest['source_hashes']:
        dest = source/name; dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT/name, dest)
    binary = private/'host-replay'; base = args.bundle/'latest'
    subprocess.run([sys.executable, str(source/'Tools/DiarizationAnalysis/replay.py'), str(base),
                    'saved', str(base/'diarization.json'), '--output', str(private/'build-control.json'),
                    '--keep-executable', str(binary)], check=True)
    provenance = dict(host_replay=str(binary), binary_sha256=sha256(binary), source_root=str(source),
                      source_tree_sha256=digest({p: sha256(source/p) for p in manifest['source_hashes']}))
    reports = {}
    for name, enabled in [('current-host-grouping-control', False), ('sentence-turns-v1', True)]:
        config_path = private/(name+'-config.json')
        write(config_path, dict(id=name, baseline=manifest['name'], word_input='saved',
                               sentence_turns=enabled, **provenance))
        output = private/(name+'-aggregate.json')
        compare(SimpleNamespace(bundle=args.bundle, lock=lock, config=config_path,
                                private_output=private/name, output=output))
        reports[name] = read(output)
    for entry in manifest['corpus']['recordings']:
        key = entry['id']; before = read(args.bundle/key/'replay.json')
        if before != read(private/'current-host-grouping-control'/(key+'.json')):
            raise ValueError('Off control differs from immutable baseline')
        after = read(private/'sentence-turns-v1'/(key+'.json'))
        result = reports['sentence-turns-v1']['recordings'][key]
        result['presentation_evidence'] = evidence_conservation(before, after)
        review = boundary_review(before, after, entry['run']+'/prepared.wav')
        write(private/'sentence-turns-v1'/(key+'-boundary-review.json'), review)
        result['changed_reading_boundaries'] = len(review['cases'])
    extra_sources = ['Tools/DiarizationAnalysis/grouping_experiment.py', 'Tools/DiarizationAnalysis/test_grouping_experiment.py',
                     'Modules/Transcription/Tests/TranscriptionTests/TranscriptAttributionRangeTests.swift']
    for name in extra_sources:
        dest = source/name; dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT/name, dest)
    write(args.output, dict(additional_source_hashes={name: sha256(source/name) for name in extra_sources}, experiment='sentence-turns-v1', production_default=False,
                           corpus=manifest['corpus'], models=manifest['models'], reports=reports,
                           validation='Explored development/sensitivity only; no human adjudication',
                           recipe_sha256=sha256(__file__)))
    print('Control matches frozen replay; canonical semantics and range evidence conserved.')


if __name__ == '__main__':
    main()
