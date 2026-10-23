#!/usr/bin/env python3
"""Remove exact disposable preference files recorded by the completed synthetic child."""
import json
import re
import sys
from pathlib import Path

names = json.loads(Path(sys.argv[1]).read_text())
assert names and all(isinstance(name, str) and re.fullmatch(
    r"[^/]+(?:\.private-profile\.[a-f0-9]{64}|\.synthetic-guest)", name
) and ".." not in name for name in names)
root = Path.home() / "Library" / "Preferences"
for name in names:
    # These domains were created with synthetic identities for this exact child,
    # which has exited. Their generated data is disposable even if Foundation
    # flushes an older retained suite after the test's in-process cleanup.
    (root / (name + ".plist")).unlink(missing_ok=True)
assert all(not (root / (name + ".plist")).exists() for name in names)
print(f"Cleaned {len(names)} exact synthetic preference domains after child exit")
