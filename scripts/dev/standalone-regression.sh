#!/usr/bin/env bash
set -euo pipefail

pichi_root="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$pichi_root"
exec python3 -S scripts/dev/standalone-regression.py "$@"
