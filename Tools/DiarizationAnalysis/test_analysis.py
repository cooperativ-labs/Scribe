import unittest

from compare import assign
from summarize import proxy


class MetricContracts(unittest.TestCase):
    def test_unmatched_words_are_not_scored_and_unknowns_are_not_remapped(self):
        words = [dict(text=t) for t in ['hello', 'extra', 'yes', 'end']]
        reference = [dict(speaker='one', text='hello absent'), dict(speaker='two', text='yes end')]
        result = proxy(words, ['B', 'A', 'A', None], reference)
        self.assertEqual(result['matched_tokens'], 3)
        self.assertEqual(result['unmatched_hypothesis_tokens'], 1)
        self.assertEqual(result['unmatched_reference_tokens'], 1)
        self.assertEqual(result['matched_correct'], 2)
        self.assertEqual(result['matched_unknown'], 1)

    def test_rounding_matches_swift_at_half_millisecond(self):
        words = [dict(startMs=0, endMs=101)]
        intervals = [dict(speakerID='A', startSeconds=0, endSeconds=.0505)]
        self.assertEqual(assign(words, intervals), ['A'])

    def test_overlap_ties_stay_unknown_and_windows_do_not_accumulate(self):
        words = [dict(startMs=0, endMs=200)]
        tied = [dict(speakerID=s, startSeconds=0, endSeconds=.15) for s in ['A', 'B']]
        self.assertEqual(assign(words, tied), [None])
        repeated = [dict(speakerID='A', startSeconds=0, endSeconds=.06)] * 2
        self.assertEqual(assign(words, repeated), [None])


if __name__ == '__main__':
    unittest.main()
