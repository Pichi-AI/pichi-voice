#!/bin/sh
set -eu

exec /usr/bin/python3 -S "$SRCROOT/scripts/dev/asr-baseline-inputs.py" stage
