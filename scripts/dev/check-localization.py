#!/usr/bin/env python3
"""Validate committed Apple catalogs and explicit UI-key coverage without a Mac runtime."""
import argparse
import collections
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
CATALOGS = ROOT / 'Sources/Fluid/Localization'
# No whitespace flag: ordinary UI copy such as '15% faster' is not a printf template.
FORMAT = re.compile(r'%(?:(\d+)\$)?[-+#0]*(?:\d+)?(?:\.\d+)?(ll|l|h|z)?([diuoxXfFeEgGaAcCsSp@%])')
SUBSTITUTION_NAME = re.compile(r'[^%@\s]+')
FORMAT_SPECIFIER = re.compile(r'(?:ll|l|h|z)?[diuoxX]|l?[fFeEgGaAcs]|[CSp@]')
# Match complete named references first. Otherwise %#@count@ looks like an
# ordinary %@ argument and hides the actual numeric quantity contract.
FORMAT_TOKEN = re.compile(r'%(?:(?P<position>\d+)\$)?#@(?P<name>[^%@\s]+)@|(?P<ordinary>' + FORMAT.pattern + ')')
NAMED_PREFIX = re.compile(r'%(?:\d+\$)?#@')
LANGUAGE = re.compile(r'^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$')
EXPLICIT = re.compile(r'\b(?:PichiLocalization\.(?:text|format)|AppBrand\.(?:text|format)|Text|Button|Label|Toggle|Picker|Menu|TextField|SecureField|GroupBox|Section|ProgressView|Link)\(\s*("(?:[^"\\]|\\.)*")')

# These named arguments are declared trusted onboarding UI copy. Restrict the audit
# to these presentation sources; generic title/model/user-data fields elsewhere are not UI keys.
ONBOARDING_NAMED_COPY = re.compile(r'\b(?:skipTitle|continueTitle|title)\s*:\s*("(?:[^"\\]|\\.)*")')

# These settings presentation files declare row labels and descriptions as trusted UI copy.
# Do not apply this to stored model/provider/prompt descriptors, whose fields are user data.
SETTINGS_NAMED_COPY = re.compile(r'\b(?:title|description|footnote)\s*:\s*("(?:[^"\\]|\\.)*")')


def settings_copy_source(path):
    return path.name in {'SettingsView.swift', 'AISettingsView+AdvancedSettings.swift'}


def onboarding_copy_source(path):
    return path.name in {
        'WelcomeView.swift', 'OnboardingTryoutStepView.swift', 'OnboardingAIEnhancementStepView.swift',
        'OnboardingCleanupExampleCarousel.swift', 'OnboardingComponents.swift',
    }


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f'Duplicate JSON key: {key!r}')
        result[key] = value
    return result


def signature(value, substitutions=None, initial_argument=1):
    arguments = {}
    next_argument = initial_argument
    for token in FORMAT_TOKEN.finditer(value):
        name = token.group('name')
        if name is not None:
            if substitutions is None or name not in substitutions:
                raise ValueError(f'Missing named substitution declaration: {name!r}')
            declaration = substitutions[name]
            index = declaration['argNum']
            position = token.group('position')
            if position and int(position) != index:
                raise ValueError(f'Named substitution {name!r} changes its argument position')
            kind = declaration['formatSpecifier']
            if not position:
                next_argument += 1
        else:
            ordinary = token.group('ordinary')
            if NAMED_PREFIX.match(ordinary):
                raise ValueError(f'Malformed named substitution reference in {value!r}')
            position, length, conversion = FORMAT.fullmatch(ordinary).groups()
            if conversion == '%':
                continue
            index = int(position) if position else next_argument
            if not position:
                next_argument += 1
            kind = (length or '') + conversion
        # Preserve C integer length and argument position; translated reordering must be positional.
        if index in arguments and arguments[index] != kind:
            raise ValueError(f'Conflicting format types in {value!r}')
        arguments[index] = kind
    return arguments


def leaves(node, language):
    if 'stringUnit' in node:
        unit = node['stringUnit']
        if not isinstance(unit.get('value'), str):
            raise ValueError('String unit has no string value')
        yield unit
    for axis, variants in node.get('variations', {}).items():
        if not isinstance(variants, dict) or not variants:
            raise ValueError(f'Empty {axis} variation')
        if axis == 'plural':
            required = {'other'}
            if language == 'ru':
                required |= {'one', 'few', 'many'}
            if not required.issubset(variants):
                raise ValueError(f'{language} plural is missing {required - variants.keys()}')
        for variant in variants.values():
            yield from leaves(variant, language)


def has_plural(node):
    variations = node.get('variations', {})
    return ('plural' in variations
            or any(has_plural(variant) for variants in variations.values() for variant in variants.values())
            or any(has_plural(substitution) for substitution in node.get('substitutions', {}).values()))


def node_contract(node, language, quantity=None):
    """Validate each formatting scope, including quantities not printed in its leaves."""
    substitutions = node.get('substitutions', {})
    if not isinstance(substitutions, dict):
        raise ValueError('Named substitutions must be an object')
    children = []
    for name, declaration in substitutions.items():
        if not isinstance(name, str) or not SUBSTITUTION_NAME.fullmatch(name) or not isinstance(declaration, dict):
            raise ValueError(f'Invalid named substitution declaration: {name!r}')
        position = declaration.get('argNum')
        specifier = declaration.get('formatSpecifier')
        if type(position) is not int or position < 1:
            raise ValueError(f'Named substitution {name!r} has no positive integer argNum')
        if not isinstance(specifier, str) or not FORMAT_SPECIFIER.fullmatch(specifier):
            raise ValueError(f'Named substitution {name!r} has an invalid formatSpecifier')
        child = node_contract(declaration, language, quantity=(position, specifier))
        if has_plural(declaration) and specifier[-1] not in 'diuoxXfFeEgGaA':
            raise ValueError(f'Plural substitution {name!r} requires a numeric formatSpecifier')
        children.append((position, specifier, child))

    units = list(leaves(node, language))
    if not units:
        raise ValueError(f'Empty localization formatting scope for {language}')
    expected = None
    referenced = set()
    for unit in units:
        if language in {'en', 'ru'} and unit.get('state') != 'translated':
            raise ValueError(f'String unit is not translated in {language}')
        # Plural leaves may omit the quantity or refer to other global call
        # arguments. Their implicit formatting starts at the quantity position.
        arguments = signature(unit['value'], substitutions, initial_argument=quantity[0] if quantity else 1)
        if quantity and quantity[0] in arguments and arguments[quantity[0]] != quantity[1]:
            raise ValueError(f'Plural quantity changes format arguments in {language}: {unit["value"]!r}')
        actual = tuple(sorted(arguments.items()))
        if expected is None:
            expected = actual
        elif actual != expected:
            raise ValueError(f'Variation changes format arguments in {language}: {unit["value"]!r}')
        referenced.update(token.group('name') for token in FORMAT_TOKEN.finditer(unit['value']) if token.group('name'))
    if referenced != substitutions.keys():
        raise ValueError(f'Unreferenced named substitution declarations: {sorted(substitutions.keys() - referenced)}')
    # Keep scope signatures separate for translation comparisons, while every
    # use of a global call argument must agree throughout the substitution tree.
    combined = dict(expected)
    for _, _, child in children:
        for position, kind in child[2]:
            if position in combined and combined[position] != kind:
                raise ValueError(f'Nested substitution changes format arguments at position {position} in {language}')
            combined[position] = kind
    # Names are local resource identifiers. Argument positions and types remain
    # the contract even when a translator reorders or renames a substitution.
    return expected, tuple(sorted(children)), tuple(sorted(combined.items()))


def validate_catalog(path):
    data = json.loads(path.read_text(), object_pairs_hook=unique_object)
    if data.get('version') != '1.0' or data.get('sourceLanguage') != 'en':
        raise ValueError('Expected English-source Apple String Catalog version 1.0')
    strings = data.get('strings')
    if not isinstance(strings, dict):
        raise ValueError('Catalog has no strings object')
    plurals = 0
    for key, entry in strings.items():
        if not key or entry.get('shouldTranslate') is False:
            continue
        localizations = entry.get('localizations', {})
        if not {'en', 'ru'}.issubset(localizations):
            raise ValueError(f'{key!r} is missing English or Russian')
        expected = node_contract(localizations['en'], 'en')
        for language, node in localizations.items():
            if not LANGUAGE.fullmatch(language):
                raise ValueError(f'Invalid BCP 47 catalog language {language!r}')
            if node_contract(node, language) != expected:
                raise ValueError(f'{key!r} changes format arguments in {language}')
        if has_plural(localizations['ru']):
            plurals += 1
    return strings, plurals


def missing_literal_keys(strings, source_root=None):
    missing = collections.defaultdict(list)
    source_root = source_root or ROOT / 'Sources/Fluid'
    for path in sorted(source_root.rglob('*.swift')):
        source = path.read_text()
        patterns = [EXPLICIT]
        if onboarding_copy_source(path):
            patterns.append(ONBOARDING_NAMED_COPY)
        if settings_copy_source(path):
            patterns.append(SETTINGS_NAMED_COPY)
        for match in (match for pattern in patterns for match in pattern.finditer(source)):
            try:
                # Swift interpolation and multiline/raw literals require Xcode's compiler extraction.
                key = json.loads(match.group(1))
            except json.JSONDecodeError:
                continue
            if key.strip() and key not in strings:
                line = source.count('\n', 0, match.start()) + 1
                relative = path.relative_to(ROOT) if path.is_relative_to(ROOT) else path.relative_to(source_root)
                missing[key].append(f'{relative}:{line}')
    return missing


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--catalog', type=pathlib.Path, help='Validate one catalog; skip source coverage.')
    args = parser.parse_args()
    paths = [args.catalog] if args.catalog else sorted(CATALOGS.glob('*.xcstrings'))
    if not paths:
        raise ValueError('No Apple String Catalogs found')
    for path in paths:
        strings, plurals = validate_catalog(path)
        if not args.catalog and path.stem == 'Localizable':
            missing = missing_literal_keys(strings)
            if missing:
                details = '\n'.join(f'{key!r}: {", ".join(locations)}' for key, locations in missing.items())
                raise ValueError(f'Explicit UI keys are missing from Localizable.xcstrings:\n{details}')
        print(f'{path.name}: {len(strings)} keys, complete English/Russian units, {plurals} native plural entries; format arguments preserved.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError) as error:
        print(f'Localization validation failed: {error}', file=sys.stderr)
        sys.exit(1)
