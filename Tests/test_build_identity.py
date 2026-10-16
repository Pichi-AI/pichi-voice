"""Portable guards for installation identity across upstream project merges."""
import pathlib
import re
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
    def testMergedProjectPreservesBothDistributionIdentities(self):
        validate_application_identity(PROJECT.read_text())

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
