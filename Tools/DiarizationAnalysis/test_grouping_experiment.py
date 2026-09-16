import copy
import unittest
from grouping_experiment import evidence_conservation, boundary_review
from test_quality import replay


class GroupingExperimentTests(unittest.TestCase):
    def fixture(self):
        before = replay(['Maybe', 'later'], [None, 'a'])
        for i, s in enumerate(before['segments']):
            s.update(start_ms=i*100, end_ms=(i+1)*100)
        before['reconciled_segments'] = copy.deepcopy(before['segments'])
        before['reconciled_segments'][0]['speaker_inference'] = {'evidence': {'distance_ms': 20}}
        for i, s in enumerate(before['reconciled_segments']):
            s.update(start_ms=i*100, end_ms=(i+1)*100)
        after = copy.deepcopy(before)
        after['display_attribution_ranges'] = [dict(source_segment_ids=r['source_segment_ids'], ranges=[
            dict(source=copy.deepcopy(s), word_start=0, word_end=1)])
            for r, s in zip(after['display_paragraphs'], after['reconciled_segments'])]
        return before, after

    def test_exact_ranges_preserve_uncertainty(self):
        before, after = self.fixture()
        self.assertTrue(evidence_conservation(before, after)['evidence_snapshots_exact'])

    def test_rejects_lost_inference_even_with_identical_words(self):
        before, after = self.fixture()
        del after['display_attribution_ranges'][0]['ranges'][0]['source']['speaker_inference']
        with self.assertRaisesRegex(ValueError, 'Lost source evidence'):
            evidence_conservation(before, after)

    def test_rejects_shifted_ranges_and_promoted_labels(self):
        for mutation in ('range', 'label'):
            before, after = self.fixture()
            if mutation == 'range':
                after['display_attribution_ranges'][0]['ranges'][0]['word_start'] = 1
            else:
                after['labels'][0] = 'a'
            with self.assertRaises(ValueError):
                evidence_conservation(before, after)

    def test_boundary_review_records_unreviewed_added_and_removed_cases(self):
        before, after = self.fixture()
        after['display_paragraphs'] = [after['display_paragraphs'][0]]
        review = boundary_review(before, after, '/private/audio.wav')
        self.assertEqual(len(review['cases']), 1)
        self.assertEqual(review['cases'][0]['change'], 'removed')
        self.assertIsNone(review['cases'][0]['human_boundary'])
        self.assertIsNone(review['cases'][0]['reviewer'])


if __name__ == '__main__':
    unittest.main()
