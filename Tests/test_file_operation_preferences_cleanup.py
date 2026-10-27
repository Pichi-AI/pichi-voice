#!/usr/bin/env python3
"""Exercise cleanup ordering against isolated files without user preference access."""

import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest import mock


spec = importlib.util.spec_from_file_location(
    "file_preferences_cleanup", Path(__file__).parent / "Support/cleanup_file_operation_preferences.py")
cleanup_tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cleanup_tool)


class PreferencesCleanupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="file-cleanup-regression-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.home = self.root / "home"
        self.preferences = self.home / "Library/Preferences"
        self.preferences.mkdir(parents=True)
        self.domain = "synthetic.file-operation.3BCF135F-B7AC-4FA2-9FF0-516F5D04DC95"
        self.source = self.preferences / (self.domain + ".plist")
        self.manifest = self.root / "owned-domains.json"
        self.manifest.write_text(json.dumps([self.domain]))
        self.evidence = self.root / "evidence"
        self.home_patch = mock.patch.object(cleanup_tool.Path, "home", return_value=self.home)
        self.home_patch.start()
        self.addCleanup(self.home_patch.stop)

    def response(self, arguments):
        removing = arguments[-1] == "remove"
        rows = [{"domain": self.domain, "foundation": True if removing else None,
                 "appSync": True if removing else None, "directSync": True if removing else None,
                 "keyCount": 0}]
        return subprocess.CompletedProcess(arguments, 0, stdout=json.dumps(rows), stderr="")

    def assert_backup(self, data):
        checksum = hashlib.sha256(data).hexdigest()
        backup = self.evidence / "backups" / self.domain / (checksum + ".plist")
        self.assertEqual(backup.read_bytes(), data)
        audit = json.loads((self.evidence / "audit.json").read_text())
        self.assertTrue(any(item["sha256"] == checksum for item in audit["backups"]))

    def run_cleanup(self, api):
        with mock.patch.object(cleanup_tool.subprocess, "run", side_effect=api), \
                mock.patch.object(cleanup_tool.time, "sleep"):
            return cleanup_tool.cleanup(self.manifest, self.evidence)

    def test_nonempty_bytes_are_backed_up_before_api_removal(self):
        data = plistlib.dumps({"fixture": "original nonempty bytes"})
        self.source.write_bytes(data)

        def api(arguments, **_):
            if arguments[-1] == "remove":
                self.assert_backup(data)
                self.source.unlink()
            return self.response(arguments)

        report = self.run_cleanup(api)
        self.assertTrue(report["complete"])
        self.assertFalse(self.source.exists())
        self.assertEqual(report["backups"][0]["keyCount"], 1)

    def test_regenerated_version_is_backed_up_before_retry_api_removal(self):
        original = plistlib.dumps({"fixture": "original"})
        regenerated = plistlib.dumps({"fixture": "new version from deferred daemon flush"})
        self.source.write_bytes(original)
        calls = {"remove": 0, "verify": 0}

        def api(arguments, **_):
            mode = arguments[-1]
            calls[mode] += 1
            if mode == "remove":
                self.assert_backup(original if calls[mode] == 1 else regenerated)
                self.source.unlink()
            elif calls[mode] == 2:
                self.source.write_bytes(regenerated)
            return self.response(arguments)

        report = self.run_cleanup(api)
        self.assertTrue(report["complete"])
        self.assertEqual(calls["remove"], 2)
        self.assertEqual(len(report["backups"]), 2)
        self.assertFalse(self.source.exists())

    def test_unowned_domain_is_rejected_without_mutation(self):
        self.manifest.write_text(json.dumps(["ai.pichi.voice"]))
        with mock.patch.object(cleanup_tool.subprocess, "run") as api:
            with self.assertRaises(ValueError):
                cleanup_tool.cleanup(self.manifest, self.evidence)
            api.assert_not_called()
        self.assertFalse(self.evidence.exists())

    def test_links_are_rejected_before_api_removal(self):
        target = self.root / "preserved-target.plist"
        data = plistlib.dumps({"fixture": "preserve linked bytes"})
        target.write_bytes(data)
        for kind in ("symlink", "hardlink"):
            with self.subTest(kind=kind):
                self.evidence = self.root / ("evidence-" + kind)
                if kind == "symlink":
                    self.source.symlink_to(target)
                else:
                    self.source.hardlink_to(target)
                with mock.patch.object(cleanup_tool.subprocess, "run") as api:
                    with self.assertRaises((OSError, RuntimeError)):
                        cleanup_tool.cleanup(self.manifest, self.evidence)
                    api.assert_not_called()
                self.assertEqual(target.read_bytes(), data)
                self.source.unlink()

    def test_api_failure_preserves_source_and_audit(self):
        data = plistlib.dumps({"fixture": "retained after API failure"})
        self.source.write_bytes(data)

        def api(arguments, **_):
            self.assert_backup(data)
            raise subprocess.TimeoutExpired(arguments, 15)

        with self.assertRaises(subprocess.TimeoutExpired):
            self.run_cleanup(api)
        self.assertEqual(self.source.read_bytes(), data)
        audit = json.loads((self.evidence / "audit.json").read_text())
        self.assertFalse(audit["complete"])
        self.assertIn("TimeoutExpired", audit["error"])


if __name__ == "__main__":
    unittest.main()
