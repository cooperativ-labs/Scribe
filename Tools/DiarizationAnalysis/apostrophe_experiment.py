#!/usr/bin/env python3
"""Build and evaluate the isolated, default-off apostrophe candidate. No inference.

All transcript-bearing artifacts and source snapshots go to a new private directory.
The public report contains only aggregate measurements and provenance hashes.
"""
import argparse
import pathlib
import re
import shutil
import subprocess
import sys
from types import SimpleNamespace

from quality import ROOT, compare, digest, read, sha256, verify_bundle, write


def reconstruction_evidence(before, after, raw_text):
    """Require exact character conservation, then check merged lexical timing spans."""
    compact = lambda value: re.sub(r'\s+', '', value)
    assert compact(''.join(w['text'] for w in before)) == compact(''.join(w['text'] for w in after))
    cursor = 0
    merged = unchanged = 0
    for word in after:
        group = []
        text = ''
        while len(text) < len(compact(word['text'])):
            old = before[cursor]
            cursor += 1
            group.append(old)
            text += compact(old['text'])
        assert text == compact(word['text'])
        assert word.get('startMs') == group[0].get('startMs')
        ends = [w.get('endMs') for w in group]
        assert word.get('endMs') == (max(ends) if all(e is not None for e in ends) else None)
        merged += len(group) > 1
        unchanged += len(group) == 1
    assert cursor == len(before)
    malformed = lambda text: len(re.findall(r"\w['’]\s+\w", text))
    suffix_forms = lambda text: len(re.findall(r"\w'\s+(?:s|t|m|re|ve|ll|d)\b", text))
    return dict(split_common_suffix_forms_before=suffix_forms(' '.join(w['text'] for w in before)),
                split_common_suffix_forms_after=suffix_forms(' '.join(w['text'] for w in after)),
                nonwhitespace_characters_equal=True, merged_word_timing_spans_equal=True,
                merged_words=merged, unchanged_words=unchanged,
                apostrophe_space_forms_before=malformed(' '.join(w['text'] for w in before)),
                apostrophe_space_forms_after=malformed(' '.join(w['text'] for w in after)),
                apostrophe_space_forms_raw_asr=malformed(raw_text))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=pathlib.Path, required=True)
    parser.add_argument('--private-output', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    args = parser.parse_args()
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
        dest = source/name
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT/name, dest)
    binary = private/'host-replay'
    base = args.bundle/'latest'
    subprocess.run([sys.executable, str(source/'Tools/DiarizationAnalysis/replay.py'), str(base),
                    str(base/'transcript.json'), str(base/'diarization.json'),
                    '--output', str(private/'build-control.json'), '--keep-executable', str(binary)], check=True)
    provenance = dict(host_replay=str(binary), binary_sha256=sha256(binary), source_root=str(source),
                      source_tree_sha256=digest({p: sha256(source/p) for p in manifest['source_hashes']}))
    reports = {}
    for name, enabled in [('current-host-raw-control', False), ('intraword-apostrophes-v1', True)]:
        config = dict(id=name, baseline=manifest['name'], word_input='raw',
                      intraword_apostrophes=enabled, **provenance)
        config_path = private/(name+'-config.json')
        write(config_path, config)
        output = private/(name+'-aggregate.json')
        compare(SimpleNamespace(bundle=args.bundle, lock=lock, config=config_path,
                                private_output=private/name, output=output))
        reports[name] = read(output)
    candidate = reports['intraword-apostrophes-v1']
    for key in candidate['recordings']:
        before = read(args.bundle/key/'replay.json')['words']
        after = read(private/'intraword-apostrophes-v1'/(key+'.json'))['words']
        raw = read(args.bundle/key/'transcript.json')
        candidate['recordings'][key]['reconstruction'] = reconstruction_evidence(before, after, raw['text'])
        control = reports['current-host-raw-control']['recordings'][key]
        assert control['word_comparison']['saved_word_objects_equal']
        # Full semantic replay equivalence (including canonical/effective labels,
        # timing, inference evidence, rows and asides), not merely equal totals.
        assert read(args.bundle/key/'replay.json') == read(private/'current-host-raw-control'/(key+'.json'))
    write(args.output, dict(experiment='intraword-apostrophes-v1', production_default=False,
                           corpus=manifest['corpus'], models=manifest['models'],
                           validation='Explored development/sensitivity recordings only; no human adjudication',
                           reports=reports, recipe_sha256=sha256(__file__),
                           tests_sha256=sha256(ROOT/'Modules/Transcription/Tests/TranscriptionTests/TokenTimingReconcilerTests.swift')))
    print('Control exactly reproduces frozen replay; candidate conserves characters and lexical timing spans.')


if __name__ == '__main__':
    main()
