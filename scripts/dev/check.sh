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
    docs/development/upstream.md scripts/dev/check.sh scripts/dev/check-diarization-repeatability.py; do
    if git check-ignore --no-index -q "$pichi_path"; then
        printf 'Required shared file is ignored: %s\n' "$pichi_path" >&2
        exit 1
    fi
done
python3 -S scripts/dev/check-localization.py
python3 -S scripts/dev/check-transcribe-sdk.py
python3 -S scripts/dev/update-mobile-project.py --check
python3 -S Tests/test_localization_catalog.py
python3 -S Tests/test_build_identity.py
python3 -S scripts/dev/check-xcode-build-settings.py
python3 -S Tests/test_xcode_build_settings.py
python3 -B -S Tests/test_sensitive_topic_packaging.py
python3 -B -S Tests/test_mobile_framework_metadata.py
python3 -S Tests/test_macos_regression.py
python3 -S Tests/test_signed_build_product_path.py
python3 -S Tests/test_asr_baseline_inputs.py
python3 -S Tests/test_standalone_regression.py
python3 -S Tests/test_local_api_live_harness.py
python3 -S Tests/test_command_profile_quality_probe.py
python3 -S Tests/run_diarization_repeatability_tests.py
python3 -S Tests/test_signed_build_product.py
python3 -S Tests/test_meeting_diarization_eval.py
python3 -S Tests/test_lint_changed.py
python3 -B -S -m unittest discover -s tools -p test_meeting_asr_text_eval.py
python3 -S tools/meeting-native-eval/test_batch_preflight.py
python3 -B -S tools/meeting-native-eval/test_weak_score.py
python3 -B -S tools/meeting-native-eval/test_migrate_replay_v2.py
python3 -B -S tools/meeting-native-eval/test_report.py
bash Tests/run_upstream_sync_tests.sh
printf '%s\n' 'Portable checks passed. macOS build and audio checks are separate.'
