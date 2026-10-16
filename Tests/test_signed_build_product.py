"""Exercise build.sh's signed profile without Xcode, certificates or codesign."""
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
IDENTITY_HASH = '0123456789ABCDEF0123456789ABCDEF01234567'
TEAM = 'TESTTEAM42'
ENTITLEMENTS = '<?xml version="1.0"?><plist><dict><key>test</key><true/></dict></plist>\n'
MOCK_TOOL = r'''import json
import os
import pathlib
import sys
import tempfile

root = pathlib.Path(os.environ['MOCK_ROOT'])
command = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / 'commands.jsonl').open('a') as stream:
    stream.write(json.dumps([command, args]) + '\n')
if command == 'security':
    if args != ['find-identity', '-v', '-p', 'codesigning']:
        sys.exit('Unexpected security invocation')
    if not os.environ.get('MOCK_NO_IDENTITY'):
        print('  1) 0123456789ABCDEF0123456789ABCDEF01234567 "Apple Development: Synthetic Test"')
elif command == 'xcodebuild':
    if '-showBuildSettings' in args:
        sys.stdout.write((root / 'settings.json').read_text())
        sys.exit(int(os.environ.get('MOCK_SETTINGS_STATUS', '0')))
    if os.environ.get('MOCK_BUILD_STATUS'):
        sys.exit(int(os.environ['MOCK_BUILD_STATUS']))
    if not os.environ.get('MOCK_MISSING_PRODUCT'):
        framework = pathlib.Path(os.environ['MOCK_APP_PATH']) / 'Contents/Frameworks/CTranscribe.framework'
        (framework / 'Versions/A/Resources').mkdir(parents=True)
        (framework / 'Versions/A/CTranscribe').write_text('synthetic binary')
        (framework / 'CTranscribe').write_text('old root binary')
        (framework / 'Resources').mkdir()
        helper = pathlib.Path(os.environ['MOCK_APP_PATH']) / 'Contents/Helpers/fv-serve'
        helper.parent.mkdir(parents=True)
        helper.write_text('synthetic helper')
        helper.chmod(0o755)
elif command == 'mktemp':
    if len(args) != 1 or not args[0].endswith('/fluidvoice-entitlements.XXXXXX'):
        sys.exit('Unexpected mktemp invocation')
    descriptor, name = tempfile.mkstemp(prefix='fluidvoice-entitlements.', dir=root)
    os.close(descriptor)
    print(name)
elif command == 'codesign':
    if '--display' in args:
        sys.stdout.write(os.environ['MOCK_ENTITLEMENTS'])
    if '--force' in args and '--entitlements' in args:
        entitlements = pathlib.Path(args[args.index('--entitlements') + 1])
        (root / 'preserved-entitlements.xml').write_text(entitlements.read_text())
    if os.environ.get('MOCK_VERIFY_STATUS') and '--verify' in args:
        sys.exit(int(os.environ['MOCK_VERIFY_STATUS']))
else:
    sys.exit('Unexpected mock tool')
'''


class SignedBuildProductTests(unittest.TestCase):
    def setUp(self):
        scratch = ROOT / '.build'
        scratch.mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix='signed-build-tests.', dir=scratch)
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.project = self.root / 'Project With Spaces'
        self.project.mkdir()
        shutil.copyfile(ROOT / 'build.sh', self.project / 'build.sh')
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        for command in ('security', 'xcodebuild', 'codesign', 'mktemp'):
            executable = self.bin / command
            executable.write_text(f'#!{sys.executable}\n' + MOCK_TOOL)
            executable.chmod(0o755)
        self.derived_data = self.project / 'Derived Data With Spaces'
        self.build_dir = self.derived_data / 'Configured Products/Debug'
        self.app = self.build_dir / 'Custom Dictation Debug.app'
        self.settings = [self.target_settings(), self.target_settings('UnrelatedApp')]
        self.environment = {
            **os.environ,
            'PATH': f'{self.bin}{os.pathsep}{os.environ["PATH"]}',
            'MOCK_ROOT': str(self.root),
            'MOCK_APP_PATH': str(self.app),
            'MOCK_ENTITLEMENTS': ENTITLEMENTS,
            'FLUIDVOICE_DEVELOPMENT_TEAM': TEAM,
            'FLUIDVOICE_DERIVED_DATA_PATH': str(self.derived_data),
            'TMPDIR': str(self.root),
        }
        # A caller's unrelated mock flags must not alter this fixture.
        for key in ('MOCK_NO_IDENTITY', 'MOCK_SETTINGS_STATUS', 'MOCK_BUILD_STATUS',
                    'MOCK_MISSING_PRODUCT', 'MOCK_VERIFY_STATUS'):
            self.environment.pop(key, None)

    def target_settings(self, target='fluid'):
        return {
            'target': target,
            'buildSettings': {
                'PRODUCT_TYPE': 'com.apple.product-type.application',
                'TARGET_BUILD_DIR': str(self.build_dir if target == 'fluid' else self.derived_data / 'Other Products'),
                'FULL_PRODUCT_NAME': self.app.name if target == 'fluid' else 'Unrelated App Debug.app',
            },
        }

    def run_build(self, settings=None, **overrides):
        (self.root / 'settings.json').write_text(
            json.dumps(self.settings) if settings is None else settings)
        result = subprocess.run(
            ['bash', str(self.project / 'build.sh'), 'public'],
            cwd=self.root,
            env={**self.environment, **overrides},
            text=True, capture_output=True, check=False,
        )
        log = self.root / 'commands.jsonl'
        self.calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        return result

    def assert_no_postprocessing(self):
        self.assertFalse(any(command == 'codesign' for command, _ in self.calls))

    def test_configured_product_with_spaces_uses_matching_build_parameters(self):
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        expected = [
            '-project', 'Fluid.xcodeproj', '-scheme', 'Fluid', '-configuration', 'Debug',
            '-destination', 'platform=macOS', '-derivedDataPath', str(self.derived_data),
            'build', f'DEVELOPMENT_TEAM={TEAM}',
        ]
        builds = [args for command, args in self.calls if command == 'xcodebuild']
        self.assertEqual(builds, [expected + ['-showBuildSettings', '-json'], expected])
        framework = self.app / 'Contents/Frameworks/CTranscribe.framework'
        self.assertEqual((framework / 'Versions/Current').readlink(), pathlib.Path('A'))
        self.assertEqual((framework / 'CTranscribe').readlink(), pathlib.Path('Versions/Current/CTranscribe'))
        self.assertEqual((framework / 'Resources').readlink(), pathlib.Path('Versions/Current/Resources'))
        signing = [args for command, args in self.calls if command == 'codesign']
        self.assertEqual([args[-1] for args in signing], [str(framework), str(self.app), str(self.app), str(self.app)])
        self.assertEqual(signing[0], [
            '--force', '--sign', IDENTITY_HASH, '--options', 'runtime', '--timestamp=none',
            '--preserve-metadata=identifier,requirements,flags', str(framework),
        ])
        self.assertEqual(signing[1], ['--display', '--entitlements', ':-', str(self.app)])
        self.assertEqual(signing[2][:-3], signing[0][:-1])
        self.assertEqual(signing[2][-3], '--entitlements')
        self.assertEqual(signing[3], ['--verify', '--deep', '--strict', str(self.app)])
        self.assertEqual((self.root / 'preserved-entitlements.xml').read_text(), ENTITLEMENTS)
        self.assertFalse(pathlib.Path(signing[2][-2]).exists(), 'Temporary entitlements were not removed')
        self.assertIn(f'Build product: {self.app}', result.stdout)

    def test_stale_legacy_product_is_not_selected_or_modified(self):
        self.app = self.build_dir / 'Pichi Voice Debug.app'
        self.environment['MOCK_APP_PATH'] = str(self.app)
        self.settings = [self.target_settings('UnrelatedApp'), self.target_settings()]
        legacy = self.derived_data / 'Build/Products/Debug/FluidVoice Debug.app'
        legacy_framework = legacy / 'Contents/Frameworks/CTranscribe.framework'
        (legacy_framework / 'Versions/A/Resources').mkdir(parents=True)
        (legacy_framework / 'Versions/A/CTranscribe').write_text('stale versioned binary')
        (legacy_framework / 'Resources').mkdir()
        sentinel = legacy_framework / 'CTranscribe'
        sentinel.write_text('stale legacy product')
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(sentinel.read_text(), 'stale legacy product')
        self.assertFalse(sentinel.is_symlink())
        self.assertFalse((legacy_framework / 'Versions/Current').exists())
        self.assertTrue(all(args[-1] == str(self.app) or args[-1] == str(self.app / 'Contents/Frameworks/CTranscribe.framework')
                            for command, args in self.calls if command == 'codesign'))

    def test_settings_command_failure_does_not_build_or_sign(self):
        result = self.run_build(MOCK_SETTINGS_STATUS='65')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Unable to read signed build settings from Xcode.', result.stderr)
        self.assertEqual(sum(command == 'xcodebuild' for command, _ in self.calls), 1)
        self.assert_no_postprocessing()

    def test_unavailable_ambiguous_or_invalid_settings_do_not_build_or_sign(self):
        valid = self.target_settings()
        invalid_settings = (
            ('malformed JSON', 'not JSON'),
            ('missing target', json.dumps([self.target_settings('OtherApp')])),
            ('ambiguous target', json.dumps([valid, valid])),
            ('missing build settings', json.dumps([{'target': 'fluid'}])),
            ('missing product name', json.dumps([{'target': 'fluid', 'buildSettings': {'TARGET_BUILD_DIR': str(self.build_dir)}}])),
            ('missing build directory', json.dumps([{'target': 'fluid', 'buildSettings': {'FULL_PRODUCT_NAME': self.app.name}}])),
            ('unresolved name', json.dumps([{'target': 'fluid', 'buildSettings': {'TARGET_BUILD_DIR': str(self.build_dir), 'FULL_PRODUCT_NAME': '$(PRODUCT_NAME).app'}}])),
            ('unresolved directory', json.dumps([{'target': 'fluid', 'buildSettings': {'TARGET_BUILD_DIR': '${BUILT_PRODUCTS_DIR}', 'FULL_PRODUCT_NAME': self.app.name}}])),
            ('relative directory', json.dumps([{'target': 'fluid', 'buildSettings': {'TARGET_BUILD_DIR': 'Products/Debug', 'FULL_PRODUCT_NAME': self.app.name}}])),
            ('invalid app name', json.dumps([{'target': 'fluid', 'buildSettings': {'TARGET_BUILD_DIR': str(self.build_dir), 'FULL_PRODUCT_NAME': '../Wrong.app'}}])),
        )
        for label, settings in invalid_settings:
            with self.subTest(label=label):
                (self.root / 'commands.jsonl').unlink(missing_ok=True)
                result = self.run_build(settings)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Unable to resolve signed application product:', result.stderr)
                self.assertEqual(sum(command == 'xcodebuild' for command, _ in self.calls), 1)
                self.assert_no_postprocessing()

    def test_missing_resolved_product_does_not_use_stale_legacy_product(self):
        legacy = self.derived_data / 'Build/Products/Debug/FluidVoice Debug.app'
        legacy.mkdir(parents=True)
        result = self.run_build(MOCK_MISSING_PRODUCT='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f'Signed build product is missing: {self.app}', result.stderr)
        self.assert_no_postprocessing()

    def test_compilation_failure_stops_before_postprocessing(self):
        result = self.run_build(MOCK_BUILD_STATUS='65')
        self.assertEqual(result.returncode, 65)
        self.assert_no_postprocessing()

    def test_strict_signature_verification_failure_remains_fatal(self):
        result = self.run_build(MOCK_VERIFY_STATUS='42')
        self.assertEqual(result.returncode, 42)
        self.assertEqual(self.calls[-1], ['codesign', ['--verify', '--deep', '--strict', str(self.app)]])

    def test_team_override_still_requires_installed_development_identity(self):
        result = self.run_build(MOCK_NO_IDENTITY='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('no Apple Development signing identity was found', result.stderr)
        self.assertFalse(any(command == 'xcodebuild' for command, _ in self.calls))
        self.assert_no_postprocessing()


if __name__ == '__main__':
    unittest.main()
