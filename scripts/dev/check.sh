#!/usr/bin/env bash
set -euo pipefail

pichi_root="$(git rev-parse --show-toplevel)"
cd "$pichi_root"
git diff --check
for pichi_script in scripts/dev/*.sh; do
    bash -n "$pichi_script"
done
python3 - <<'PY'
import ast
import pathlib
import tomllib

root = pathlib.Path('.')
with (root / '.codex/config.toml').open('rb') as stream:
    tomllib.load(stream)
with (root / '.codex/environments/environment.toml').open('rb') as stream:
    environment = tomllib.load(stream)
assert environment['version'] == 1
assert environment['name'] == 'Pichi Voice'
assert environment['setup']['script']
for action in environment.get('actions', []):
    assert action['name'] and action['command']
    assert action['icon'] in ('tool', 'run', 'debug', 'test')
    assert action.get('platform', 'darwin') in ('darwin', 'linux', 'win32')
ast.parse((root / '.codex/hooks/session-start.py').read_text())
print('Repository configuration and script syntax passed.')
PY
for pichi_path in AGENTS.md .codex/config.toml .codex/hooks/session-start.py \
    .codex/environments/environment.toml docs/development/codex.md \
    docs/development/upstream.md scripts/dev/check.sh; do
    if git check-ignore --no-index -q "$pichi_path"; then
        printf 'Required shared file is ignored: %s\n' "$pichi_path" >&2
        exit 1
    fi
done
python3 -S scripts/dev/check-localization.py
python3 -S Tests/test_localization_catalog.py
python3 -S Tests/test_build_identity.py
python3 -S Tests/test_macos_regression.py
python3 -S Tests/test_signed_build_product_path.py
python3 -S Tests/test_asr_baseline_inputs.py
python3 -S Tests/test_standalone_regression.py
python3 -S Tests/test_local_api_live_harness.py
bash Tests/run_upstream_sync_tests.sh
printf '%s\n' 'Portable checks passed. macOS build and audio checks are separate.'
