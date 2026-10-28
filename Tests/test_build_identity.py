"""Portable guards for installation identity across upstream project merges."""
import pathlib
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
PROJECT = ROOT / 'Fluid.xcodeproj/project.pbxproj'


def validate_application_identity(project):
    application_configurations = 0
    for block in re.findall(r'buildSettings = \{(.*?)\n\s*\};', project, re.DOTALL):
        assignments = re.findall(r'^\s*(\w+) = ([^\n;]+);', block, re.MULTILINE)
        settings = dict(assignments)
        module = settings.get('PRODUCT_MODULE_NAME')
        if module not in {'FluidVoice', 'FluidVoice_Debug'}:
            continue
        application_configurations += 1
        for key in ('PRODUCT_BUNDLE_IDENTIFIER', 'PRODUCT_NAME', 'MARKETING_VERSION'):
            values = [value for candidate, value in assignments if candidate == key]
            if len(values) != 1:
                raise ValueError(f'{module}: expected one {key} assignment, found {len(values)}')
        debug = module == 'FluidVoice_Debug'
        expected = {
            'PRODUCT_BUNDLE_IDENTIFIER': '"$(PICHI_BUNDLE_IDENTIFIER)' + ('.debug"' if debug else '"'),
            'PRODUCT_NAME': '"$(PICHI_PRODUCT_NAME)' + (' Debug"' if debug else '"'),
            'ASSETCATALOG_COMPILER_APPICON_NAME': '"$(PICHI_APP_ICON)"',
        }
        for key, value in expected.items():
            if settings.get(key) != value:
                raise ValueError(f'{module}: {key} must use the distribution configuration')
    if application_configurations != 2:
        raise ValueError(f'Expected Debug and Release application configurations, found {application_configurations}')


class BuildIdentityTests(unittest.TestCase):
    def testMobileRegenerationPreservesSourcesAndIncludesNewPlatformFiles(self):
        with tempfile.TemporaryDirectory(prefix='pichi-mobile-membership-') as directory:
            root = pathlib.Path(directory)
            for relative in [
                'Fluid.xcodeproj/project.pbxproj', 'scripts/dev/update-mobile-project.py',
                'Sources/Mobile/shared-sources.txt', 'Sources/Fluid/Branding/brand-package.json',
                'Sources/Mobile/Info.plist', 'Sources/Mobile/Version.xcconfig',
            ]:
                destination = root / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / relative, destination)
            for folder in ['Sources/Mobile', 'Sources/MobileActivity', 'Tests/MobileUITests', 'Tests/MobileIntegrationTests']:
                (root / folder).mkdir(parents=True, exist_ok=True)
                for source in (ROOT / folder).glob('*.swift'):
                    (root / folder / source.name).touch()
            (root / 'Fluid.xcodeproj/xcshareddata/xcschemes').mkdir(parents=True)
            for name in ['MobileRegisteredModelInferenceTests.swift', 'MeetingOwnerVoiceProfileTests.swift']:
                if (ROOT / 'Tests/FluidDictationIntegrationTests' / name).is_file():
                    destination = root / 'Tests/FluidDictationIntegrationTests' / name
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    destination.touch()
            generator = root / 'scripts/dev/update-mobile-project.py'
            subprocess.run([sys.executable, '-S', str(generator)], check=True, capture_output=True)
            regenerated = (root / 'Fluid.xcodeproj/project.pbxproj').read_text()
            self.assertEqual(regenerated, PROJECT.read_text(), 'Regeneration must preserve every existing source registration')
            for source in ['MeetingLocationService.swift', 'MeetingLocationSettingsContent.swift',
                           'AccountSessionService.swift', 'PrivateProfileService.swift']:
                self.assertIn(source, regenerated)
            (root / 'Sources/Mobile/MobileAccount.swift').touch()
            subprocess.run([sys.executable, '-S', str(generator)], check=True, capture_output=True)
            updated = (root / 'Fluid.xcodeproj/project.pbxproj').read_text()
            self.assertIn('Mobile file Sources/Mobile/MobileAccount.swift', updated)
            self.assertIn('Mobile build Sources/Mobile/MobileAccount.swift', updated)

    def testMergedProjectPreservesBothDistributionIdentities(self):
        validate_application_identity(PROJECT.read_text())

    def testMobilePrivacyPurposeStringsHaveEnglishAndRussianCopy(self):
        info = plistlib.loads((ROOT / 'Sources/Mobile/Info.plist').read_bytes())
        for key in ['NSMicrophoneUsageDescription', 'NSSpeechRecognitionUsageDescription',
                    'NSLocationWhenInUseUsageDescription', 'NSLocalNetworkUsageDescription']:
            with self.subTest(key=key):
                self.assertIsInstance(info.get(key), str)
                self.assertGreater(len(info[key].strip()), 20)
                for language in ['en', 'ru']:
                    resource = ROOT / f'Sources/Mobile/Resources/{language}.lproj/InfoPlist.strings'
                    match = re.search(r'"' + key + r'"\s*=\s*"([^"\n]+)";', resource.read_text())
                    self.assertIsNotNone(match, f'{language} needs a localized privacy purpose for {key}')
                    self.assertGreater(len(match.group(1).strip()), 20)
                    if language == 'en':
                        self.assertEqual(match.group(1), info[key])
                    else:
                        self.assertRegex(match.group(1), '[А-Яа-яЁё]')

    def testMobileAppAndExtensionShareReleaseVersionOverrides(self):
        project = PROJECT.read_text()
        version_id = re.search(r'(\w+) /\* Mobile file Sources/Mobile/Version.xcconfig \*/', project).group(1)
        for label in ['Mobile Debug', 'Mobile Release', 'Mobile activity Debug', 'Mobile activity Release']:
            configuration = re.search(r'/\* ' + label + r' \*/ = \{([^\n]+)', project).group(1)
            self.assertIn('baseConfigurationReference = ' + version_id + ';', configuration)
            self.assertNotIn('CURRENT_PROJECT_VERSION =', configuration)
            self.assertNotIn('MARKETING_VERSION =', configuration)
        for relative in ['Sources/Mobile/Info.plist', 'Sources/MobileActivity/Info.plist']:
            info = plistlib.loads((ROOT / relative).read_bytes())
            self.assertEqual(info['CFBundleVersion'], '$(CURRENT_PROJECT_VERSION)')
            self.assertEqual(info['CFBundleShortVersionString'], '$(MARKETING_VERSION)')
        defaults = (ROOT / 'Sources/Mobile/Version.xcconfig').read_text()
        self.assertRegex(defaults, r'(?m)^CURRENT_PROJECT_VERSION = [1-9][0-9]*$')
        self.assertRegex(defaults, r'(?m)^MARKETING_VERSION = 0\.1\.0$')

    def testDuplicateUpstreamIdentityAndReleaseSettingsAreRejected(self):
        project = PROJECT.read_text()
        for key, value in [
            ('PRODUCT_BUNDLE_IDENTIFIER', 'com.FluidApp.app.debug'),
            ('PRODUCT_NAME', '"FluidVoice Debug"'),
            ('MARKETING_VERSION', '"9.9.9"'),
        ]:
            with self.subTest(key=key):
                needle = 'PRODUCT_MODULE_NAME = FluidVoice_Debug;'
                corrupted = project.replace(needle, f'{needle}\n\t\t\t\t{key} = {value};', 1)
                with self.assertRaisesRegex(ValueError, f'expected one {key}'):
                    validate_application_identity(corrupted)

    def testSingleHardcodedUpstreamIdentityIsRejected(self):
        corrupted = PROJECT.read_text().replace(
            'PRODUCT_BUNDLE_IDENTIFIER = "$(PICHI_BUNDLE_IDENTIFIER)";',
            'PRODUCT_BUNDLE_IDENTIFIER = com.FluidApp.app;',
            1,
        )
        with self.assertRaisesRegex(ValueError, 'must use the distribution configuration'):
            validate_application_identity(corrupted)


if __name__ == '__main__':
    unittest.main()
