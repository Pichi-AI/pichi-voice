#!/usr/bin/env python3
"""Write en/ru Localizable.strings for the named keys beside a raw test executable.

A swiftc-built probe has no compiled app catalog, so Bundle.main cannot localize generated
titles. This copies the real catalog entries (the macOS/"other" device variation when present).
Usage: write_localized_title_resources.py <executable-directory> <key> [<key> ...]
"""
from pathlib import Path
import json, sys

catalog = json.loads(Path('Sources/Fluid/Localization/Localizable.xcstrings').read_text())
root = Path(sys.argv[1])
for language in ['en', 'ru']:
    folder = root / (language + '.lproj')
    folder.mkdir(parents=True, exist_ok=True)
    lines = []
    for key in sys.argv[2:]:
        localization = catalog['strings'][key]['localizations'][language]
        unit = localization.get('stringUnit') or localization['variations']['device']['other']['stringUnit']
        lines.append(json.dumps(key, ensure_ascii=False) + ' = ' + json.dumps(unit['value'], ensure_ascii=False) + ';\n')
    (folder / 'Localizable.strings').write_text(''.join(lines))
