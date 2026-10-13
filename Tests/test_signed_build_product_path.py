#!/usr/bin/env python3
"""Exercise the signed build route without Xcode, Keychain access or signing."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class SignedBuildProductPathTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="voice-signed-build-test-")
        self.root = Path(self.directory.name)
        shutil.copyfile(ROOT / "build.sh", self.root / "build.sh")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.derived = self.root / "Derived Data"
        self.products = self.derived / "Build" / "Products" / "Debug"
        self.log = self.root / "signing.jsonl"
        self._executable("security", """#!/bin/sh
printf '%s\\n' '  1) 0123456789012345678901234567890123456789 "Apple Development: Fixture"'
""")
        self._executable("xcodebuild", """#!/usr/bin/env python3
import json, os, pathlib, sys
if '-showBuildSettings' in sys.argv:
    print(os.environ['TEST_BUILD_SETTINGS'])
else:
    framework = pathlib.Path(os.environ['TEST_BUILD_PRODUCT']) / 'Contents/Frameworks/CTranscribe.framework/Versions/A'
    (framework / 'Resources').mkdir(parents=True, exist_ok=True)
    (framework / 'CTranscribe').write_bytes(b'synthetic framework')
""")
        self._executable("codesign", """#!/usr/bin/env python3
import json, os, sys
with open(os.environ['TEST_SIGNING_LOG'], 'a') as stream:
    stream.write(json.dumps(sys.argv[1:]) + '\\n')
if '--display' in sys.argv:
    print('<?xml version="1.0"?><plist version="1.0"><dict/></plist>')
""")

    def tearDown(self):
        self.directory.cleanup()

    def _executable(self, name, source):
        path = self.bin / name
        path.write_text(source)
        path.chmod(0o755)

    def _settings(self, name="Pichi Voice Debug.app"):
        return [{"target": "fluid", "buildSettings": {
            "PRODUCT_TYPE": "com.apple.product-type.application",
            "TARGET_BUILD_DIR": str(self.products),
            "FULL_PRODUCT_NAME": name,
        }}]

    def _run(self, settings, product=None, profile="public"):
        environment = dict(os.environ)
        environment.update({
            "PATH": str(self.bin) + os.pathsep + environment["PATH"],
            "FLUIDVOICE_DERIVED_DATA_PATH": str(self.derived),
            "FLUIDVOICE_DEVELOPMENT_TEAM": "FIXTURE000",
            "TEST_BUILD_SETTINGS": json.dumps(settings),
            "TEST_BUILD_PRODUCT": str(product or self.products / "Pichi Voice Debug.app"),
            "TEST_SIGNING_LOG": str(self.log),
        })
        return subprocess.run(["bash", str(self.root / "build.sh"), profile],
                              cwd=self.root, env=environment, capture_output=True, text=True)

    def _assert_rejected_before_signing(self, settings):
        result = self._run(settings)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("Unable to resolve signed application product", result.stderr)
        self.assertFalse(self.log.exists(), "Rejected settings must never reach codesign")

    def test_brand_names_and_spaces_resolve_from_xcode_settings(self):
        for name in ["Pichi Voice Debug.app", "FluidVoice Debug.app", "Example Voice Debug.app",
                     "Example $(touch injected) Debug.app"]:
            with self.subTest(name=name):
                product = self.products / name
                result = self._run(self._settings(name), product)
                self.assertEqual(result.returncode, 0, result.stderr)
                calls = [json.loads(line) for line in self.log.read_text().splitlines()]
                self.assertEqual(calls[-1], ["--verify", "--deep", "--strict", str(product)])
                self.assertTrue((product / "Contents/Frameworks/CTranscribe.framework/CTranscribe").is_symlink())
                self.assertFalse((self.root / "injected").exists(), "Product text must never be evaluated as shell code")

    def test_non_application_or_wrong_target_is_rejected(self):
        for target, product_type in [("FluidASRBaselineHost", "com.apple.product-type.application"),
                                     ("fluid", "com.apple.product-type.bundle.unit-test")]:
            with self.subTest(target=target, product_type=product_type):
                settings = self._settings()
                settings[0]["target"] = target
                settings[0]["buildSettings"]["PRODUCT_TYPE"] = product_type
                self._assert_rejected_before_signing(settings)

    def test_missing_or_ambiguous_application_is_rejected(self):
        for settings in [[], self._settings() * 2]:
            with self.subTest(settings=settings):
                self._assert_rejected_before_signing(settings)

    def test_product_name_cannot_escape_the_build_directory(self):
        for name in ["../Other.app", "/Applications/Other.app", "Other.framework"]:
            with self.subTest(name=name):
                self._assert_rejected_before_signing(self._settings(name))

    def test_build_directory_must_be_absolute_and_inside_derived_data(self):
        for directory in ["Build/Products/Debug", str(self.root / "Outside")]:
            with self.subTest(directory=directory):
                settings = self._settings()
                settings[0]["buildSettings"]["TARGET_BUILD_DIR"] = directory
                self._assert_rejected_before_signing(settings)

    def test_missing_build_setting_is_rejected(self):
        settings = self._settings()
        del settings[0]["buildSettings"]["FULL_PRODUCT_NAME"]
        self._assert_rejected_before_signing(settings)

    def test_malformed_build_settings_are_rejected(self):
        for settings in [None, {}, [None], [{"target": "fluid", "buildSettings": "invalid"}]]:
            with self.subTest(settings=settings):
                self._assert_rejected_before_signing(settings)

    def test_bundle_symlink_cannot_redirect_signing_outside_derived_data(self):
        self.products.mkdir(parents=True)
        outside = self.root / "Outside.app"
        outside.mkdir()
        product = self.products / "Pichi Voice Debug.app"
        product.symlink_to(outside, target_is_directory=True)
        self._assert_rejected_before_signing(self._settings())

    def test_unsigned_build_never_signs_or_queries_the_product(self):
        result = self._run(None, profile="unsigned")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.log.exists())


if __name__ == "__main__":
    unittest.main()
