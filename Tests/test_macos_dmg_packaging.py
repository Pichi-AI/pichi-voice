"""Offline contract checks for the distribution packager."""
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("macos_dmg", ROOT / "scripts/dev/package-macos-dmg.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
SIGNATURE = "Authority=Developer ID Application: Example\nTeamIdentifier=LU46F7HGJM\nTimestamp=now\nflags=runtime\n"


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / "Pichi Voice.app"
        (self.app / "Contents").mkdir(parents=True)
        self.info = {"CFBundleIdentifier": "ai.pichi.voice", "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "66"}
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(self.info))
        self.output = self.root / "Pichi Voice.dmg"

    def signed(self, command, **kwargs):
        return subprocess.CompletedProcess(command, 0, "", SIGNATURE)

    @patch.object(module.subprocess, "run")
    def test_distribution_must_pass_all_trust_checks_before_building(self, run):
        run.side_effect = self.signed
        with patch.object(module, "draw_background") as draw:
            def builder(output, name, settings):
                self.assertEqual(name, "Pichi Voice")
                self.assertEqual(settings["symlinks"], {"Applications": "/Applications"})
                self.assertEqual(settings["files"], [str(self.app)])
                self.assertEqual(settings["hide_extensions"], [])
                Path(output).write_bytes(b"image")
            self.assertEqual(module.build(self.app, self.output, builder=builder), self.info)
        self.assertEqual([c.args[0][0] for c in run.call_args_list], ["codesign", "xcrun", "spctl", "codesign", "hdiutil"])
        self.assertTrue(self.output.exists())
        self.assertEqual(plistlib.loads((self.app / "Contents/Info.plist").read_bytes()), self.info)

    def test_never_overwrites_output_or_writes_into_app(self):
        self.output.write_bytes(b"keep")
        with self.assertRaises(ValueError): module.build(self.app, self.output)
        self.assertEqual(self.output.read_bytes(), b"keep")
        with self.assertRaises(ValueError): module.build(self.app, self.app / "nested.dmg")
        alias = self.root / "alias.app"
        alias.symlink_to(self.app)
        with self.assertRaises(ValueError): module.build(alias, self.root / "new.dmg")

    def test_rejects_other_distribution_identity(self):
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "example.other"}))
        with self.assertRaises(ValueError): module.build(self.app, self.output)

    @patch.object(module.subprocess, "run")
    def test_rejects_missing_or_wrong_signature_and_notary(self, run):
        for signature in [SIGNATURE.replace("LU46F7HGJM", "OTHER"), SIGNATURE.replace("Developer ID Application:", "Apple Development:"), SIGNATURE.replace("Timestamp=now", "no timestamp")]:
            run.side_effect = None
            run.return_value = subprocess.CompletedProcess([], 0, "", signature)
            with self.assertRaises(ValueError): module.build(self.app, self.output)
        run.side_effect = subprocess.CalledProcessError(1, ["xcrun", "stapler"])
        with self.assertRaises(subprocess.CalledProcessError): module.build(self.app, self.output)

    @patch.object(module.subprocess, "run")
    def test_failure_removes_only_partial_image(self, run):
        run.side_effect = self.signed
        def builder(output, *args, **kwargs):
            Path(output).write_bytes(b"partial")
            raise RuntimeError("build failed")
        with patch.object(module, "draw_background"), self.assertRaises(RuntimeError):
            module.build(self.app, self.output, builder=builder)
        self.assertFalse(self.output.exists())
        self.assertTrue((self.app / "Contents/Info.plist").exists())


if __name__ == "__main__": unittest.main()
