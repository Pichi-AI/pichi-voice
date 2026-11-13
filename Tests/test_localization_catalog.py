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
    def testNativeAlertMenuAndUpdaterActionsRequireCatalogCoverageWithoutInspectingUserData(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / 'Native.swift').write_text('''
alert.messageText = "No Updates"
presentFloatingPrompt(
    title: "No Updates", message: message, actions: actions)
alert.informativeText = "Nothing to install."
alert.addButton(withTitle: "OK")
NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
FloatingPromptAction(
    title: "Install Now") {}
NSMenuItem(
    title: "Settings", action: nil, keyEquivalent: "")
alert.informativeText = error.localizedDescription
NSMenuItem(title: device.name, action: nil, keyEquivalent: "")
''')
            expected = {'No Updates', 'Nothing to install.', 'OK', 'Settings', 'Install Now'}
            self.assertEqual(set(check.missing_literal_keys({}, source_root=root)), expected)
            self.assertEqual(check.missing_literal_keys(dict.fromkeys(expected, {}), source_root=root), {})

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

    def substitution_catalog(self):
        unit = lambda value: {'stringUnit': {'state': 'translated', 'value': value}}
        localizations = {}
        for language, forms in {
            'en': {'one': 'day streak', 'other': 'days in a row'},
            'ru': {'one': 'день подряд', 'few': 'дня подряд', 'many': 'дней подряд', 'other': 'дней подряд'},
        }.items():
            localizations[language] = {
                **unit('%#@streakDays@'),
                'substitutions': {'streakDays': {
                    'argNum': 1, 'formatSpecifier': 'lld',
                    'variations': {'plural': {name: unit(value) for name, value in forms.items()}},
                }},
            }
        return {'version': '1.0', 'sourceLanguage': 'en', 'strings': {
            'stats.streak.unit': {'localizations': localizations},
        }}

    def substitution_node(self, catalog, language='ru'):
        return catalog['strings']['stats.streak.unit']['localizations'][language]

    def testUnitOnlyPluralSubstitutionRetainsItsUnprintedQuantityContract(self):
        catalog = self.substitution_catalog()
        strings, plurals = self.validate(catalog)
        self.assertIn('stats.streak.unit', strings)
        self.assertEqual(plurals, 1)
        node = self.substitution_node(catalog)
        self.assertEqual(check.signature(node['stringUnit']['value'], node['substitutions']), {1: 'lld'})

    def testNamedReferencesCanReorderAlongsideOrdinaryPositionalArguments(self):
        catalog = self.substitution_catalog()
        english = self.substitution_node(catalog, 'en')
        english['stringUnit']['value'] = '%1$#@streakDays@ for %2$@'
        russian = self.substitution_node(catalog)
        russian['substitutions']['дни'] = russian['substitutions'].pop('streakDays')
        russian['stringUnit']['value'] = '%2$@: %1$#@дни@'
        self.validate(catalog)
        self.assertEqual(check.signature(russian['stringUnit']['value'], russian['substitutions']), {1: 'lld', 2: '@'})

    def testEscapedNamedReferenceIsLiteralAndConsumesNoArgument(self):
        self.assertEqual(check.signature('%%#@notADeclaration@ %lld'), {1: 'lld'})

    def testRejectsMissingNestedRussianPluralForm(self):
        catalog = self.substitution_catalog()
        del self.substitution_node(catalog)['substitutions']['streakDays']['variations']['plural']['few']
        with self.assertRaisesRegex(ValueError, 'plural is missing'):
            self.validate(catalog)

    def testRejectsUntranslatedNestedPluralUnit(self):
        catalog = self.substitution_catalog()
        self.substitution_node(catalog)['substitutions']['streakDays']['variations']['plural']['few']['stringUnit']['state'] = 'new'
        with self.assertRaisesRegex(ValueError, 'not translated in ru'):
            self.validate(catalog)

    def testRejectsChangedNamedQuantityTypeOrPosition(self):
        for field, value in [('formatSpecifier', 'd'), ('formatSpecifier', '@'), ('argNum', 2)]:
            with self.subTest(field=field, value=value):
                catalog = self.substitution_catalog()
                self.substitution_node(catalog)['substitutions']['streakDays'][field] = value
                with self.assertRaisesRegex(ValueError, 'changes format arguments|numeric formatSpecifier'):
                    self.validate(catalog)

    def testRejectsInvalidNamedArgumentNumberAndSpecifier(self):
        for field, value in [('argNum', True), ('argNum', 0), ('argNum', -1), ('argNum', '1'),
                             ('formatSpecifier', '%lld'), ('formatSpecifier', 'lld%@'), ('formatSpecifier', ''),
                             ('formatSpecifier', 'llf'), ('formatSpecifier', 'l@')]:
            with self.subTest(field=field, value=value):
                catalog = self.substitution_catalog()
                self.substitution_node(catalog)['substitutions']['streakDays'][field] = value
                with self.assertRaisesRegex(ValueError, 'argNum|formatSpecifier'):
                    self.validate(catalog)

    def testRejectsMissingDeclarationAndUnknownRootReference(self):
        for mutation in ['missing', 'unknown']:
            with self.subTest(mutation=mutation):
                catalog = self.substitution_catalog()
                node = self.substitution_node(catalog)
                if mutation == 'missing':
                    del node['substitutions']
                else:
                    node['stringUnit']['value'] = '%#@otherDays@'
                with self.assertRaisesRegex(ValueError, 'Missing named substitution declaration'):
                    self.validate(catalog)

    def testRejectsUnusedDeclarationAndInvalidNames(self):
        catalog = self.substitution_catalog()
        self.substitution_node(catalog)['stringUnit']['value'] = 'дней подряд'
        with self.assertRaisesRegex(ValueError, 'Unreferenced named substitution'):
            self.validate(catalog)
        for name in ['', 'invalid name', 'invalid@name', 'invalid%name']:
            with self.subTest(name=name):
                catalog = self.substitution_catalog()
                declarations = self.substitution_node(catalog)['substitutions']
                declarations[name] = declarations.pop('streakDays')
                with self.assertRaisesRegex(ValueError, 'Invalid named substitution declaration'):
                    self.validate(catalog)

    def testRejectsMalformedOrInconsistentPositionalNamedReference(self):
        for value in ['%#@streakDays', '%#@invalid name@', '%2$#@streakDays@']:
            with self.subTest(value=value):
                catalog = self.substitution_catalog()
                self.substitution_node(catalog)['stringUnit']['value'] = value
                with self.assertRaisesRegex(ValueError, 'Malformed named substitution|argument position'):
                    self.validate(catalog)

    def testRejectsFormatArgumentDriftInsideNestedPluralScope(self):
        catalog = self.substitution_catalog()
        self.substitution_node(catalog)['substitutions']['streakDays']['variations']['plural']['few']['stringUnit']['value'] = '%lld дня подряд'
        with self.assertRaisesRegex(ValueError, 'Variation changes format arguments'):
            self.validate(catalog)

    def testNestedPluralMayPrintQuantityWhenEveryLocalePreservesThatContract(self):
        catalog = self.substitution_catalog()
        for language in ['en', 'ru']:
            node = self.substitution_node(catalog, language)
            for variant in node['substitutions']['streakDays']['variations']['plural'].values():
                variant['stringUnit']['value'] = '%lld ' + variant['stringUnit']['value']
        self.validate(catalog)

    def testRejectsPrintingNumericQuantityAsObjectEvenWhenAllLocalesAgree(self):
        for position, value in [(1, '%@ '), (2, '%@ '), (2, '%2$@ ')]:
            with self.subTest(position=position, value=value):
                catalog = self.substitution_catalog()
                for language in ['en', 'ru']:
                    node = self.substitution_node(catalog, language)
                    declaration = node['substitutions']['streakDays']
                    declaration['argNum'] = position
                    for variant in declaration['variations']['plural'].values():
                        variant['stringUnit']['value'] = value + variant['stringUnit']['value']
                with self.assertRaisesRegex(ValueError, 'Plural quantity changes format arguments'):
                    self.validate(catalog)

    def testNestedPluralCanUseGlobalArgumentPositionsAndItsImplicitQuantity(self):
        catalog = self.substitution_catalog()
        for language in ['en', 'ru']:
            node = self.substitution_node(catalog, language)
            node['stringUnit']['value'] = '%1$@ %2$#@streakDays@'
            declaration = node['substitutions']['streakDays']
            declaration['argNum'] = 2
            for variant in declaration['variations']['plural'].values():
                variant['stringUnit']['value'] = '%1$@: %lld ' + variant['stringUnit']['value']
        self.validate(catalog)

    def testRejectsGlobalArgumentTypeConflictBetweenRootAndNestedPlural(self):
        catalog = self.substitution_catalog()
        for language in ['en', 'ru']:
            node = self.substitution_node(catalog, language)
            node['stringUnit']['value'] = '%1$lld %2$#@streakDays@'
            declaration = node['substitutions']['streakDays']
            declaration['argNum'] = 2
            for variant in declaration['variations']['plural'].values():
                variant['stringUnit']['value'] = '%1$@: %lld ' + variant['stringUnit']['value']
        with self.assertRaisesRegex(ValueError, 'Nested substitution changes format arguments at position 1'):
            self.validate(catalog)

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
