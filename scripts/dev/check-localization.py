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
LANGUAGE = re.compile(r'^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$')
EXPLICIT = re.compile(r'\b(?:PichiLocalization\.(?:text|format)|AppBrand\.(?:text|format)|Text|Button|Label|Toggle|Picker|Menu|TextField|SecureField|GroupBox|Section|ProgressView|Link)\(\s*("(?:[^"\\]|\\.)*")')

# These named arguments are declared trusted onboarding UI copy. Restrict the audit
# to these presentation sources; generic title/model/user-data fields elsewhere are not UI keys.
ONBOARDING_NAMED_COPY = re.compile(r'\b(?:skipTitle|continueTitle|title)\s*:\s*("(?:[^"\\]|\\.)*")')


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


def signature(value):
    arguments = {}
    next_argument = 1
    for match in FORMAT.finditer(value):
        position, length, conversion = match.groups()
        if conversion == '%':
            continue
        index = int(position) if position else next_argument
        if not position:
            next_argument += 1
        # Preserve C integer length and argument position; translated reordering must be positional.
        kind = (length or '') + conversion
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
        english = list(leaves(localizations['en'], 'en'))
        if not english:
            raise ValueError(f'{key!r} has no English value')
        expected = signature(english[0]['value'])
        for language, node in localizations.items():
            if not LANGUAGE.fullmatch(language):
                raise ValueError(f'Invalid BCP 47 catalog language {language!r}')
            units = list(leaves(node, language))
            if not units:
                raise ValueError(f'{key!r} has an empty localization for {language}')
            for unit in units:
                if language in {'en', 'ru'} and unit.get('state') != 'translated':
                    raise ValueError(f'{key!r} is not translated in {language}')
                if signature(unit['value']) != expected:
                    raise ValueError(f'{key!r} changes format arguments in {language}: {unit["value"]!r}')
        if 'plural' in localizations['ru'].get('variations', {}):
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
