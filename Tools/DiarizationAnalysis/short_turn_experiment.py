#!/usr/bin/env python3
"""Serial, pinned short-turn inference and frozen-host comparison. No ASR inference."""
import argparse
import collections
import pathlib
import platform
import shutil
import subprocess
from types import SimpleNamespace

from quality import ROOT, compare, digest, read, sha256, verify_bundle, write
from wder import optimal_mapping

REVISION = '41540ea237350afe5117a082b5c28eda642d0612'


def interval_correspondence(candidate, baseline):
    """Cluster correspondence from shared acoustic time, never reference labels."""
    counts = collections.Counter()
    for a in candidate:
        for b in baseline:
            counts[a['speakerID'], b['speakerID']] += max(0, min(a['endSeconds'], b['endSeconds']) - max(a['startSeconds'], b['startSeconds']))
    mapping = optimal_mapping(counts, sorted({a['speakerID'] for a in candidate}), sorted({b['speakerID'] for b in baseline}))
    evidence = {a: dict(target=b, shared_seconds=counts[a, b],
                        other_max_seconds=max((v for (x,y),v in counts.items() if x == a and y != b), default=0))
                for a,b in mapping.items()}
    return mapping, evidence


def acoustic_correspondence(candidate, control):
    counts = collections.Counter()
    for a in candidate:
        for b in control:
            counts[a['speakerID'], b['speakerID']] = sum(x*y for x,y in zip(a['vector'], b['vector'], strict=True))
    mapping = optimal_mapping(counts, sorted(a['speakerID'] for a in candidate), sorted(b['speakerID'] for b in control))
    evidence = {a: dict(target=b, cosine=counts[a,b],
                        runner_up=max((v for (x,y),v in counts.items() if x == a and y != b), default=0))
                for a,b in mapping.items()}
    return mapping, evidence


def interval_evidence(variant, control):
    raw_ids = variant['rawClusterIDsByStableID']
    signature = lambda i, ids: (ids[i['speakerID']], i['startSeconds'], i['endSeconds'], i['qualityScore'])
    old = {signature(i, control['rawClusterIDsByStableID']) for i in control['result']['intervals']}
    new = {signature(i, raw_ids) for i in variant['result']['intervals']}
    added = [i for i in variant['result']['intervals'] if signature(i, raw_ids) not in old]
    return dict(intervals=len(new), added_intervals=len(new-old), removed_intervals=len(old-new),
                added_seconds=sum(i['endSeconds']-i['startSeconds'] for i in added),
                overlap_intervals=sum(i['overlapsAnotherSpeaker'] for i in variant['result']['intervals']),
                added_overlap_intervals=sum(i['overlapsAnotherSpeaker'] for i in added),
                chunk_evidence_sha256=digest(variant['chunkEmbeddings']),
                chunk_count=len(variant['chunkEmbeddings']),
                same_chunk_embeddings_and_assignments=variant['chunkEmbeddings']==control['chunkEmbeddings'])


def verify_experiment(private, bundle):
    """Post-run semantic controls and focused review inventory; no inference."""
    evidence = {}
    for key in ['latest', 'cab']:
        control = read(private/(key+'-inference')/'embedding-1.0-output-1.0.json')
        baseline = read(bundle/key/'diarization.json')
        assert control['result']['intervals'] == baseline['intervals']
        assert read(private/'embedding-1.0-output-1.0'/(key+'.json')) == read(bundle/key/'replay.json')
        isolated = read(private/(key+'-inference')/'embedding-1.0-output-0.5.json')
        coupled = read(private/(key+'-inference')/'embedding-0.5-output-0.5.json')
        equal_chunks = isolated['chunkEmbeddings'] == coupled['chunkEmbeddings']
        equal_intervals = isolated['result']['intervals'] == coupled['result']['intervals']
        cases = read(private/'embedding-1.0-output-0.5'/(key+'-review.json'))['cases']
        focused = [c for c in cases if c['changed']]
        write(private/(key+'-short-turn-regressions.json'), dict(
            description='Real changed assignments at output 0.5 s; text/timing evidence only, not human adjudication',
            cases=focused))
        evidence[key] = dict(fresh_baseline_intervals_equal=True, fresh_baseline_full_replay_equal=True,
            coupled_and_output_only_chunk_evidence_equal=equal_chunks,
            coupled_and_output_only_intervals_equal=equal_intervals,
            changed_assignment_cases=len(focused),
            effective_newly_wrong_from_correct=sum(c['view']=='effective' and c['baseline_state']=='correct' and c['candidate_state']=='wrong' for c in focused),
            effective_newly_wrong_from_unknown=sum(c['view']=='effective' and c['baseline_state']=='unknown' and c['candidate_state']=='wrong' for c in focused),
            private_regression_pack_sha256=sha256(private/(key+'-short-turn-regressions.json')))
    return evidence


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=pathlib.Path, required=True)
    parser.add_argument('--private-output', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--models', type=pathlib.Path, required=True)
    args = parser.parse_args()
    lock = ROOT/'docs/investigations/transcript-quality-baseline-v1.json'
    manifest = verify_bundle(args.bundle, lock)
    private = args.private_output.resolve()
    if private.is_relative_to(ROOT) or private.is_relative_to(args.bundle.resolve()):
        raise ValueError('Private output must be outside source and baseline')
    if args.output.resolve().is_relative_to(args.bundle.resolve()):
        raise ValueError('Never overwrite baseline')
    private.mkdir(parents=True, exist_ok=False, mode=0o700)
    models = {str(p.relative_to(args.models)): sha256(p) for p in sorted(args.models.rglob('*')) if p.is_file()}
    assert digest(models) == manifest['models']['tree_sha256'], 'Model assets changed since baseline'
    write(private/'model-hashes.json', models)
    # Snapshot all source packages necessary to reproduce the worker build.
    source = private/'source'
    sources = {}
    for folder in ['Workers/TranscriptionWorker', 'Modules/Speakers']:
        for p in (ROOT/folder).rglob('*'):
            if not p.is_file() or any(part.startswith('.') for part in p.relative_to(ROOT/folder).parts):
                continue
            if p.suffix not in ('.swift', '.json', '.resolved'): continue
            rel = p.relative_to(ROOT)
            dest = source/rel; dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(p, dest); sources[str(rel)] = sha256(dest)
    # Model manifest and analysis recipe are retained with the worker snapshot.
    for p in pathlib.Path(__file__).parent.glob('*.py'):
        rel = p.relative_to(ROOT); dest = source/rel; dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(p, dest); sources[str(rel)] = sha256(dest)
    build = private/'build'
    with (private/'build.log').open('w') as log:
        subprocess.run(['swift','build','--package-path',str(source/'Workers/TranscriptionWorker'),
                        '--scratch-path',str(build),'--build-system','swiftbuild','-c','release',
                        '--product','ShortTurnBenchmark'], stdout=log, stderr=subprocess.STDOUT, check=True)
    binary = build/'out/Products/Release/ShortTurnBenchmark'
    sdk = build/'checkouts/FluidAudio'
    revision = subprocess.check_output(['git','rev-parse','HEAD'], cwd=sdk, text=True).strip()
    assert revision == REVISION
    assert not subprocess.check_output(['git','status','--porcelain'], cwd=sdk, text=True).strip()
    sdk_sources = {str(p.relative_to(sdk)): sha256(p) for p in (sdk/'Sources').rglob('*') if p.is_file()}
    provenance = dict(worker_binary_sha256=sha256(binary), source_hashes=sources,
                      source_tree_sha256=digest(sources), sdk_revision=revision,
                      sdk_source_tree_sha256=digest(sdk_sources), models=manifest['models'],
                      toolchain=subprocess.check_output(['swift','--version'],text=True).strip(),
                      platform=platform.platform(), hardware=subprocess.check_output(['sysctl','-n','hw.model'],text=True).strip(),
                      timing_policy='Serial inference; two preparations per recording. One run, uncontrolled warm caches; no speed or memory improvement claimed.')
    write(private/'provenance.json', provenance)
    variants_by_recording = {}
    preserved_inputs = {}
    for entry in manifest['corpus']['recordings']:
        key = entry['id']; run = pathlib.Path(entry['run'])
        preserved_inputs[key] = {str(p): sha256(p) for p in run.iterdir() if p.is_file()}
        assert sha256(run/'prepared.wav') == manifest['recordings'][key]['inputs']['prepared.wav']
        for role, p in entry['references'].items():
            assert sha256(ROOT/p) == entry['reference_sha256'][role]
        with (private/(key+'-inference.log')).open('w') as log:
            subprocess.run([str(binary),str(run/'prepared.wav'),str(source/'Workers/TranscriptionWorker/model_manifest.json'),
                            str(args.models),str(private/(key+'-inference'))], stdout=log, stderr=subprocess.STDOUT, check=True)
        variants_by_recording[key] = {p.stem:read(p) for p in (private/(key+'-inference')).glob('*.json')}
    reports = {}
    for name in sorted(next(iter(variants_by_recording.values()))):
        recordings = {}; evidence = {}
        for key, variants in variants_by_recording.items():
            variant = variants[name]; control = variants['embedding-1.0-output-1.0']
            baseline = read(args.bundle/key/'diarization.json')
            control_map, control_evidence = interval_correspondence(control['result']['intervals'], baseline['intervals'])
            raw_to_baseline = {control['rawClusterIDsByStableID'][a]:b for a,b in control_map.items()}
            if variant['preparationEmbeddingFloorSeconds'] == 1:
                mapping = {a:raw_to_baseline.get(raw, 'unmatched_'+raw) for a,raw in variant['rawClusterIDsByStableID'].items()}
                acoustic = None
            else:
                coupled_map, acoustic = acoustic_correspondence(variant['result']['embeddings'], control['result']['embeddings'])
                mapping = {a:control_map.get(b, 'unmatched_'+b) for a,b in coupled_map.items()}
            path = private/(key+'-'+name+'-diarization.json')
            write(path, variant['result'])
            recordings[key] = dict(diarization=str(path), diarization_sha256=sha256(path), speaker_correspondence=mapping)
            evidence[key] = dict(**interval_evidence(variant, control), control_to_baseline=control_evidence,
                                 coupled_acoustic_correspondence=acoustic,
                                 preparation_embedding_floor_seconds=variant['preparationEmbeddingFloorSeconds'],
                                 output_floor_seconds=variant['outputFloorSeconds'],
                                 applied_preparation_configuration=variant['result']['configuration'],
                                 worker_artifact_sha256=sha256(private/(key+'-inference')/(name+'.json')))
            if variant['preparationEmbeddingFloorSeconds'] == 1:
                assert evidence[key]['same_chunk_embeddings_and_assignments']
                assert evidence[key]['removed_intervals'] == 0
        config = dict(id=name, baseline=manifest['name'], word_input='saved', recordings=recordings)
        config_path = private/(name+'-config.json'); write(config_path, config)
        aggregate = private/(name+'-aggregate.json')
        compare(SimpleNamespace(bundle=args.bundle, lock=lock, config=config_path, private_output=private/name, output=aggregate))
        reports[name] = read(aggregate)
        for key, values in evidence.items(): reports[name]['recordings'][key]['short_turn_evidence'] = values
    for inputs in preserved_inputs.values():
        assert all(sha256(p) == h for p,h in inputs.items()), 'Original run changed'
    verify_bundle(args.bundle, lock)
    write(args.output, dict(experiment='short-turn-retention-v1', production_default_changed=False,
                            corpus=manifest['corpus'], provenance=provenance, reports=reports,
                            semantic_verification=verify_experiment(private, args.bundle),
                            original_run_hashes_unchanged=True, baseline_verified=True,
                            human_review='Not adjudicated; private review packs require listening. Machine-reference agreement only.'))


if __name__ == '__main__':
    main()
