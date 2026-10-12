"""Portable negative checks for localization safety invariants."""
import importlib.util
import json
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('localization_check', ROOT / 'scripts/dev/check-localization.py')
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


class LocalizationCatalogValidationTests(unittest.TestCase):
    def catalog(self, russian='%lld запись', forms=None):
        unit = lambda value: {'stringUnit': {'state': 'translated', 'value': value}}
        russian_node = unit(russian) if forms is None else {'variations': {'plural': {key: unit(value) for key, value in forms.items()}}}
        return {'version': '1.0', 'sourceLanguage': 'en', 'strings': {'%lld entries': {'localizations': {
            'en': unit('%lld entries'), 'ru': russian_node,
        }}}}

    def validate(self, catalog):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / 'Localizable.xcstrings'
            path.write_text(json.dumps(catalog))
            return check.validate_catalog(path)

    def testRejectsChangedIntegerArgumentType(self):
        with self.assertRaisesRegex(ValueError, 'changes format arguments'):
            self.validate(self.catalog(russian='%@ записей'))

    def testRejectsMissingRussianPluralForm(self):
        with self.assertRaisesRegex(ValueError, 'plural is missing'):
            self.validate(self.catalog(forms={'one': '%lld запись', 'many': '%lld записей', 'other': '%lld записи'}))

    def testRejectsMissingRussianUnitAndDuplicateCatalogKeys(self):
        catalog = self.catalog()
        del catalog['strings']['%lld entries']['localizations']['ru']
        with self.assertRaisesRegex(ValueError, 'missing English or Russian'):
            self.validate(catalog)
        with self.assertRaisesRegex(ValueError, 'Duplicate JSON key'):
            json.loads('{"strings": {}, "strings": {}}', object_pairs_hook=check.unique_object)

    def testMissingNamedOnboardingNavigationCopyIsCaughtButDataFieldsRemainData(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / 'WelcomeView.swift').write_text('cinematicFooter(continueTitle: "Continue", skipTitle: "Skip")\nOnboardingPillButtonConfiguration(title: "Back")\n')
            (root / 'OnboardingModelData.swift').write_text('ModelDescriptor(title: "My private model")\nlet modelID = "Skip"\n')
            missing = check.missing_literal_keys({'Continue': {}, 'Back': {}}, source_root=root)
            self.assertEqual(set(missing), {'Skip'})
            self.assertEqual(missing['Skip'], ['WelcomeView.swift:1'])
            self.assertEqual(check.missing_literal_keys({'Continue': {}, 'Back': {}, 'Skip': {}}, source_root=root), {})

    def testPositionalReorderingKeepsArgumentTypesAndLiteralPercentCopyIsNotAFormat(self):
        self.assertEqual(check.signature('%lld entries for %@'), check.signature('%2$@ has %1$lld entries'))
        self.assertEqual(check.signature('15% faster'), {})
        self.assertEqual(check.signature('Progress: %lld%%'), {1: 'lld'})

    def testMissingSettingsRowCopyIsCaughtWithoutScanningProviderDataFields(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / 'SettingsView.swift').write_text('optionToggleRow(title: "Copy to Clipboard", description: "Keep a local copy.")\nsettingsToggleRow(title: "Return to Starting Field", description: "Use the first field.", footnote: "Off by default.")\n')
            (root / 'AISettingsView+AdvancedSettings.swift').write_text('promptEditorConfigRow(title: "AI provider", description: "Verified providers only.")\n')
            (root / 'ProviderDescriptor.swift').write_text('ProviderDescriptor(title: "Private model", description: "Private provider text", footnote: "Private notes")\n')
            translated = {key: {} for key in ['Copy to Clipboard', 'Return to Starting Field', 'AI provider', 'Use the first field.']}
            missing = check.missing_literal_keys(translated, source_root=root)
            self.assertEqual(set(missing), {'Keep a local copy.', 'Off by default.', 'Verified providers only.'})
            translated.update({key: {} for key in missing})
            self.assertEqual(check.missing_literal_keys(translated, source_root=root), {})


if __name__ == '__main__':
    unittest.main()
