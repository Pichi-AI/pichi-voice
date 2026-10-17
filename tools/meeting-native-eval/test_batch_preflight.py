#!/usr/bin/env python3
"""Synthetic validation checks. These never load a speech model or use private audio."""
from pathlib import Path
import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
import wave

BATCH = Path(__file__).with_name('batch.py')

class PreflightTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='meeting-native-preflight-')
        self.root = Path(self.temporary.name)
        clips = []
        for index in range(20):
            audio = self.root / f'clip-{index}.wav'
            # Distinct synthetic PCM content prevents accidental audio deduplication.
            with wave.open(str(audio), 'wb') as file:
                file.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
                file.writeframes(index.to_bytes(2, 'little', signed=True) * 160)
            reference = self.root / f'ref-{index}.json'
            reference.write_text('{}')
            clips.append({'clip_id': f'clip-{index}', 'meeting_id': f'meeting-{index}',
                'split': 'development' if index < 12 else 'heldOut', 'audio_path': str(audio),
                'audio_sha256': hashlib.sha256(audio.read_bytes()).hexdigest(), 'duration_seconds': 0.01,
                'weak_reference_path': str(reference), 'weak_reference_sha256': hashlib.sha256(reference.read_bytes()).hexdigest(),
                'observed_weak_speaker_count': 2})
        self.manifest = self.root / 'manifest.json'
        self.lock = self.root / 'lock.json'
        self.value = {'schema_version': 1, 'clips': clips}
        self.save()

    def tearDown(self):
        self.temporary.cleanup()

    def save(self):
        self.manifest.write_text(json.dumps(self.value))
        self.lock.write_text(json.dumps({'status': 'frozen', 'corpus_manifest_sha256': hashlib.sha256(self.manifest.read_bytes()).hexdigest()}))

    def reject(self, message):
        result = subprocess.run([sys.executable, str(BATCH), '--manifest', str(self.manifest),
            '--selection-lock', str(self.lock), '--output', str(self.root / 'output'), '--pass-name', 'test',
            '--gigaam-directory', str(self.root / 'no-model'), '--fast32-directory', str(self.root / 'no-model')],
            text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(message, result.stderr)
        self.assertFalse((self.root / 'output').exists(), 'Validation failure invoked native output phase')

    def test_lock_change_fails_before_inference(self):
        self.manifest.write_text(self.manifest.read_text() + '\n')
        self.reject('must be frozen')

    def test_whole_meeting_leakage_fails_before_inference(self):
        self.value['clips'][19]['meeting_id'] = self.value['clips'][0]['meeting_id']
        self.save()
        self.reject('whole-meeting held-out clips without leakage')

    def test_duplicate_audio_fails_before_inference(self):
        self.value['clips'][1]['audio_path'] = self.value['clips'][0]['audio_path']
        self.value['clips'][1]['audio_sha256'] = self.value['clips'][0]['audio_sha256']
        self.save()
        self.reject('Changed or duplicate audio')

    def test_reference_replacement_fails_before_inference(self):
        Path(self.value['clips'][1]['weak_reference_path']).write_text('{"changed":true}')
        self.reject('Reference changed')

    def test_insufficient_audio_fails_before_inference(self):
        self.value['clips'].pop()
        self.save()
        self.reject('At least 20 distinct actual audio clips')

    def test_underrepresented_two_speaker_case_fails_before_inference(self):
        for clip in self.value['clips'][:11]:
            clip['observed_weak_speaker_count'] = 4
        self.save()
        self.reject('common two-speaker case')

if __name__ == '__main__':
    unittest.main()
