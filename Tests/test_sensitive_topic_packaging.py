#!/usr/bin/env python3
"""Release-resource controls use original synthetic inputs and task-owned output."""
import hashlib
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('topic_packaging', ROOT / 'scripts/dev/stage-sensitive-topic-model.py')
PACKAGING = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGING)


class PackagingTests(unittest.TestCase):
    def test_real_generation_is_frozen_and_second_run_preserves_resource(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / 'app/sensitive-topics-v2.json'
            command = [sys.executable, '-B', '-S', str(ROOT / 'scripts/dev/stage-sensitive-topic-model.py'), '--output', str(output)]
            subprocess.run(command, check=True, capture_output=True)
            self.assertEqual(hashlib.sha256(output.read_bytes()).hexdigest(), PACKAGING.ARTIFACT_SHA256)
            original = (output.read_bytes(), output.stat().st_mtime_ns)
            subprocess.run(command, check=True, capture_output=True)
            self.assertEqual((output.read_bytes(), output.stat().st_mtime_ns), original)
            self.assertEqual(list((output.parent / '.build/topic-resource/.build').iterdir()), [])

    def test_tampered_artifact_and_symlink_output_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            file = root / 'model.json'
            file.write_bytes(b'tampered')
            with self.assertRaises(ValueError):
                PACKAGING.verified_bytes(file, PACKAGING.ARTIFACT_SHA256)
            link = root / 'link.json'
            link.symlink_to(file)
            with self.assertRaises(ValueError):
                PACKAGING.stage(link, root / 'work')
            self.assertEqual(file.read_bytes(), b'tampered')
            self.assertFalse((root / 'work').exists())


if __name__ == '__main__':
    unittest.main()
