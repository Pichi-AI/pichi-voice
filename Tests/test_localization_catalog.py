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

    def testPositionalReorderingKeepsArgumentTypesAndLiteralPercentCopyIsNotAFormat(self):
        self.assertEqual(check.signature('%lld entries for %@'), check.signature('%2$@ has %1$lld entries'))
        self.assertEqual(check.signature('15% faster'), {})
        self.assertEqual(check.signature('Progress: %lld%%'), {1: 'lld'})


if __name__ == '__main__':
    unittest.main()
