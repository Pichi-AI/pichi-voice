#!/usr/bin/env python3
"""Synthetic Mach-O metadata and signing-boundary regressions, without building code."""
import importlib.util
from pathlib import Path
import plistlib
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("framework_metadata", ROOT / "scripts/dev/mobile-framework-metadata.py")
metadata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metadata)


def macho(minimum=0x110000, platform=2, legacy=False):
    command = (struct.pack("<IIII", 0x25, 16, minimum, 0x1B0000) if legacy else
               struct.pack("<IIIIII", 0x32, 24, platform, minimum, 0x1B0000, 0))
    return struct.pack("<IIIIIIII", 0xFEEDFACF, 0x100000C, 0, 6, 1, len(command), 0, 0) + command


def universal(binaries):
    offset = 8 + 20 * len(binaries)
    headers = []
    for index, binary in enumerate(binaries):
        headers.append(struct.pack(">IIIII", 0x100000C + index, 0, offset, len(binary), 0))
        offset += len(binary)
    return struct.pack(">II", 0xCAFEBABE, len(binaries)) + b"".join(headers + binaries)


class FrameworkMetadataTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="pichi-framework-metadata-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.framework = self.root / "App.app/Frameworks/onnxruntime.framework"
        self.framework.mkdir(parents=True)
        self.binary = self.framework / "onnxruntime"
        self.binary.write_bytes(macho())
        self.plist = self.framework / "Info.plist"
        self.info = {"CFBundleExecutable": "onnxruntime", "CFBundleIdentifier": "com.microsoft.onnxruntime",
                     "CFBundleVersion": "1.24.2", "MinimumOSVersion": "15.1"}
        self.plist.write_bytes(plistlib.dumps(self.info))
        self.environment = {"IPHONEOS_DEPLOYMENT_TARGET": "17.0", "CODE_SIGNING_ALLOWED": "YES",
                            "EXPANDED_CODE_SIGN_IDENTITY": "synthetic-existing-identity"}

    def test_current_rejection_is_detected_and_normalized_from_binary(self):
        with self.assertRaisesRegex(metadata.MetadataError, "below Mach-O"):
            metadata.check(self.root / "App.app")
        commands = []
        original_binary = self.binary.read_bytes()
        self.assertTrue(metadata.normalize_onnx(self.framework, self.environment,
                                               lambda command, **kwargs: commands.append((command, kwargs))))
        self.assertEqual(plistlib.loads(self.plist.read_bytes()), {**self.info, "MinimumOSVersion": "17.0"})
        self.assertEqual(self.binary.read_bytes(), original_binary)
        self.assertEqual(metadata.check(self.root / "App.app"), 1)
        self.assertEqual(commands[0][0][0:4], ["/usr/bin/codesign", "--force", "--sign", "synthetic-existing-identity"])
        self.assertIn("--preserve-metadata=identifier,entitlements,requirements,flags,runtime", commands[0][0])
        self.assertEqual(commands[1][0][1:4], ["--verify", "--strict", str(self.framework)])
        self.assertTrue(all(kwargs == {"check": True} for _, kwargs in commands))
        commands.clear()
        self.assertFalse(metadata.normalize_onnx(self.framework, self.environment,
                                                lambda command, **kwargs: commands.append(command)))
        self.assertEqual(commands, [["/usr/bin/codesign", "--verify", "--strict", str(self.framework)]])

    def test_signing_failure_cannot_be_accepted_on_retry(self):
        def fail_sign(command, **_kwargs):
            raise subprocess.CalledProcessError(1, command)
        with self.assertRaises(subprocess.CalledProcessError):
            metadata.normalize_onnx(self.framework, self.environment, fail_sign)
        calls = []
        def retry(command, **_kwargs):
            calls.append(command)
            if len(calls) == 1:
                raise subprocess.CalledProcessError(1, command)
        self.assertFalse(metadata.normalize_onnx(self.framework, self.environment, retry))
        self.assertEqual([command[1] for command in calls], ["--verify", "--force", "--verify"])

    def test_every_architecture_and_legacy_minimum_are_read(self):
        self.binary.write_bytes(universal([macho(0x0F0100, 7), macho(0x110200, 7)]))
        self.assertEqual(metadata.macho_minimums(self.binary), [(7, "15.1"), (7, "17.2")])
        with self.assertRaisesRegex(metadata.MetadataError, "different minimum"):
            metadata.normalize_onnx(self.framework, self.environment)
        self.binary.write_bytes(macho(0x0F0100, legacy=True))
        self.assertEqual(metadata.macho_minimums(self.binary), [(2, "15.1")])

    def test_missing_identity_newer_runtime_and_wrong_framework_fail_before_write(self):
        original = self.plist.read_bytes()
        for environment in [{**self.environment, "EXPANDED_CODE_SIGN_IDENTITY": ""},
                            {**self.environment, "IPHONEOS_DEPLOYMENT_TARGET": "16.0"}]:
            with self.assertRaises(metadata.MetadataError):
                metadata.normalize_onnx(self.framework, environment)
            self.assertEqual(self.plist.read_bytes(), original)
        other = self.framework.with_name("Other.framework")
        self.framework.rename(other)
        with self.assertRaisesRegex(metadata.MetadataError, "Only the copied ONNX"):
            metadata.normalize_onnx(other, self.environment)

    def test_unsigned_build_does_not_use_signing_identity(self):
        self.assertTrue(metadata.normalize_onnx(self.framework,
            {**self.environment, "CODE_SIGNING_ALLOWED": "NO", "EXPANDED_CODE_SIGN_IDENTITY": ""},
            lambda *_args, **_kwargs: self.fail("Unsigned build must not sign")))

    def test_nested_framework_is_checked_without_mutation(self):
        self.plist.write_bytes(plistlib.dumps({**self.info, "MinimumOSVersion": "17.0"}))
        nested = self.root / "App.app/PlugIns/Activity.appex/Frameworks/Other.framework"
        nested.mkdir(parents=True)
        (nested / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "Other", "MinimumOSVersion": "15.0"}))
        (nested / "Other").write_bytes(macho(0x100000))
        before = {p: p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        with self.assertRaisesRegex(metadata.MetadataError, "Other.framework"):
            metadata.check(self.root / "App.app")
        self.assertEqual(before, {p: p.read_bytes() for p in self.root.rglob("*") if p.is_file()})

    def test_truncated_static_and_unexpected_platform_are_rejected(self):
        for data in [b"!<arch>\n", macho()[:-1], struct.pack(">II", 0xCAFEBABE, 100),
                     macho(platform=1)]:
            self.binary.write_bytes(data)
            with self.assertRaises(metadata.MetadataError):
                metadata.framework_metadata(self.framework)

    def test_symlink_metadata_cannot_be_changed(self):
        target = self.plist.with_name("original.plist")
        self.plist.rename(target)
        self.plist.symlink_to(target.name)
        original = target.read_bytes()
        with self.assertRaisesRegex(metadata.MetadataError, "must not be symlinks"):
            metadata.normalize_onnx(self.framework, self.environment)
        self.assertEqual(target.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
