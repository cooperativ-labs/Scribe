#!/usr/bin/env python3
"""Compare saved Scribe checkpoints to a speaker/text MacWhisper export locally.
No audio, transcript text, or names are included in the aggregate JSON output.
Metrics are reference agreement on exact text matches, not DER or ground truth WDER.
Segment counts use TranscriptDisplayGrouper rules; legacy sentence-row counts are also reported.
"""
import argparse
import collections
import difflib
import itertools
import json
import math
import re
import statistics
from pathlib import Path


def lexical(text):
    return re.findall(r"\w+", text.casefold())


def assign(words, intervals, cap=None):
    result = []
    for w in words:
        start, end = w['startMs'], w['endMs']
        if cap:
            end = min(end, start + cap)
        scores = {}
        for t in intervals:
            # Swift's .rounded() uses ties away from zero for nonnegative times.
            overlap = max(0, min(end, math.floor(t['endSeconds'] * 1000 + .5)) - max(start, math.floor(t['startSeconds'] * 1000 + .5)))
            if overlap:
                scores[t['speakerID']] = max(scores.get(t['speakerID'], 0), overlap)
        ranked = sorted(scores.items(), key=lambda x: (-x[1], x[0]))
        winner = None
        if ranked and ranked[0][1] >= max(50, math.ceil((end - start) * .5)) and (len(ranked) == 1 or ranked[0][1] - ranked[1][1] > 1):
            winner = ranked[0][0]
        result.append(winner)
    return result


def ends_sentence(text):
    return bool(text) and text[-1] in '.?!'


def segments(words, labels, pause_ms=1000, preferred_duration_ms=12000, preferred_words=40, max_duration_ms=30000, max_words=80):
    """Match TranscriptDisplayGrouper: punctuation is a preferred break, not a mandatory row."""
    groups = []
    for w, label in zip(words, labels):
        if groups:
            g = groups[-1]
            same = g['label'] == label
            gap = w['startMs'] - g['end']
            duration = w['endMs'] - g['start']
            count = g['count']
            last_ends = ends_sentence(g['text'])
            prefer_break = last_ends and (g['label'] is None or (g['end'] - g['start']) >= preferred_duration_ms or count >= preferred_words)
            if same and gap < pause_ms and duration <= max_duration_ms and count < max_words and not prefer_break:
                g['end'] = max(g['end'], w['endMs'])
                g['count'] += 1
                g['text'] = w['text']
                continue
        groups.append(dict(label=label, start=w['startMs'], end=w['endMs'], count=1, text=w['text']))
    return groups


def legacy_sentence_segments(words, labels):
    """Pre-ffzh grouping: a new row after every final .?!, speaker change, 1s gap, or 30s."""
    groups = []
    for w, label in zip(words, labels):
        if groups and groups[-1]['label'] == label and groups[-1]['text'][-1] not in '.?!' and w['startMs'] - groups[-1]['end'] < 1000 and w['endMs'] - groups[-1]['start'] <= 30000:
            g = groups[-1]
            g['end'] = max(g['end'], w['endMs'])
            g['count'] += 1
            g['text'] = w['text']
        else:
            groups.append(dict(label=label, start=w['startMs'], end=w['endMs'], count=1, text=w['text']))
    return groups


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('run', type=Path)
    p.add_argument('baseline', type=Path)
    p.add_argument('--diarization', type=Path)
    p.add_argument('--words', type=Path, help='Fixed word checkpoint or actual Swift replay JSON')
    a = p.parse_args()
    words = json.loads((a.words or a.run/'words.json').read_text())['words']
    diar = json.loads((a.diarization or a.run/'diarization.json').read_text())['intervals']
    baseline = json.loads(a.baseline.read_text())
    canonical = json.loads((a.run/'canonical-transcript.json').read_text())
    ref_ids = {name: f'reference_{i+1}' for i,name in enumerate(dict.fromkeys(x['speaker'] for x in baseline))}
    ref = [(token, ref_ids[s['speaker']]) for s in baseline for token in lexical(s['text'])]
    hyp = [(token,i) for i,w in enumerate(words) for token in lexical(w['text'])]
    matcher = difflib.SequenceMatcher(None, [x[0] for x in hyp], [x[0] for x in ref], autojunk=False)
    pairs = [(i+k,j+k) for i,j,n in matcher.get_matching_blocks() for k in range(n)]
    output = dict(word_count=len(words), reference_segments=len(baseline), reference_lexical_tokens=len(ref), scribe_lexical_tokens=len(hyp), matched_lexical_tokens=len(pairs), canonical_revision=canonical['revision'], saved_canonical_segments=len(canonical['segments']))
    matched_words = {hyp[i][1] for i, _ in pairs}
    output['coverage'] = dict(
        metric='exact-matched-text reference agreement proxy; not human ground truth, DER or WDER',
        unmatched_scribe_lexical_tokens=len(hyp)-len(pairs),
        unmatched_reference_lexical_tokens=len(ref)-len(pairs),
        scribe_lexical_coverage_pct=round(100*len(pairs)/len(hyp), 3) if hyp else None,
        reference_lexical_coverage_pct=round(100*len(pairs)/len(ref), 3) if ref else None,
        words_without_any_matched_lexical_token=len(words)-len(matched_words),
    )
    output['intervals_by_speaker'] = dict(collections.Counter(t['speakerID'] for t in diar))
    output['interval_seconds_by_speaker'] = {s: round(sum(t['endSeconds']-t['startSeconds'] for t in diar if t['speakerID']==s),3) for s in sorted({t['speakerID'] for t in diar})}
    interval_total = sum(output['interval_seconds_by_speaker'].values())
    dominant_interval_fraction = (
        max(output['interval_seconds_by_speaker'].values()) / interval_total
        if interval_total else None
    )
    output['clustering_diagnostics'] = {
        'cluster_count': len(output['intervals_by_speaker']),
        'interval_count': len(diar),
        'overlap_interval_count': sum(bool(t.get('overlapsAnotherSpeaker')) for t in diar),
        'dominant_interval_fraction': round(dominant_interval_fraction, 6) if dominant_interval_fraction is not None else None,
        'separation_appears_collapsed_from_intervals': (
            len(output['intervals_by_speaker']) >= 2
            and dominant_interval_fraction is not None
            and dominant_interval_fraction >= .98
        ),
    }
    # New worker artifacts add supported chunk-assignment occupancy plus the
    # exact engine/configuration. Keep accepting historical checkpoints.
    diarization_document = json.loads((a.diarization or a.run/'diarization.json').read_text())
    for key in ('engine', 'configuration', 'clusteringDiagnostics'):
        if key in diarization_document:
            output[key] = diarization_document[key]
    output['word_duration_ms'] = dict(median=statistics.median(w['endMs']-w['startMs'] for w in words),maximum=max(w['endMs']-w['startMs'] for w in words),over_1000=sum(w['endMs']-w['startMs']>1000 for w in words))
    output['word_gaps_at_least_1000ms'] = sum(y['startMs']-x['endMs']>=1000 for x,y in zip(words,words[1:]))
    for cap in [None, 320]:
        labels = assign(words, diar, cap)
        counts = collections.Counter((labels[hyp[i][1]],ref[j][1]) for i,j in pairs)
        speakers=sorted(set(labels)-{None})
        # One-to-one label mapping; unmatched extra clusters remain disagreements.
        maps=[dict(zip(speakers, perm)) for perm in itertools.permutations(list(ref_ids.values())+[None]*max(0,len(speakers)-len(ref_ids)),len(speakers))]
        mapping=max(maps or [{}],key=lambda m:sum(n for (s,r),n in counts.items() if s and m.get(s)==r))
        good=sum(n for (s,r),n in counts.items() if s and mapping.get(s)==r)
        unknown=sum(n for (s,r),n in counts.items() if s is None)
        groups=segments(words,labels)
        legacy=legacy_sentence_segments(words,labels)
        output['original' if cap is None else 'diagnostic_320ms_attribution_window'] = dict(unknown_words=labels.count(None),segments=len(groups),one_word_segments=sum(g['count']==1 for g in groups),median_words_per_segment=statistics.median(g['count'] for g in groups),legacy_sentence_segments=len(legacy),legacy_one_word_segments=sum(g['count']==1 for g in legacy),legacy_median_words_per_segment=statistics.median(g['count'] for g in legacy),mapping=mapping,matched_token_agreement_pct=round(100*good/len(pairs),2),matched_token_unknown_pct=round(100*unknown/len(pairs),2),matched_token_wrong_speaker_pct=round(100*(len(pairs)-good-unknown)/len(pairs),2),confusion={str(s):{r:counts[s,r] for r in ref_ids.values()} for s in [None]+speakers})
    print(json.dumps(output,indent=2))


if __name__ == '__main__':
    main()
