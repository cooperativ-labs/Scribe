import unittest

from short_turn_experiment import acoustic_correspondence, interval_correspondence, interval_evidence


def interval(speaker, start, end, overlap=False):
    return dict(speakerID=speaker, startSeconds=start, endSeconds=end,
                qualityScore=0.8, overlapsAnotherSpeaker=overlap)


class ShortTurnEvidenceTests(unittest.TestCase):
    def test_correspondence_uses_acoustic_time_when_first_appearance_swaps(self):
        baseline = [interval('speaker_1', 2, 10), interval('speaker_2', 12, 20)]
        candidate = [interval('speaker_1', 0, 0.4), interval('speaker_2', 2, 10), interval('speaker_1', 12, 20)]
        mapping, evidence = interval_correspondence(candidate, baseline)
        self.assertEqual(mapping, {'speaker_1':'speaker_2', 'speaker_2':'speaker_1'})
        self.assertEqual(evidence['speaker_1']['shared_seconds'], 8)

    def test_coupled_mapping_uses_vectors_not_reference_scores(self):
        candidate = [dict(speakerID='b',vector=[1,0]), dict(speakerID='a',vector=[0,1])]
        control = [dict(speakerID='a',vector=[1,0]), dict(speakerID='b',vector=[0,1])]
        mapping, evidence = acoustic_correspondence(candidate, control)
        self.assertEqual(mapping, {'a':'b','b':'a'})
        self.assertEqual(evidence['a']['cosine'], 1)

    def test_retention_preserves_cluster_provenance_and_overlap(self):
        chunks = [{'speakerId':'S2','embedding256':[1,0]}]
        control = dict(rawClusterIDsByStableID={'speaker_1':'S2'}, chunkEmbeddings=chunks,
                       result=dict(intervals=[interval('speaker_1',2,4)]))
        variant = dict(rawClusterIDsByStableID={'speaker_1':'S8','speaker_2':'S2'}, chunkEmbeddings=chunks,
                       result=dict(intervals=[interval('speaker_1',1.8,2.2,True), interval('speaker_2',2,4,True)]))
        evidence = interval_evidence(variant, control)
        self.assertEqual(evidence['removed_intervals'], 0)
        self.assertEqual(evidence['added_intervals'], 1)
        self.assertEqual(evidence['added_overlap_intervals'], 1)
        self.assertTrue(evidence['same_chunk_embeddings_and_assignments'])

    def test_changed_cluster_assignment_is_not_an_output_only_change(self):
        control = dict(rawClusterIDsByStableID={'speaker_1':'S2'}, chunkEmbeddings=[{'speakerId':'S2'}],
                       result=dict(intervals=[interval('speaker_1',2,4)]))
        variant = {**control, 'chunkEmbeddings':[{'speakerId':'S3'}]}
        self.assertFalse(interval_evidence(variant, control)['same_chunk_embeddings_and_assignments'])


if __name__ == '__main__':
    unittest.main()
