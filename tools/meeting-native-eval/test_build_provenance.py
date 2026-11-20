#!/usr/bin/env python3
"""Synthetic checks of the vendored package provenance used by build.py; no build runs."""
from pathlib import Path
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from provenance import gigaam_package_inputs, transcribe_inputs, vendored_inputs, vendored_revision  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
PIN = 'b7fb7f7dea8a2469e6335d95a61b8f36d0dc83b2'


class RevisionTests(unittest.TestCase):
    def test_the_tracked_record_names_the_pinned_revision(self):
        record = ROOT / 'Vendor/onnxruntime-swift-package-manager/PICHI_VENDORING.md'
        self.assertEqual(vendored_revision(record.read_text()), PIN)

    def test_one_revision_may_be_repeated(self):
        self.assertEqual(vendored_revision(f'Exported `{PIN}`, still `{PIN}`.'), PIN)

    def test_a_record_without_a_revision_is_refused(self):
        with self.assertRaises(ValueError):
            vendored_revision('Exported from the default branch.')

    def test_malformed_revisions_do_not_count(self):
        for text in (f'`{PIN[:-1]}`', f'`{PIN.upper()}`', PIN, f'`{PIN}0`', f'`{PIN[:-1]}g`'):
            with self.subTest(text=text), self.assertRaises(ValueError):
                vendored_revision(text)

    def test_two_different_revisions_are_refused(self):
        with self.assertRaises(ValueError):
            vendored_revision(f'`{PIN}` and `{"0" * 40}`')


class InputTests(unittest.TestCase):
    def package(self, root, headers=('b.h', 'a.h'), record=True):
        (root / 'objectivec/include').mkdir(parents=True)
        (root / 'Package.swift').write_text('// manifest\n')
        if record:
            (root / 'PICHI_VENDORING.md').write_text(f'`{PIN}`\n')
        for name in headers:
            (root / 'objectivec/include' / name).write_text('// header\n')
        return root

    def test_inputs_are_the_manifest_the_record_and_sorted_headers(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = self.package(Path(temporary))
            self.assertEqual([path.relative_to(root).as_posix() for path in vendored_inputs(root)],
                             ['Package.swift', 'PICHI_VENDORING.md', 'objectivec/include/a.h', 'objectivec/include/b.h'])

    def test_a_package_without_headers_or_record_is_refused(self):
        for headers, record in (((), True), (('a.h',), False)):
            with self.subTest(headers=headers, record=record), tempfile.TemporaryDirectory() as temporary:
                root = self.package(Path(temporary), headers=headers, record=record)
                with self.assertRaises(ValueError):
                    vendored_inputs(root)

    def test_the_vendored_package_is_complete(self):
        inputs = vendored_inputs(ROOT / 'Vendor/onnxruntime-swift-package-manager')
        self.assertIn('onnxruntime.h', [path.name for path in inputs])


class TranscribeInputTests(unittest.TestCase):
    def package(self, root, sources=('B.swift', 'A.swift'), skip=None):
        files = ['Package.swift', 'UPSTREAM.md', 'Artifacts/manifest.json', 'Artifacts/TranscribeCpp.xcframework.zip',
                 *('Sources/TranscribeCpp/' + name for name in sources)]
        for name in files:
            if name == skip:
                continue
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('x\n')
        return root

    def test_inputs_are_the_manifest_the_pin_the_archive_and_sorted_sources(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = self.package(Path(temporary))
            self.assertEqual([path.relative_to(root).as_posix() for path in transcribe_inputs(root)],
                             ['Package.swift', 'UPSTREAM.md', 'Artifacts/manifest.json',
                              'Artifacts/TranscribeCpp.xcframework.zip',
                              'Sources/TranscribeCpp/A.swift', 'Sources/TranscribeCpp/B.swift'])

    def test_a_missing_pin_or_archive_is_refused(self):
        for skip in ('UPSTREAM.md', 'Artifacts/manifest.json', 'Artifacts/TranscribeCpp.xcframework.zip', 'Package.swift'):
            with self.subTest(skip=skip), tempfile.TemporaryDirectory() as temporary:
                with self.assertRaises(ValueError):
                    transcribe_inputs(self.package(Path(temporary), skip=skip))

    def test_a_package_without_swift_sources_is_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaises(ValueError):
                transcribe_inputs(self.package(Path(temporary), sources=()))

    def test_the_vendored_packages_are_complete(self):
        names = [path.name for path in transcribe_inputs(ROOT / 'Vendor/TranscribeCpp')]
        self.assertIn('TranscribeCpp.xcframework.zip', names)
        self.assertIn('Session.swift', names)
        self.assertEqual([path.name for path in gigaam_package_inputs(ROOT / 'Vendor/PichiGigaAM')], ['Package.swift'])

    def test_a_gigaam_package_without_a_manifest_is_refused(self):
        with tempfile.TemporaryDirectory() as temporary, self.assertRaises(ValueError):
            gigaam_package_inputs(Path(temporary))


if __name__ == '__main__':
    unittest.main()
