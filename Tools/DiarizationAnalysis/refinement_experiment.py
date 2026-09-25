#!/usr/bin/env python3
"""Evaluate current host refinements against fixed, verified v1 words/intervals.

Builds a private source snapshot; publishes only aggregate quality.py evidence.
No model inference or writes to source recordings or the frozen bundle.
"""
import argparse
import pathlib
import shutil
import subprocess
import sys
from types import SimpleNamespace

from quality import ROOT, compare, digest, read, sha256, verify_bundle, write


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=pathlib.Path, required=True)
    parser.add_argument('--private-output', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    args = parser.parse_args()
    lock = ROOT / 'docs/investigations/transcript-quality-baseline-v1.json'
    manifest = verify_bundle(args.bundle, lock)
    private = args.private_output.resolve()
    if private.is_relative_to(ROOT) or private.is_relative_to(args.bundle.resolve()):
        raise ValueError('Private output must be outside source and baseline')
    if args.output.resolve().is_relative_to(args.bundle.resolve()):
        raise ValueError('Never overwrite the frozen baseline')
    private.mkdir(parents=True, exist_ok=False, mode=0o700)
    source = private / 'source'
    for name in manifest['source_hashes']:
        dest = source / name
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / name, dest)
    # Include this recipe even though it postdates the frozen manifest.
    shutil.copy2(__file__, source / 'Tools/DiarizationAnalysis/refinement_experiment.py')
    binary = private / 'host-replay'
    base = args.bundle / manifest['corpus']['recordings'][0]['id']
    subprocess.run([sys.executable, str(source / 'Tools/DiarizationAnalysis/replay.py'),
                    str(base), 'saved', str(base / 'diarization.json'),
                    '--output', str(private / 'build-replay.json'),
                    '--keep-executable', str(binary)], check=True)
    config = private / 'config.json'
    write(config, dict(id='bounded-gap-and-inferred-grouping-v1', baseline=manifest['name'],
                       word_input='saved', host_replay=str(binary), binary_sha256=sha256(binary),
                       source_root=str(source),
                       source_tree_sha256=digest({n: sha256(source / n) for n in manifest['source_hashes']})))
    compare(SimpleNamespace(bundle=args.bundle, lock=lock, config=config,
                            private_output=private / 'comparison', output=args.output))
    report = read(args.output)
    for key in report['recordings']:
        before = read(args.bundle / key / 'replay.json')
        after = read(private / 'comparison' / (key + '.json'))
        if before['labels'] != after['labels'] or before['words'] != after['words']:
            raise ValueError('Canonical word attribution/text/timing changed: ' + key)
        result = report['recordings'][key]
        if result['change']['effective']['newly_wrong']:
            raise ValueError('New lexical speaker disagreements: ' + key)
        result['canonical_word_labels_identical'] = True
    report['recipe_sha256'] = sha256(__file__)
    report['validation'] = 'Two previously explored development recordings; machine references, no human adjudication or holdout.'
    write(args.output, report)
    print('Words, timing and canonical labels preserved; no new lexical speaker disagreements.')


if __name__ == '__main__':
    main()
