#!/usr/bin/env python3
"""Remove only exact empty preference files recorded by the completed synthetic child."""
import json
import plistlib
import sys
from pathlib import Path

names = json.loads(Path(sys.argv[1]).read_text())
assert names and all(isinstance(name, str) and "/" not in name and ".." not in name for name in names)
root = Path.home() / "Library" / "Preferences"
for name in names:
    path = root / (name + ".plist")
    if path.exists():
        assert plistlib.loads(path.read_bytes()) == {}, f"Refusing to delete nonempty synthetic domain: {name}"
        path.unlink()
assert all(not (root / (name + ".plist")).exists() for name in names)
print(f"Cleaned {len(names)} exact synthetic preference domains after child exit")
