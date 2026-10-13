import importlib.util
import pathlib
import unittest

path = pathlib.Path(__file__).resolve().parents[1] / 'scripts/dev/check-xcode-build-settings.py'
spec = importlib.util.spec_from_file_location('xcode_build_settings', path)
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class BuildSettingsTests(unittest.TestCase):
    def test_silent_brand_identity_override_is_rejected(self):
        source = '''buildSettings = {
            PRODUCT_BUNDLE_IDENTIFIER = "$(PICHI_BUNDLE_IDENTIFIER)";
            PRODUCT_NAME = "$(PICHI_PRODUCT_NAME)";
            MARKETING_VERSION = "1.6.11";
            PRODUCT_BUNDLE_IDENTIFIER = com.FluidApp.app;
        };'''
        with self.assertRaisesRegex(ValueError, 'Duplicate build setting PRODUCT_BUNDLE_IDENTIFIER'):
            checker.validate(source)

    def test_configurations_and_conditional_settings_have_separate_keys(self):
        source = '''buildSettings = {
            PRODUCT_NAME = "$(PICHI_PRODUCT_NAME)";
            CODE_SIGN_IDENTITY = "";
            "CODE_SIGN_IDENTITY[sdk=macosx*]" = "Apple Development";
        };
        buildSettings = {
            PRODUCT_NAME = "$(PICHI_PRODUCT_NAME) Debug";
        };'''
        self.assertEqual(checker.validate(source), 2)

    def test_missing_blocks_do_not_silently_pass(self):
        with self.assertRaises(ValueError):
            checker.validate('invalid project')


if __name__ == '__main__':
    unittest.main()
