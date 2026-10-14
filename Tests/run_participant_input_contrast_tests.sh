#!/bin/sh
set -eu
task_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# The production-derived UI probe owns prohibited activation and hidden windows.
# It never launches the app or sends physical input to the user's GUI.
PICHI_UI_CONTRAST_OUTPUT_DIR="${PICHI_PARTICIPANT_INPUT_OUTPUT_DIR:-$task_repo_dir/.build/participant-input-tests}"
export PICHI_UI_CONTRAST_OUTPUT_DIR
exec /bin/sh "$task_repo_dir/Tests/run_ui_contrast_tests.sh" --participant-input-only
