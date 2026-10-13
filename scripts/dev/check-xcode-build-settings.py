#!/usr/bin/env python3
"""Reject duplicate keys in the project's formatted Xcode buildSettings blocks.

Git can merge an upstream version bump beside downstream product settings and
silently duplicate keys. Xcode then uses the last product/bundle identity.
"""
import pathlib
import re
import sys

BLOCK = re.compile(r'\bbuildSettings\s*=\s*\{(.*?)^\s*\};', re.M | re.S)
KEY = re.compile(r'^\s*("[^"\n]+"|[A-Za-z_][A-Za-z0-9_]*)\s*=', re.M)


def validate(source):
    blocks = list(BLOCK.finditer(source))
    if not blocks:
        raise ValueError('No formatted buildSettings blocks found')
    for block in blocks:
        seen = {}
        for match in KEY.finditer(block.group(1)):
            key = match.group(1).strip('"')
            line = source.count('\n', 0, block.start(1) + match.start()) + 1
            if key in seen:
                raise ValueError(f'Duplicate build setting {key} at lines {seen[key]} and {line}')
            seen[key] = line
    return len(blocks)


if __name__ == '__main__':
    project = pathlib.Path(__file__).resolve().parents[2] / 'Fluid.xcodeproj/project.pbxproj'
    try:
        count = validate(project.read_text())
        print(f'Xcode build settings: {count} blocks without duplicate keys.')
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
