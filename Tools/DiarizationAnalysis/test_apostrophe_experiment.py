import unittest
from apostrophe_experiment import reconstruction_evidence


class ReconstructionEvidenceTests(unittest.TestCase):
    def test_join_preserves_characters_and_lexical_span(self):
        before = [dict(text="don'", startMs=0, endMs=100), dict(text="t", startMs=200, endMs=300)]
        after = [dict(text="don't", startMs=0, endMs=300)]
        result = reconstruction_evidence(before, after, "don't")
        self.assertEqual(result['merged_words'], 1)
        self.assertEqual(result['split_common_suffix_forms_before'], 1)
        self.assertEqual(result['split_common_suffix_forms_after'], 0)
        self.assertEqual(result['apostrophe_space_forms_raw_asr'], 0)

    def test_lost_punctuation_and_stretched_timing_fail(self):
        before = [dict(text="don'", startMs=0, endMs=100), dict(text="t.", startMs=200, endMs=300)]
        for after in [[dict(text="dont.", startMs=0, endMs=300)],
                      [dict(text="don't.", startMs=0, endMs=900)]]:
            with self.assertRaises(AssertionError):
                reconstruction_evidence(before, after, "don't.")
