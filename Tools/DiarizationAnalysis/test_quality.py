import copy
import json
import pathlib
import tempfile
import unittest

from quality import (align, tokens, reference, mapping_for, score, review_pack,
                     boundary_metrics, conservation, verify_bundle)
from wder import sha256


def replay(texts, labels):
    words = [dict(id=str(i), text=t, startMs=i*100, endMs=(i+1)*100) for i,t in enumerate(texts)]
    segments = [dict(id='s'+str(i), text=t, words=[dict(text=t,start_ms=i*100,end_ms=(i+1)*100)]) for i,t in enumerate(texts)]
    return dict(words=words, labels=labels, effective_labels=labels[:], segments=segments,
                display_paragraphs=[dict(word_ids=[str(i)],source_segment_ids=['s'+str(i)],word_count=1,words=copy.deepcopy(segments[i]['words'])) for i in range(len(texts))], display_asides=[])


class QualityTests(unittest.TestCase):
    def test_split_contraction_uses_common_lexical_coordinates(self):
        b = replay(["don't", 'stop'], ['a','a'])
        c = replay(["don'", 't', 'stop'], ['a','a','a'])
        refs = [dict(text="Don't stop",speaker='r')]
        changes,cases = review_pack(b,c,refs,{'a':'r'})
        self.assertEqual(changes['effective']['common_tokens'],3)
        self.assertEqual(changes['effective']['newly_wrong'],0)
        self.assertFalse(cases)

    def test_equal_totals_do_not_hide_new_disagreements(self):
        b = replay(['one','two'],['a','b'])
        c = replay(['one','two'],['b','a'])
        refs = [dict(text='one two', speaker='r')]
        result,cases = review_pack(b,c,refs,{'a':'r'})
        self.assertEqual(result['effective']['newly_wrong'],1)
        self.assertEqual(result['effective']['corrected_wrong'],1)
        self.assertTrue(all(x['human_speaker'] is None for x in cases))

    def test_fixed_mapping_used_for_canonical_and_effective(self):
        r = replay(['one','two','three'],[None,'b','a'])
        r['effective_labels']=['a','b','a']
        refs=[dict(text='one two three',speaker='r')]
        pairs=align(tokens(r['words']),tokens(refs)); mapping=mapping_for(r,refs,pairs)
        self.assertEqual(mapping,{'a':'r'})
        self.assertEqual(score(r,refs,pairs,mapping,'canonical')[0]['unknown'],1)
        self.assertEqual(score(r,refs,pairs,mapping,'effective')[0]['wrong'],1)

    def test_null_reference_and_zero_duration_are_retained(self):
        with tempfile.TemporaryDirectory() as d:
            p=pathlib.Path(d)/'r.json';p.write_text(json.dumps([dict(text='one',speaker=None,start=1,end=1),dict(text='two',speaker='Name',start=1,end=2)]))
            refs=reference(p)
        self.assertEqual(len(refs),2);self.assertIsNone(refs[0]['speaker'])
        r=replay(['one','two'],['a','a']); pairs=align(tokens(r['words']),tokens(refs))
        score_=score(r,refs,pairs,{'a':'reference_1'},'effective')[0]
        self.assertEqual(score_['unscoreable'],1);self.assertEqual(score_['scored_tokens'],1)

    def test_asides_conserve_words_and_detect_duplication(self):
        r=replay(['one','yes','two'],['a','b','a'])
        r['display_asides']=[r['display_paragraphs'].pop(1)]
        self.assertTrue(conservation(r)['main_plus_aside_words_equal'])
        r['display_paragraphs'].append(copy.deepcopy(r['display_asides'][0]))
        with self.assertRaises(ValueError):conservation(r)

    def test_conservation_detects_text_loss_even_if_counts_match(self):
        r=replay(['one'],['a']);r['segments'][0]['words'][0]['text']='changed'
        with self.assertRaises(ValueError):conservation(r)

    def test_unaligned_boundary_not_snapped(self):
        r=replay(['one','missing','two'],['a']*3)
        refs=[dict(text='one',speaker='r'),dict(text='two',speaker='r')]
        result=boundary_metrics(r,refs,align(tokens(r['words']),tokens(refs)),0)
        self.assertEqual(result['matched'],1);self.assertEqual(result['ambiguous_unaligned_starts'],1)

    def test_boundary_tolerance_is_one_to_one(self):
        r=replay(['one','two','three'],['a']*3)
        refs=[dict(text='one two',speaker='r'),dict(text='three',speaker='r')]
        result=boundary_metrics(r,refs,align(tokens(r['words']),tokens(refs)),3)
        self.assertEqual(result['matched'],1);self.assertEqual(result['unmatched_hypothesis'],1)

    def test_frozen_artifact_tampering_is_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            root=pathlib.Path(d);p=root/'data';p.write_text('original')
            (root/'manifest.json').write_text(json.dumps(dict(bundle_hashes={'data':sha256(p)})))
            verify_bundle(root);p.write_text('changed')
            with self.assertRaises(ValueError):verify_bundle(root)

    def test_repeated_tokens_deterministic_and_unmatched_reported(self):
        b=replay(['yes','yes','end'],['a']*3);c=replay(['yes','end'],['a']*2)
        refs=[dict(text='yes yes end',speaker='r')]
        changes,_=review_pack(b,c,refs,{'a':'r'})
        self.assertEqual(changes['canonical']['baseline_only'],1)
        self.assertEqual(align(tokens(b['words']),tokens(refs)),align(tokens(b['words']),tokens(refs)))

if __name__=='__main__':unittest.main()
