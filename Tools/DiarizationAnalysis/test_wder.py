import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace
import json
from pathlib import Path

from wder import (engine_revision, manual_reference, parse_reference, score_replay,
                  text_pairs, timed_pairs, paragraph_metrics, replay_run)


class WDERContracts(unittest.TestCase):
    def replay(self, labels):
        return dict(words=[dict(text="one", startMs=0, endMs=100), dict(text="two", startMs=100, endMs=200),
                           dict(text="three", startMs=200, endMs=300)], labels=labels,
                    segments=[dict(words=[{}, {}]), dict(words=[{}])])

    def test_timed_alignment_scores_only_overlapping_manual_rows(self):
        reference = [dict(speaker="edited", text="", start_ms=90, end_ms=210)]
        pairs, used = timed_pairs(self.replay(["a"] * 3)["words"], reference)
        self.assertEqual([(word, speaker) for word, _, speaker in pairs], [(0, "edited"), (1, "edited"), (2, "edited")])
        self.assertEqual(used, {0})

    def test_text_alignment_uses_sequence_matcher_coverage(self):
        reference = [dict(speaker="Alice", text="one absent"), dict(speaker="Bob", text="three")]
        pairs, used, hypothesis, target = text_pairs(self.replay(["x"] * 3)["words"], reference)
        self.assertEqual([(word, speaker) for word, _, speaker in pairs], [(0, "Alice"), (2, "Bob")])
        self.assertEqual((used, hypothesis, target), ({0, 1}, 3, 3))

    def test_mapping_is_one_to_one_and_unknown_is_not_remapped(self):
        reference = [dict(speaker="Alice", text="one"), dict(speaker="Bob", text="two"), dict(speaker="Bob", text="three")]
        result = score_replay(self.replay(["cluster", None, "cluster"]), reference, "test", {})
        agreement = result["agreement"]
        # One emitted cluster cannot be mapped to both reference people.
        self.assertEqual((agreement["correct_words"], agreement["wrong_words"], agreement["unknown_words"]), (1, 1, 1))
        self.assertEqual(agreement["wder_pct"], 66.667)
        self.assertEqual(result["paragraphs"], {"paragraph_count": 2, "single_word_paragraph_count": 1})

    def test_manual_reference_excludes_automatic_rows(self):
        canonical = {"segments": [dict(attribution_source="automatic", speaker_id="a", start_ms=0, end_ms=1),
                                  dict(attribution_source="manual", speaker_id="b", start_ms=2, end_ms=3)]}
        self.assertEqual(manual_reference(canonical), [dict(speaker="b", text="", start_ms=2, end_ms=3)])

    def test_import_formats_and_timestamp_detection(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "reference.vtt"
            path.write_text("WEBVTT\n\n00:00:01.000 --> 00:00:02.500\nA: Hello there\n")
            self.assertEqual(parse_reference(path), [dict(speaker="A", text="Hello there", start_ms=1000, end_ms=2500)])
            plain = Path(temporary) / "reference.txt"
            plain.write_text("A: hello\nB: goodbye\n")
            self.assertEqual([row["speaker"] for row in parse_reference(plain)], ["A", "B"])

    def test_display_paragraph_counts_and_segment_only_text(self):
        self.assertEqual(paragraph_metrics([dict(word_count=1), dict(word_count=6)]),
                         dict(paragraph_count=2, single_word_paragraph_count=1))
        self.assertEqual(paragraph_metrics([dict(text="one", words=None), dict(text="two words")]),
                         dict(paragraph_count=2, single_word_paragraph_count=1))

    def test_reused_host_translates_saved_words_argument(self):
        with tempfile.TemporaryDirectory() as temporary:
            executable = Path(temporary) / "host"
            executable.write_bytes(b"test executable")
            args = SimpleNamespace(host_replay=executable, run=Path("run"), transcript="saved", diarization=Path("diarization.json"))
            with patch("wder.subprocess.check_output", return_value=json.dumps(self.replay(["a"] * 3)).encode()) as run:
                result, digest = replay_run(args)
            self.assertEqual(run.call_args.args[0][2], "--saved-words")
            self.assertEqual(result["labels"], ["a"] * 3)
            self.assertEqual(len(digest), 64)

    def test_engine_runtime_revision_is_recorded(self):
        self.assertEqual(engine_revision({"engine": {"runtimeRevision": "engine-pin"}}), "engine-pin")


if __name__ == "__main__":
    unittest.main()
