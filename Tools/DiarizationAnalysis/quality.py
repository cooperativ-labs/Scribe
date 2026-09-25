#!/usr/bin/env python3
"""Controlled, local saved-artifact experiments. Public output is aggregate-only."""
import argparse
import collections
import difflib
import json
import pathlib
import platform
import shutil
import subprocess
import sys

from wder import lexical, optimal_mapping, sha256, parse_json_reference, timed_pairs

ROOT = pathlib.Path(__file__).resolve().parents[2]
BASELINE = 'scribe-quality-v1'


def read(path):
    return json.loads(pathlib.Path(path).read_text())


def write(path, value):
    pathlib.Path(path).write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def digest(value):
    import hashlib
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def reference(path):
    # Retain unlabelled rows in lexical alignment and boundary diagnostics.
    # Their tokens are explicitly unscoreable for attribution.
    result = []
    for raw in read(path):
        missing = raw.get('speaker') is None
        row = parse_json_reference([{**raw, 'speaker': '__unlabelled__' if missing else raw['speaker']}])[0]
        if missing:
            row['speaker'] = None
        result.append(row)
    ids = {s: f'reference_{i+1}' for i, s in enumerate(dict.fromkeys(r['speaker'] for r in result if r['speaker'] is not None))}
    return [{**r, 'speaker': ids.get(r['speaker'])} for r in result]


def tokens(rows):
    return [(token, i) for i, row in enumerate(rows) for token in lexical(row['text'])]


def align(a, b):
    return [(i+k, j+k) for i, j, n in difflib.SequenceMatcher(None, [x[0] for x in a], [x[0] for x in b], autojunk=False).get_matching_blocks() for k in range(n)]


def mapping_for(replay, refs, pairs):
    hyp, ref = tokens(replay['words']), tokens(refs)
    counts = collections.Counter((replay['effective_labels'][hyp[i][1]], refs[ref[j][1]]['speaker']) for i, j in pairs)
    speakers = sorted({s for s in replay['labels'] + replay['effective_labels'] if s is not None})
    target = sorted({r['speaker'] for r in refs if r['speaker'] is not None})
    return optimal_mapping(counts, speakers, target)


def classify(label, target, mapping):
    if target is None:
        return 'unscoreable'
    if label is None:
        return 'unknown'
    return 'correct' if mapping.get(label) == target else 'wrong'


def score(replay, refs, pairs, mapping, view):
    hyp, ref = tokens(replay['words']), tokens(refs)
    labels = replay['labels' if view == 'canonical' else 'effective_labels']
    states = {j: classify(labels[hyp[i][1]], refs[ref[j][1]]['speaker'], mapping) for i, j in pairs}
    counts = collections.Counter(states.values())
    total = len(states) - counts['unscoreable']
    confusion = collections.Counter((labels[hyp[i][1]] or 'unknown', refs[ref[j][1]]['speaker']) for i, j in pairs if refs[ref[j][1]]['speaker'] is not None)
    return dict(scored_tokens=total, **{k: counts[k] for k in ('correct', 'wrong', 'unknown', 'unscoreable')},
                **{k+'_pct': round(100*counts[k]/total, 4) if total else None for k in ('wrong', 'unknown')},
                confusion=[dict(hypothesis=h, reference=r, count=n) for (h, r), n in sorted(confusion.items())]), states


def rows_metrics(rows):
    sizes = [r.get('word_count', len(r.get('words', []))) for r in rows]
    return dict(rows=len(rows), one_word=sizes.count(1), up_to_three_words=sum(0 < x <= 3 for x in sizes), words=sum(sizes))


def conservation(replay):
    original = collections.Counter(w['id'] for w in replay['words'])
    word_key = lambda w: (w['text'], w.get('start_ms', w.get('startMs')), w.get('end_ms', w.get('endMs')))
    saved = collections.Counter(word_key(w) for s in replay['segments'] for w in s.get('words', []))
    original_content = collections.Counter(word_key(w) for w in replay['words'])
    display = collections.Counter(i for r in replay['display_paragraphs'] + replay['display_asides'] for i in r['word_ids'])
    ids = collections.Counter(s['id'] for s in replay['segments'])
    grouped = collections.Counter(i for r in replay['display_paragraphs'] + replay['display_asides'] for i in r['source_segment_ids'])
    display_content = collections.Counter(word_key(w) for row in replay['display_paragraphs'] + replay['display_asides'] for w in row['words'])
    result = dict(saved_words_equal=original_content == saved, display_content_equal=original_content == display_content, main_plus_aside_words_equal=original == display,
                  source_segments_equal=ids == grouped, unique_input_word_ids=all(n == 1 for n in original.values()),
                  missing_display_words=sum((original-display).values()), duplicated_display_words=sum((display-original).values()))
    if not all(result[k] for k in ('saved_words_equal', 'display_content_equal', 'main_plus_aside_words_equal', 'source_segments_equal', 'unique_input_word_ids')):
        raise ValueError('Word/aside conservation failed: '+str(result))
    return result


def boundary_metrics(replay, refs, pairs, tolerance=0):
    """Match starts in reference lexical coordinates, excluding the first row.

    Starts whose exact first lexical token is unaligned remain unmatched/ambiguous;
    never snap over a missing span. Main paragraphs and asides are separate rows.
    """
    hyp, ref = tokens(replay['words']), tokens(refs)
    word_first = {}
    for i, (_, wi) in enumerate(hyp):
        word_first.setdefault(replay['words'][wi]['id'], i)
    h_to_r = dict(pairs)
    targets = {i for i in range(1, len(ref)) if ref[i][1] != ref[i-1][1]}
    starts, ambiguous = [], 0
    for row in replay['display_paragraphs'] + replay['display_asides']:
        indexes = [word_first[x] for x in row['word_ids'] if x in word_first]
        if not indexes:
            ambiguous += 1
            continue
        start = min(indexes)
        if start == 0:
            continue
        if start not in h_to_r:
            ambiguous += 1
        else:
            starts.append(h_to_r[start])
    remaining = set(targets)
    matched = 0
    for start in sorted(starts):
        candidates = sorted((abs(start-x), x) for x in remaining if abs(start-x) <= tolerance)
        if candidates:
            remaining.remove(candidates[0][1]); matched += 1
    n = len(starts)+ambiguous
    return dict(tolerance_lexical_tokens=tolerance, hypothesis_boundaries=n, reference_boundaries=len(targets),
                matched=matched, ambiguous_unaligned_starts=ambiguous, unmatched_hypothesis=n-matched,
                unmatched_reference=len(remaining), precision=matched/n if n else None,
                recall=matched/len(targets) if targets else None)


def boundary_causes(replay):
    # Diagnostic reconstruction only; Python never generates host output.
    version = replay.get('grouping_provenance', 'speaker-turn-attribution-v3')
    if version not in ('speaker-turn-attribution-v3', 'speaker-turn-grouping-v2'):
        raise ValueError('Unsupported grouping predicates: ' + version)
    counts = collections.Counter()
    distance_changes = 0
    for a, b in zip(replay['segments'], replay['segments'][1:]):
        def evidence(s):
            e = s.get('speaker_inference', {}).get('evidence', {})
            return e.get('distance_ms') if isinstance(e, dict) and e.get('type') == 'nearest_interval' else None
        da, db = evidence(a), evidence(b)
        ia = a.get('speaker_id') or (a.get('speaker_inference', {}).get('speaker_id') if da is not None else None)
        ib = b.get('speaker_id') or (b.get('speaker_inference', {}).get('speaker_id') if db is not None else None)
        reasons = []
        if (da != db if version == 'speaker-turn-attribution-v3' else (da is None) != (db is None)):
            reasons.append('nearest_evidence_change')
        if ia != ib: reasons.append('builder_speaker_change')
        if b['start_ms']-a['end_ms'] >= 1000: reasons.append('pause_1s')
        if b['words'][0]['end_ms']-a['start_ms'] > 30000: reasons.append('duration_cap')
        if len(a['words']) >= 80: reasons.append('word_cap')
        if a['words'][-1]['text'][-1:] in ('.','?','!') and (ia is None or a['end_ms']-a['start_ms'] >= 12000 or len(a['words']) >= 40): reasons.append('sentence_break')
        counts['+'.join(reasons) or 'unexplained'] += 1
        if da is not None and db is not None and da != db and ia == ib: distance_changes += 1
    return dict(predicate_version=version, combinations=dict(counts), same_speaker_inferred_distance_changes=distance_changes)


def evaluate(replay, refs, paragraphs, mapping):
    pairs = align(tokens(replay['words']), tokens(refs))
    scored = {v: score(replay, refs, pairs, mapping, v)[0] for v in ('canonical', 'effective')}
    nt, nr = len(tokens(replay['words'])), len(tokens(refs))
    timed = None
    if all('start_ms' in r for r in refs):
        tp, _ = timed_pairs(replay['words'], refs)
        timed = {}
        for view, field in [('canonical', 'labels'), ('effective', 'effective_labels')]:
            c = collections.Counter(classify(replay[field][i], s, mapping) for i, _, s in tp)
            timed[view] = dict(c)
        timed['unit'] = 'saved words, greatest positive time overlap; fixed lexical mapping'
    return dict(alignment=dict(method='unicode casefold + Unicode word runs; SequenceMatcher autojunk=False',
                               matched_tokens=len(pairs), hypothesis_tokens=nt, reference_tokens=nr,
                               hypothesis_coverage=len(pairs)/nt if nt else None, reference_coverage=len(pairs)/nr if nr else None),
                mapping=mapping, attribution=scored, time_sensitivity=timed,
                reference=dict(kind='machine reference, not human ground truth', rows=len(refs),
                               zero_duration_rows=sum(r.get('start_ms') is not None and r.get('start_ms') == r.get('end_ms') for r in refs)),
                saved=rows_metrics(replay['segments']), reading=rows_metrics(replay['display_paragraphs']),
                asides=rows_metrics(replay['display_asides']), conservation=conservation(replay),
                boundaries=[boundary_metrics(replay, paragraphs, align(tokens(replay['words']), tokens(paragraphs)), t) for t in (0, 1, 3)],
                saved_boundary_changes=boundary_causes(replay))


def review_pack(baseline, candidate, refs, mapping):
    """Compare on common *reference token indices*, robust to changed word units."""
    ref = tokens(refs)
    bh, ch = tokens(baseline['words']), tokens(candidate['words'])
    bp, cp = align(bh, ref), align(ch, ref)
    bi, ci = {j: bh[i][1] for i, j in bp}, {j: ch[i][1] for i, j in cp}
    result, cases = {}, []
    for view in ('canonical', 'effective'):
        _, bs = score(baseline, refs, bp, mapping, view)
        _, cs = score(candidate, refs, cp, mapping, view)
        field = 'labels' if view == 'canonical' else 'effective_labels'
        counts = collections.Counter()
        for j in sorted(bs.keys() & cs.keys()):
            counts[bs[j]+'->'+cs[j]] += 1
            b, c = bi[j], ci[j]
            changed = baseline[field][b] != candidate[field][c]
            if changed or cs[j] in ('wrong', 'unknown'):
                word = candidate['words'][c]
                cases.append(dict(view=view, reference_token_index=j, word_index=c,
                                  baseline_label=baseline[field][b], candidate_label=candidate[field][c],
                                  baseline_state=bs[j], candidate_state=cs[j], changed=changed,
                                  start_ms=word.get('startMs'), end_ms=word.get('endMs'),
                                  clip_start_ms=max(0, (word.get('startMs') or 0)-2000),
                                  clip_end_ms=(word.get('endMs') or 0)+2000,
                                  text=word['text'], context=' '.join(w['text'] for w in candidate['words'][max(0,c-5):c+6]),
                                  human_speaker=None, human_boundary=None, reviewer=None, notes=None))
        result[view] = dict(common_tokens=len(bs.keys() & cs.keys()), baseline_only=len(bs.keys()-cs.keys()),
                            candidate_only=len(cs.keys()-bs.keys()), transitions=dict(counts),
                            newly_wrong=sum(n for k,n in counts.items() if k.endswith('->wrong') and not k.startswith('wrong->')),
                            corrected_wrong=sum(n for k,n in counts.items() if k == 'wrong->correct'))
    return result, cases


def run_replay(binary, run, transcript, diarization, output, intraword_apostrophes=False, sentence_turns=False):
    with pathlib.Path(output).open('w') as stream:
        subprocess.run([str(binary), str(run), '--saved-words' if transcript == 'saved' else str(transcript), str(diarization)] + (['--intraword-apostrophes'] if intraword_apostrophes else []) + (['--sentence-turns'] if sentence_turns else []), stdout=stream, check=True)
    return read(output)


def verify_bundle(bundle, lock=None):
    if lock and sha256(bundle/'manifest.json') != read(lock)['baseline_manifest_sha256']:
        raise ValueError('Baseline manifest differs from the published lock')
    manifest = read(bundle/'manifest.json')
    for relative, expected in manifest['bundle_hashes'].items():
        if sha256(bundle/relative) != expected:
            raise ValueError('Frozen baseline hash mismatch: '+relative)
    return manifest


def source_files():
    host = ROOT/'Modules/Transcription/Sources/Transcription'
    names = ['SourceEnergyPrior', 'CanonicalTranscriptValidator', 'UnknownFragmentReconciler', 'TranscriptParagraph', 'CanonicalTranscript', 'WorkerASRTranscript', 'TokenTimingReconciler', 'SpeakerTurnBuilder', 'TranscriptDisplayGrouper']
    return [host/f'Transcript/{n}.swift' for n in names] + [host/'Import/AudioPreparationService.swift', host/'Jobs/TranscriptAssemblyStageRunner.swift', host/'UI/TranscriptReviewPresentation.swift', ROOT/'Scribe/App/Sources/ScribeAppCore/SourceEnergyTimeline.swift'] + list(pathlib.Path(__file__).parent.glob('*.py')) + [pathlib.Path(__file__).with_name('Replay.swift'), ROOT/'Workers/TranscriptionWorker/model_manifest.json', ROOT/'Workers/TranscriptionWorker/Package.resolved']


def freeze(args):
    bundle = args.bundle.resolve()
    if bundle.exists():
        raise ValueError('Refusing to replace an existing baseline bundle')
    if bundle.is_relative_to(ROOT):
        raise ValueError('Private baseline must be outside the source checkout')
    bundle.mkdir(parents=True, mode=0o700)
    corpus = read(args.corpus)
    source_hashes = {}
    for path in source_files():
        relative = path.relative_to(ROOT)
        dest = bundle/'source'/relative
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, dest)
        source_hashes[str(relative)] = sha256(path)
    models = {str(p.relative_to(args.models)): sha256(p) for p in sorted(args.models.rglob('*')) if p.is_file()}
    write(bundle/'model-hashes.json', models)
    manifest = dict(name=BASELINE, source_hashes=source_hashes, source_tree_sha256=digest(source_hashes),
                    git_revision=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                    models=dict(tree_sha256=digest(models), file_count=len(models), role='installed assets; saved-artifact replay performs no model inference'),
                    toolchain=subprocess.check_output(['swiftc', '--version'], text=True).strip(), platform=platform.platform(),
                    corpus=corpus, recordings={}, timing_policy='No latency or memory claims; host replay only, no fresh inference.')
    binary = bundle/'host-replay'
    aggregate = dict(name=BASELINE, membership=corpus['membership'], recordings={})
    for entry in corpus['recordings']:
        key = entry['id']; run = pathlib.Path(entry['run']).expanduser()
        dest = bundle/key; dest.mkdir()
        inputs = {}
        source_audio = list(run.parents[1].glob('source.*'))
        if len(source_audio) != 1:
            raise ValueError('Expected exactly one original source audio: '+key)
        inputs['original_source_audio'] = sha256(source_audio[0])
        canonical_source = read(run/'canonical-transcript.json')['source']
        if inputs['original_source_audio'] != canonical_source['checksum']:
            raise ValueError('Original recording checksum mismatch: '+key)
        # Hash every saved artifact including prepared audio; copy only replay inputs.
        for path in sorted(run.iterdir()):
            if path.is_file():
                inputs[path.name] = sha256(path)
                if path.suffix == '.json':
                    shutil.copy2(path, dest/path.name)
        for label, path in entry['references'].items():
            path = ROOT/path
            inputs['reference_'+label] = sha256(path)
            if inputs['reference_'+label] != entry['reference_sha256'][label]:
                raise ValueError('Reference checksum mismatch: '+key+'/'+label)
            shutil.copy2(path, dest/(label+'.json'))
        if inputs['canonical-transcript.json'] != entry['canonical_sha256']:
            raise ValueError('Canonical input does not match corpus: '+key)
        if not binary.exists():
            subprocess.run([sys.executable, str(bundle/'source/Tools/DiarizationAnalysis/replay.py'), str(dest), 'saved', str(dest/'diarization.json'), '--output', str(dest/'replay.json'), '--keep-executable', str(binary)], check=True)
        else:
            run_replay(binary, dest, 'saved', dest/'diarization.json', dest/'replay.json')
        replay = read(dest/'replay.json')
        refs, paras = reference(dest/'segments.json'), reference(dest/'paragraphs.json')
        mapping = mapping_for(replay, refs, align(tokens(replay['words']), tokens(refs)))
        write(dest/'mapping.json', mapping)
        result = evaluate(replay, refs, paras, mapping)
        result['self_comparison'], cases = review_pack(replay, replay, refs, mapping)
        write(dest/'review.json', dict(audio_path=str(run/'prepared.wav'), cases=cases, annotation_status='not reviewed'))
        canonical = read(dest/'canonical-transcript.json')
        def semantic(segments):
            return [{k:s.get(k) for k in ('text','start_ms','end_ms','speaker_id','speaker_inference','overlap','words')} for s in segments]
        result['saved_reproduction'] = dict(segments_semantically_equal=semantic(canonical['segments']) == semantic(replay['reconciled_segments']),
                                            saved_segment_count=len(canonical['segments']))
        if not result['saved_reproduction']['segments_semantically_equal']:
            raise ValueError('Saved canonical reproduction failed: '+key)
        result['reference_grouping_comparison'] = dict(
            normalized_text_equal=[x[0] for x in tokens(refs)] == [x[0] for x in tokens(paras)],
            segment_rows=len(refs), paragraph_rows=len(paras),
            paragraph_one_word_rows=sum(len(lexical(r['text'])) == 1 for r in paras))
        if (dest/'transcript.json').exists():
            raw = run_replay(binary, dest, dest/'transcript.json', dest/'diarization.json', dest/'raw-replay.json')
            result['raw_asr_reproduction'] = dict(words_equal=raw['words']==replay['words'], segments_equal=raw['segments']==replay['segments'])
            if not all(result['raw_asr_reproduction'].values()):
                raise ValueError('Raw ASR reconstruction differs from saved words: '+key)
        config = canonical.get('processing_options', {})
        manifest['recordings'][key] = dict(inputs=inputs, processing_options=config, config_sha256=digest(config),
                                          engine=read(dest/'diarization.json').get('engine'), mapping_sha256=sha256(dest/'mapping.json'))
        aggregate['recordings'][key] = result
    manifest['binary_sha256'] = sha256(binary)
    write(bundle/'aggregate.json', aggregate)
    manifest['bundle_hashes'] = {str(p.relative_to(bundle)):sha256(p) for p in sorted(bundle.rglob('*')) if p.is_file()}
    write(bundle/'manifest.json', manifest)
    # Public evidence has no transcript text, speaker names, or private review cases.
    write(args.output, dict(**aggregate, provenance=manifest, baseline_manifest_sha256=sha256(bundle/'manifest.json')))
    for p in bundle.rglob('*'):
        if p.is_file():
            p.chmod(0o500 if p == binary else 0o400)
    print(json.dumps(dict(bundle=str(bundle), manifest_sha256=sha256(bundle/'manifest.json'), output=str(args.output))))


def compare(args):
    manifest = verify_bundle(args.bundle, args.lock)
    config = read(args.config)
    allowed = {'id', 'baseline', 'word_input', 'recordings', 'host_replay', 'binary_sha256', 'source_root', 'source_tree_sha256', 'description', 'intraword_apostrophes', 'sentence_turns'}
    if set(config)-allowed or config.get('word_input','saved') not in ('saved','raw'):
        raise ValueError('Unknown candidate configuration field or word input')
    if type(config.get('sentence_turns', False)) is not bool:
        raise ValueError('sentence_turns must be a boolean')
    if config.get('sentence_turns') and 'host_replay' not in config:
        raise ValueError('Sentence turns require an explicit current host')
    if type(config.get('intraword_apostrophes', False)) is not bool:
        raise ValueError('intraword_apostrophes must be a boolean')
    if config.get('intraword_apostrophes') and (config.get('word_input') != 'raw' or 'host_replay' not in config):
        raise ValueError('Apostrophe candidate requires raw tokens and an explicit current host')
    if set(config.get('recordings',{})) - {e['id'] for e in manifest['corpus']['recordings']}:
        raise ValueError('Unknown recording override')
    candidate_sources = manifest['source_hashes']
    if 'host_replay' in config:
        source_root = pathlib.Path(config['source_root'])
        candidate_sources = {p:sha256(source_root/p) for p in manifest['source_hashes']}
        if digest(candidate_sources) != config['source_tree_sha256']:
            raise ValueError('Candidate source tree hash mismatch')
    if config['baseline'] != manifest['name']:
        raise ValueError('Wrong baseline')
    if args.output.resolve().is_relative_to(args.bundle.resolve()) or args.private_output.resolve().is_relative_to(args.bundle.resolve()):
        raise ValueError('Candidate outputs must not modify the frozen bundle')
    if args.private_output.resolve().is_relative_to(ROOT):
        raise ValueError('Private review output must be outside the source checkout')
    args.private_output.mkdir(parents=True, exist_ok=False, mode=0o700)
    results = {}
    for entry in manifest['corpus']['recordings']:
        key = entry['id']; base = args.bundle/key
        override = config.get('recordings', {}).get(key, {})
        if set(override)-{'diarization','diarization_sha256','speaker_correspondence'}:
            raise ValueError('Unknown recording configuration field')
        binary = pathlib.Path(config.get('host_replay', str(args.bundle/'host-replay'))).resolve()
        if sha256(binary) != config.get('binary_sha256', manifest['binary_sha256']):
            raise ValueError('Candidate executable hash mismatch')
        diar = pathlib.Path(override.get('diarization', str(base/'diarization.json')))
        if 'diarization' in override and sha256(diar) != override['diarization_sha256']:
            raise ValueError('Candidate diarization hash mismatch')
        transcript = base/'transcript.json' if config.get('word_input', 'saved') == 'raw' else 'saved'
        replay = run_replay(binary, base, transcript, diar, args.private_output/(key+'.json'), config.get('intraword_apostrophes', False), config.get('sentence_turns', False))
        refs, paras = reference(base/'segments.json'), reference(base/'paragraphs.json')
        mapping = read(base/'mapping.json')
        # New cluster IDs require explicit correspondence to baseline cluster IDs.
        correspondence = override.get('speaker_correspondence', {})
        if correspondence:
            if len(set(correspondence.values())) != len(correspondence):
                raise ValueError('Speaker correspondence must be one-to-one')
            for field in ('labels','effective_labels'):
                replay[field] = [correspondence.get(s, s) for s in replay[field]]
        result = evaluate(replay, refs, paras, mapping)
        baseline_replay = read(base/'replay.json')
        result['change'], cases = review_pack(baseline_replay, replay, refs, mapping)
        bt, ct = tokens(baseline_replay['words']), tokens(replay['words'])
        common = align(bt, ct)
        result['word_comparison'] = dict(saved_word_objects_equal=baseline_replay['words']==replay['words'],
                                         baseline_words=len(baseline_replay['words']), candidate_words=len(replay['words']),
                                         common_lexical_tokens=len(common), baseline_unmatched_tokens=len(bt)-len(common),
                                         candidate_unmatched_tokens=len(ct)-len(common),
                                         normalized_lexical_sequence_equal=[t[0] for t in bt]==[t[0] for t in ct])
        if config.get('word_input','saved') == 'saved' and not result['word_comparison']['saved_word_objects_equal']:
            raise ValueError('Fixed saved-ASR word contract violated')
        result['provenance'] = dict(config_sha256=sha256(args.config), binary_sha256=sha256(binary), diarization_sha256=sha256(diar),
                                     source_hashes=candidate_sources, speaker_correspondence=correspondence,
                                     word_input=config.get('word_input','saved'))
        write(args.private_output/(key+'-review.json'), dict(audio_path=entry['run']+'/prepared.wav', cases=cases, annotation_status='not reviewed'))
        results[key] = result
    write(args.output, dict(name=config['id'], baseline=manifest['name'], baseline_manifest_sha256=sha256(args.bundle/'manifest.json'), recordings=results))


def main():
    p = argparse.ArgumentParser(description=__doc__); sub = p.add_subparsers(dest='command', required=True)
    f = sub.add_parser('freeze'); f.add_argument('--corpus', type=pathlib.Path, required=True); f.add_argument('--bundle', type=pathlib.Path, required=True)
    f.add_argument('--models', type=pathlib.Path, required=True); f.add_argument('--output', type=pathlib.Path, required=True)
    c = sub.add_parser('compare'); c.add_argument('--bundle', type=pathlib.Path, required=True); c.add_argument('--config', type=pathlib.Path, required=True)
    c.add_argument('--private-output', type=pathlib.Path, required=True); c.add_argument('--output', type=pathlib.Path, required=True)
    v = sub.add_parser('verify'); v.add_argument('--bundle', type=pathlib.Path, required=True)
    for parser in (c,v):
        parser.add_argument('--lock', type=pathlib.Path, default=ROOT/'docs/investigations/transcript-quality-baseline-v1.json')
    args = p.parse_args()
    if args.command == 'freeze': freeze(args)
    elif args.command == 'compare': compare(args)
    else: verify_bundle(args.bundle, args.lock); print('Frozen bundle hashes verified')

if __name__ == '__main__':
    main()
