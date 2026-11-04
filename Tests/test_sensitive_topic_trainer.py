"""Continuation controls use tiny synthetic weights, never an evaluation holdout."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('sensitive_trainer', ROOT / 'tools/sensitive_topic_classifier.py')
TRAINER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TRAINER)


class ContinuationTests(unittest.TestCase):
    def artifact(self):
        return dict(formatVersion=1, featureIdentity=TRAINER.FEATURE_ID, dimensions=16384,
                    trainingDigest='a' * 64,
                    topics=[dict(id=topic, bias=0.123456789, threshold=0.5,
                                 weights={'1': 0.3141592653, '45': -0.2718281828}) for topic in TRAINER.TOPICS])

    def cases(self):
        return [dict(id='train-positive', split='train', familyID='train-family',
                     text='Личная плата за нужную подпись.', topics=[TRAINER.TOPICS[0]]),
                dict(id='train-negative', split='train', familyID='train-family',
                     text='Официальная услуга по опубликованному тарифу.', topics=[]),
                dict(id='development', split='development', familyID='development-family',
                     text='Документы передали секретарю.', topics=[])]

    def write(self, root, value):
        path = Path(root) / 'artifact.json'
        data = json.dumps(value).encode()
        path.write_bytes(data)
        return path, hashlib.sha256(data).hexdigest()

    def test_zero_steps_preserve_nonzero_weights_and_bias_without_mutation(self):
        base = self.artifact(); original = copy.deepcopy(base)
        result = TRAINER.train(self.cases(), 'b' * 64, initial_artifact=base, epochs=0)
        for before, after in zip(base['topics'], result['topics']):
            self.assertEqual(before['weights'], after['weights'])
            self.assertEqual(before['bias'], after['bias'])
        self.assertEqual(base, original)

    def test_one_step_depends_on_baseline_and_is_deterministic(self):
        base = self.artifact()
        resumed = TRAINER.train(self.cases(), 'b' * 64, initial_artifact=base, epochs=1, learning_rate=0.3)
        again = TRAINER.train(self.cases(), 'b' * 64, initial_artifact=base, epochs=1, learning_rate=0.3)
        fresh = TRAINER.train(self.cases(), 'b' * 64, epochs=1, learning_rate=0.3)
        self.assertEqual(resumed, again)
        self.assertNotEqual(resumed['topics'][0]['weights'], fresh['topics'][0]['weights'])
        self.assertNotEqual(resumed['topics'][0]['weights'], base['topics'][0]['weights'])

    def test_checksum_and_compatibility_guard(self):
        with tempfile.TemporaryDirectory() as directory:
            path, digest = self.write(directory, self.artifact())
            self.assertEqual(TRAINER.load_initial_artifact(path, digest), self.artifact())
            with self.assertRaises(ValueError):
                TRAINER.load_initial_artifact(path, '0' * 64)
            changed = self.artifact(); changed['dimensions'] = 32768
            path, digest = self.write(directory, changed)
            with self.assertRaises(ValueError):
                TRAINER.load_initial_artifact(path, digest)

    def test_nonfinite_boolean_and_out_of_range_weights_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            for value in [float('nan'), True, 101.0]:
                changed = self.artifact(); changed['topics'][0]['weights']['1'] = value
                path, digest = self.write(directory, changed)
                with self.assertRaises(ValueError):
                    TRAINER.load_initial_artifact(path, digest)

    def test_duplicate_json_keys_and_symlinks_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path, digest = self.write(directory, self.artifact())
            link = Path(directory) / 'link.json'; link.symlink_to(path)
            with self.assertRaises(ValueError):
                TRAINER.load_initial_artifact(link, digest)
            raw = b'{"formatVersion":1,"formatVersion":1}'
            path.write_bytes(raw)
            with self.assertRaises(ValueError):
                TRAINER.load_initial_artifact(path, hashlib.sha256(raw).hexdigest())

    def test_grouped_split_and_duplicate_text_guard(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'cases.jsonl'
            rows = self.cases()
            rows[-1]['familyID'] = 'train-family'
            path.write_text(''.join(json.dumps(row) + '\n' for row in rows))
            with self.assertRaisesRegex(ValueError, 'family crosses'):
                TRAINER.load_cases(path)
            rows = self.cases(); rows[-1]['text'] = rows[0]['text'].upper()
            path.write_text(''.join(json.dumps(row) + '\n' for row in rows))
            with self.assertRaisesRegex(ValueError, 'duplicate normalized'):
                TRAINER.load_cases(path)


if __name__ == '__main__':
    unittest.main()
