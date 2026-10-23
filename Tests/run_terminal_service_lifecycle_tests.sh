#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p "$PWD/.build"
task_test_dir=$(mktemp -d "$PWD/.build/terminal-service-lifecycle.XXXXXX")
trap 'rm -rf "$task_test_dir"' EXIT HUP INT TERM
task_evidence_base="$PWD/private_assets/test-artifacts/terminal-service-lifecycle"
mkdir -p "$task_evidence_base"
task_evidence_dir=$(mktemp -d "$task_evidence_base/run.XXXXXX")
echo "Evidence: $task_evidence_dir"
for task_mode in swift5 swift6-mainactor; do
    if [ "$task_mode" = swift5 ]; then
        set -- -swift-version 5
    else
        set -- -swift-version 6 -default-isolation MainActor -strict-concurrency=complete -warnings-as-errors
    fi
    xcrun swiftc -parse-as-library "$@" -module-cache-path "$task_test_dir/ModuleCache" \
        Sources/Fluid/Services/TerminalService.swift Tests/TerminalServiceLifecycleTests.swift \
        -o "$task_test_dir/tests" > "$task_evidence_dir/$task_mode-compile.log" 2>&1 || {
        cat "$task_evidence_dir/$task_mode-compile.log"; exit 1;
    }
    python3 - "$task_test_dir/tests" "$task_evidence_dir" "$task_mode" <<'PY_RUN' || {
import json, os, signal, subprocess, sys, threading, time
from pathlib import Path
binary, evidence, mode = sys.argv[1], Path(sys.argv[2]), sys.argv[3]
# A new session proves ownership of every test group. Keep its leader unreaped
# until cleanup has finished, including when a lifecycle regression hangs.
process = subprocess.Popen([binary, str(evidence / (mode + '-fixtures with spaces'))],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
finished = threading.Event()
def copy_output():
    with (evidence / (mode + '-run.log')).open('wb') as output:
        while chunk := process.stdout.read(65536):
            output.write(chunk)
    finished.set()
reader = threading.Thread(target=copy_output, daemon=True)
reader.start()
def interrupt(number, frame):
    raise SystemExit(128 + number)
for number in (signal.SIGTERM, signal.SIGINT):
    signal.signal(number, interrupt)
rows = []
timed_out = False
try:
    timed_out = not finished.wait(30)
finally:
    # Only groups in this newly created test session can receive a signal.
    # No broad process-name or age-based cleanup is used.
    pids = subprocess.check_output(['/bin/ps', '-axo', 'pid='], text=True).split()
    groups = set()
    for value in pids:
        pid = int(value)
        try:
            if os.getsid(pid) == process.pid:
                group = os.getpgid(pid)
                rows.append({'pid': pid, 'group': group})
                groups.add(group)
        except ProcessLookupError:
            pass
    for number in (signal.SIGTERM, signal.SIGKILL):
        for group in groups:
            try:
                os.killpg(group, number)
            except ProcessLookupError:
                pass
        if number == signal.SIGTERM:
            time.sleep(0.3)
    code = process.wait(timeout=5)
    reader.join(timeout=5)
    for row in rows:
        try:
            os.kill(row['pid'], 0)
            row['absentAfterCleanup'] = False
        except ProcessLookupError:
            row['absentAfterCleanup'] = True
    (evidence / (mode + '-supervisor-cleanup.json')).write_text(json.dumps({
        'sessionLeader': process.pid, 'timedOut': timed_out, 'exitCode': code,
        'processes': rows, 'readerJoined': not reader.is_alive()}, indent=2) + '\n')
if timed_out or code != 0 or reader.is_alive() or any(not row['absentAfterCleanup'] for row in rows):
    raise SystemExit(1)
PY_RUN
        cat "$task_evidence_dir/$task_mode-run.log"; exit 1;
    }
    cat "$task_evidence_dir/$task_mode-run.log"
done
