import random
import unittest
import meeting_asr_text_eval as scorer


class WeakTextTests(unittest.TestCase):
    def test_normalization_is_explicit_not_semantic(self):
        self.assertEqual(scorer.normalize('Ёж, ЕЖ! GigaAM １２.5 API-v3 café'), ['еж', 'еж', 'gigaam', '12', '5', 'api', 'v3', 'café'])
        self.assertNotEqual(scorer.normalize('два'), scorer.normalize('2'))
        self.assertNotEqual(scorer.normalize('voice'), scorer.normalize('войс'))

    def test_edits_and_unbounded_rate(self):
        self.assertEqual(scorer.word_edits(['a', 'b'], ['a', 'c'])['substitutions'], 1)
        self.assertEqual(scorer.word_edits(['a', 'b'], ['a'])['deletions'], 1)
        self.assertEqual(scorer.word_edits(['a'], ['a', 'b', 'c', 'd'])['weak_wer'], 3)
        self.assertIsNone(scorer.word_edits([], ['a'])['weak_wer'])
        self.assertEqual(scorer.word_edits(['a'], [])['weak_wer'], 1)

    def test_character_distance_against_full_dp(self):
        rng = random.Random(641)
        for _ in range(250):
            left = ''.join(rng.choices('абвa', k=rng.randrange(20)))
            right = ''.join(rng.choices('абвa', k=rng.randrange(20)))
            self.assertEqual(scorer.char_distance(left, right), scorer.word_edits(list(left), list(right))['distance'])
        self.assertEqual(scorer.char_distance('kitten', 'sitting'), 3)

    def test_character_distance_beyond_machine_word(self):
        reference = "абвг" * 100
        self.assertEqual(scorer.char_distance(reference, reference), 0)
        self.assertEqual(scorer.char_distance(reference, reference[:200] + "x" + reference[200:]), 1)
        self.assertEqual(scorer.char_distance(reference, reference[:200] + reference[201:]), 1)

    def test_complete_turn_guard_does_not_trim_reference_text(self):
        turns = [dict(start=0, end=2, text='outside', clipped_start=True),
                 dict(start=2, end=5, text='one two'), dict(start=5, end=8, text='three'),
                 dict(start=8, end=10, text='last')]
        runs, excluded = scorer.reference_runs(turns, 10, 1)
        self.assertEqual(runs, [dict(start=2, end=8, text='one two three', turn_indices=[1, 2])])
        self.assertEqual(excluded, {'clip_truncated': 1, 'clip_edge_guard': 1})

    def test_invalid_overlap_not_double_counted(self):
        with self.assertRaises(ValueError):
            scorer.reference_runs([dict(start=1, end=3, text='a'), dict(start=2, end=4, text='b')], 10, 0)

    def test_native_midpoint_and_boundary_coverage(self):
        clip = dict(clip_id='c', audio_sha256='sha', split='development', duration_seconds=10,
                    speaker_count_stratum=2, language_condition='Russian')
        reference = dict(turns=[dict(start=0, end=2, text='excluded'), dict(start=2, end=8, text='one two'),
                               dict(start=8, end=10, text='excluded')])
        native = dict(clipID='c', audioSHA256='sha', units=[
            dict(analysisStart=1.9, analysisEnd=2.3, text='one', precision='word'),
            dict(analysisStart=7.8, analysisEnd=8.2, text='excluded', precision='word'),
            dict(analysisStart=5, analysisEnd=6, text='two', precision='word'),
            dict(analysisStart=6, analysisEnd=5, text='invalid', precision='word')])
        result = scorer.score_clip(clip, reference, native)
        primary = result['profiles'][1]
        self.assertEqual(primary['weak_wer'], 0)
        self.assertEqual(primary['native_units_included'], 2)
        self.assertEqual(primary['boundary_crossing_native_units_included'], 1)
        self.assertEqual(result['native_units_rejected'], {'invalid_geometry': 1})

    def test_no_eligible_reference_is_undefined(self):
        clip = dict(clip_id='c', audio_sha256='sha', split='development', duration_seconds=10,
                    speaker_count_stratum=2, language_condition='English')
        native = dict(clipID='c', audioSHA256='sha', units=[])
        result = scorer.score_clip(clip, dict(turns=[dict(start=0, end=10, text='full')]), native)
        self.assertIsNone(result['profiles'][1]['weak_wer'])
        self.assertEqual(result['profiles'][1]['distance'], 0)
        self.assertIsNone(scorer.aggregate([result])[1]['weak_cer'])


if __name__ == '__main__':
    unittest.main()
