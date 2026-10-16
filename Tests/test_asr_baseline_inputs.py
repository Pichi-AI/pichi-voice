#!/usr/bin/env python3
"""Portable regressions for sandboxed baseline resource declarations and staging."""

import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("baseline_inputs", ROOT / "scripts/dev/asr-baseline-inputs.py")
BASELINE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BASELINE)


class BaselineStagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.inputs = self.root / "approved fixtures"
        self.inputs.mkdir()
        (self.inputs / "nested").mkdir()
        (self.inputs / "nested/model.bin").write_bytes(b"synthetic model fixture")
        (self.inputs / "manifest.json").write_text('{"synthetic": true}')
        self.output = self.root / "bundle/ASRBaselineInputs"

    def prepare(self):
        return BASELINE.prepare(self.inputs, self.root / "declarations").parent

    def stage(self, declarations):
        BASELINE.stage(self.inputs, self.output, declarations / "manifest.json")

    def test_declarations_cover_every_copied_file_and_parent(self):
        declarations = self.prepare()
        repeated = self.prepare()
        for name in ("inputs.xcfilelist", "outputs.xcfilelist", "manifest.json"):
            self.assertEqual((declarations / name).read_bytes(), (repeated / name).read_bytes())
        self.assertNotEqual(declarations, repeated)
        self.assertEqual((declarations / "inputs.xcfilelist").read_text().splitlines(), [
            str(self.inputs), str(self.inputs / "nested"),
            str(self.inputs / "manifest.json"), str(self.inputs / "nested/model.bin"),
        ])
        outputs = (declarations / "outputs.xcfilelist").read_text().splitlines()
        self.assertIn(f"{BASELINE.OUTPUT_ROOT}/nested", outputs)
        self.assertIn(f"{BASELINE.OUTPUT_ROOT}/nested/model.bin", outputs)
        self.assertIn(f"{BASELINE.OUTPUT_ROOT}/{BASELINE.STAMP}", outputs)
        self.assertEqual((declarations / "inputs.xcconfig").stat().st_mode & 0o777, 0o600)
        self.stage(declarations)
        self.assertEqual((self.output / "nested/model.bin").read_bytes(), b"synthetic model fixture")
        self.stage(declarations)

    def test_default_public_contract_matches_tracked_placeholder(self):
        host = ROOT / "Tests/FluidASRBaselineHost"
        manifest = json.loads((host / "staging-manifest.json").read_text())
        files, _ = BASELINE.validate_manifest(manifest)
        self.assertEqual(files, [{"path": "placeholder.json", "size": (host / "Inputs/placeholder.json").stat().st_size}])
        self.assertIn("$(FLUID_ASR_BASELINE_INPUTS)/placeholder.json", (host / "inputs.xcfilelist").read_text().splitlines())
        self.assertIn(f"{BASELINE.OUTPUT_ROOT}/placeholder.json", (host / "outputs.xcfilelist").read_text().splitlines())
        BASELINE.stage(host / "Inputs", self.output, host / "staging-manifest.json")
        self.assertEqual((self.output / "placeholder.json").read_bytes(), (host / "Inputs/placeholder.json").read_bytes())
        with self.assertRaisesRegex(ValueError, "custom fixtures"):
            BASELINE.stage(self.inputs, self.output, host / "staging-manifest.json")

    def test_changed_fixture_set_requires_clean_bundle(self):
        declarations = self.prepare()
        self.stage(declarations)
        (self.inputs / "manifest.json").unlink()
        updated = self.prepare()
        with self.assertRaisesRegex(ValueError, "clean baseline build products"):
            self.stage(updated)
        self.assertTrue((self.output / "manifest.json").exists())

    def test_old_unstamped_private_resources_require_clean_bundle(self):
        host = ROOT / "Tests/FluidASRBaselineHost"
        self.output.mkdir(parents=True)
        stale = self.output / "previous-private-fixture.wav"
        stale.write_bytes(b"synthetic prior fixture")
        with self.assertRaisesRegex(ValueError, "clean baseline build products"):
            BASELINE.stage(host / "Inputs", self.output, host / "staging-manifest.json")
        self.assertFalse((self.output / "placeholder.json").exists())
        self.assertEqual(stale.read_bytes(), b"synthetic prior fixture")

    def test_xcode_precreated_empty_declared_directories_are_safe(self):
        declarations = self.prepare()
        (self.output / "nested").mkdir(parents=True)
        self.stage(declarations)
        self.assertEqual((self.output / "nested/model.bin").read_bytes(), b"synthetic model fixture")

    def test_matching_stamp_rejects_unexpected_nested_resource(self):
        declarations = self.prepare()
        self.stage(declarations)
        (self.output / "nested/stale.bin").write_bytes(b"synthetic stale data")
        with self.assertRaisesRegex(ValueError, "clean baseline build products"):
            self.stage(declarations)

    def test_private_root_is_pinned(self):
        declarations = self.prepare()
        with self.assertRaisesRegex(ValueError, "does not match"):
            BASELINE.stage(self.root, self.output, declarations / "manifest.json")

    def test_size_change_requires_new_declaration(self):
        declarations = self.prepare()
        (self.inputs / "nested/model.bin").write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "prepare file declarations again"):
            self.stage(declarations)
        self.assertFalse((self.output / "nested/model.bin").exists())

    def test_preparation_rejects_symlink_files_directories_and_special_files(self):
        for target in (self.root, self.inputs / "manifest.json"):
            link = self.inputs / "link"
            link.symlink_to(target)
            with self.assertRaisesRegex(ValueError, "symlinks and special files"):
                self.prepare()
            link.unlink()
        fifo = self.inputs / "fifo"
        os.mkfifo(fifo)
        with self.assertRaisesRegex(ValueError, "symlinks and special files"):
            self.prepare()

    def test_staging_rejects_symlink_substituted_after_preparation(self):
        declarations = self.prepare()
        original = self.inputs / "nested/model.bin"
        original.unlink()
        original.symlink_to(self.inputs / "manifest.json")
        with self.assertRaises(OSError):
            self.stage(declarations)
        original.unlink()
        (self.inputs / "nested").rmdir()
        (self.inputs / "nested").symlink_to(self.root)
        with self.assertRaises(OSError):
            self.stage(declarations)

    def test_staging_rejects_destination_symlink(self):
        declarations = self.prepare()
        self.stage(declarations)
        (self.output / "nested/model.bin").unlink()
        (self.output / "nested").rmdir()
        (self.output / "nested").symlink_to(self.root)
        with self.assertRaises(OSError):
            self.stage(declarations)
        self.assertFalse((self.root / "model.bin").exists())

    def test_invalid_relative_names_and_manifest_bounds_fail_closed(self):
        for name in ("", "/etc/passwd", "../escape", "a/../b", "a//b", "./x", "~/x", "a\\b", "a\nb", "$(SRCROOT)/x", BASELINE.STAMP):
            with self.subTest(name=name), self.assertRaises(ValueError):
                BASELINE.safe_path(name)
        valid = {"version": 1, "files": [{"path": "a", "size": 1}]}
        for invalid in (
            {"version": 2, "files": valid["files"]},
            {"version": 1, "files": []},
            {"version": 1, "files": [{"path": "a", "size": True}]},
            {"version": 1, "files": [{"path": "a", "size": BASELINE.MAX_FILE_BYTES + 1}]},
            {"version": 1, "files": valid["files"] * 2},
            {"version": 1, "files": [{"path": "a", "size": 0}, {"path": "a/b", "size": 0}]},
        ):
            with self.subTest(manifest=invalid), self.assertRaises(ValueError):
                BASELINE.validate_manifest(invalid)
        with patch.object(BASELINE, "MAX_FILES", 1), self.assertRaises(ValueError):
            self.prepare()
        with patch.object(BASELINE, "MAX_TOTAL_BYTES", 1), self.assertRaises(ValueError):
            self.prepare()


if __name__ == "__main__":
    unittest.main()
