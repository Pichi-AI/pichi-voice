#!/usr/bin/env python3
"""Portable runner regressions execute synthetic scripts, never application probes."""

from contextlib import redirect_stdout
import errno
import importlib.util
import io
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("standalone_regression", ROOT / "scripts/dev/standalone-regression.py")
RUNNER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = RUNNER
SPEC.loader.exec_module(RUNNER)


class StandaloneRunnerTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="standalone root with spaces ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "Tests").mkdir()

    def probe(self, name, body="exit 0", interpreter="sh", requires_ui=False):
        extension = "py" if interpreter == "python3" else "sh"
        filename = f"Tests/run_{name}_tests.{extension}"
        shebang = {"sh": "#!/bin/sh", "bash": "#!/usr/bin/env bash", "python3": "#!/usr/bin/env python3"}[interpreter]
        (self.root / filename).write_text(f"{shebang}\n{body}\n")
        return RUNNER.Probe(filename, interpreter, requires_ui)

    def run_probes(self, probes, **options):
        with redirect_stdout(io.StringIO()):
            status, report = RUNNER.run_suite(self.root, probes, revision="synthetic-revision", dirty=True, **options)
        directory = Path(report["artifactDirectory"])
        self.assertEqual(json.loads((directory / "summary.json").read_text()), report)
        self.assertTrue((directory / "summary.txt").is_file())
        self.assertEqual(report["workingTree"], "dirty")
        for row in report["results"]:
            self.assertTrue((directory / row["log"]).is_file())
        return status, report, directory

    def test_current_registry_covers_every_standalone_and_only_update_prompt_opts_in(self):
        RUNNER.validate_registry(ROOT)
        pending = [probe for probe in RUNNER.PROBES if probe.name == "meeting_pending_speech"]
        self.assertEqual(len(pending), 1)
        self.assertEqual(pending[0].interpreter, "sh")
        self.assertFalse(pending[0].requires_ui)
        self.assertEqual(len(RUNNER.PROBES), 72)
        self.assertEqual(sum(probe.interpreter == "sh" for probe in RUNNER.PROBES), 56)
        self.assertEqual(sum(probe.interpreter == "python3" for probe in RUNNER.PROBES), 8)
        self.assertEqual(sum(probe.interpreter == "bash" for probe in RUNNER.PROBES), 8)
        admitted = [probe for probe in RUNNER.PROBES if probe.name == "admitted_history_writes"]
        self.assertEqual(len(admitted), 1)
        self.assertEqual(admitted[0].interpreter, "sh")
        self.assertFalse(admitted[0].requires_ui)
        activity = [probe for probe in RUNNER.PROBES if probe.name == "meeting_capture_activity"]
        self.assertEqual(len(activity), 1)
        self.assertEqual(activity[0].interpreter, "sh")
        self.assertFalse(activity[0].requires_ui)
        attribution = [probe for probe in RUNNER.PROBES if probe.name == "meeting_speaker_attribution"]
        self.assertEqual(len(attribution), 1)
        self.assertEqual(attribution[0].interpreter, "python3")
        self.assertFalse(attribution[0].requires_ui)
        self.assertEqual([probe.name for probe in RUNNER.PROBES if probe.requires_ui], ["update_prompt"])
        self.assertTrue({"fluid_serve", "file_export", "file_error_localization", "ui_contrast", "participant_input_contrast", "file_transcript_relative_date", "command_ui_localization", "clipboard_backup_reproduction", "settings_owned_copy", "settings_viewport", "native_window_appearance", "local_api_live_harness", "meeting_audio_scope", "upstream_sync", "diarization_repeatability", "hotkey_initialization"}
                        .issubset({probe.name for probe in RUNNER.PROBES}))

    def test_failure_is_counted_and_later_probes_still_run(self):
        probes = [self.probe("first", 'echo first; echo stderr >&2'),
                  self.probe("failure", "exit 7"), self.probe("last", "echo last")]
        status, report, directory = self.run_probes(probes)
        self.assertEqual(status, 1)
        self.assertEqual(report["status"], "FAIL")
        self.assertEqual(report["counts"], {"total": 3, "passed": 2, "failed": 1, "skipped": 0})
        self.assertEqual([row["exitCode"] for row in report["results"]], [0, 7, 0])
        self.assertIn("stderr", (directory / "first.log").read_text())
        self.assertEqual((directory / "last.log").read_text(), "last\n")

    def test_optional_ui_is_skipped_without_activation(self):
        probes = [self.probe("normal"), self.probe("ui", "touch activated", requires_ui=True)]
        status, report, directory = self.run_probes(probes)
        self.assertEqual(status, 0)
        self.assertEqual(report["counts"], {"total": 2, "passed": 1, "failed": 0, "skipped": 1})
        self.assertIsNone(report["results"][1]["exitCode"])
        self.assertIn("--include-ui", (directory / "ui.log").read_text())
        self.assertFalse((self.root / "activated").exists())

    def test_ui_requires_explicit_flag_even_when_selected_alone(self):
        probe = self.probe("ui", "touch activated", requires_ui=True)
        status, report, _ = self.run_probes([probe])
        self.assertEqual(status, 1)
        self.assertEqual(report["status"], "FAIL")
        self.assertEqual(report["counts"]["skipped"], 1)
        self.assertFalse((self.root / "activated").exists())
        status, report, _ = self.run_probes([probe], include_ui=True)
        self.assertEqual(status, 0)
        self.assertEqual(report["counts"]["passed"], 1)
        self.assertTrue((self.root / "activated").exists())

    def test_python_and_bash_are_invoked_with_their_own_interpreters(self):
        python = self.probe("python", 'from pathlib import Path\nprint("python OK")\nassert Path("Tests").is_dir()', interpreter="python3")
        bash = self.probe("bash", 'set -euo pipefail\nvalues=(alpha beta)\n[[ "${values[1]}" == beta ]]\necho "bash OK"', interpreter="bash")
        RUNNER.validate_registry(self.root, [python, bash])
        status, report, directory = self.run_probes([python, bash])
        self.assertEqual(status, 0)
        self.assertEqual(report["results"][0]["command"], [sys.executable, python.script])
        self.assertEqual(report["results"][1]["command"], ["/bin/bash", bash.script])
        self.assertEqual((directory / "python.log").read_text(), "python OK\n")
        self.assertEqual((directory / "bash.log").read_text(), "bash OK\n")

    def test_missing_registered_script_is_not_a_success(self):
        probe = self.probe("missing")
        (self.root / probe.script).unlink()
        status, report, _ = self.run_probes([probe])
        self.assertEqual(status, 1)
        self.assertEqual(report["counts"]["failed"], 1)
        self.assertEqual(report["results"][0]["reason"], "registered script missing")

    def test_process_launch_failure_is_recorded(self):
        probe = self.probe("launch")
        with patch.object(RUNNER, "run_owned_process", side_effect=FileNotFoundError("synthetic missing interpreter")):
            status, report, directory = self.run_probes([probe])
        self.assertEqual(status, 1)
        self.assertIsNone(report["results"][0]["exitCode"])
        self.assertIn("missing interpreter", (directory / "launch.log").read_text())

    def test_signal_exit_is_preserved(self):
        probe = self.probe("signal")
        with patch.object(RUNNER, "run_owned_process", return_value=(-15, None)):
            status, report, _ = self.run_probes([probe])
        self.assertEqual(status, 1)
        self.assertEqual(report["results"][0]["exitCode"], -15)

    def test_interruption_records_failure_and_remaining_skips(self):
        probes = [self.probe("first"), self.probe("interrupted"), self.probe("last")]
        with patch.object(RUNNER, "run_owned_process", side_effect=[(0, None), KeyboardInterrupt()]):
            status, report, _ = self.run_probes(probes)
        self.assertEqual(status, 130)
        self.assertEqual(report["counts"], {"total": 3, "passed": 1, "failed": 1, "skipped": 1})
        self.assertEqual(report["results"][1]["runnerExitCode"], 130)
        self.assertIsNone(report["results"][1]["exitCode"])
        self.assertEqual(report["results"][2]["reason"], "not run after interruption")

    def worker_probe(self, *, wait=True):
        worker = self.root / "worker.py"
        os.mkfifo(self.root / "worker-release")
        worker.write_text('import os, signal\nfrom pathlib import Path\n'
                          'signal.signal(signal.SIGTERM, signal.SIG_IGN)\n'
                          'Path("worker-group").write_text(str(os.getpgrp()))\n'
                          'Path("worker-started").touch()\n'
                          'with open("worker-release") as gate: gate.read(1)\n'
                          'Path("escaped-worker").touch()\n')
        command = f"{shlex.quote(sys.executable)} {shlex.quote(str(worker))} &\n"
        command += 'while [ ! -f worker-started ]; do sleep 0.01; done\n'
        command += "wait" if wait else "exit 0"
        return self.probe("descendant", command)

    def assert_worker_joined(self):
        group = int((self.root / "worker-group").read_text())
        self.assertFalse(RUNNER.live_process_group(group))
        # Release is attempted only AFTER cleanup returns. Any surviving reader
        # could now write, so ENXIO proves the worker cannot resume its operation.
        with self.assertRaises(OSError) as failure:
            descriptor = os.open(self.root / "worker-release", os.O_WRONLY | os.O_NONBLOCK)
            try:
                os.write(descriptor, b"x")
            finally:
                os.close(descriptor)
        self.assertEqual(failure.exception.errno, errno.ENXIO)
        self.assertFalse((self.root / "escaped-worker").exists())

    def verify_real_signal_cleanup(self, number):
        probe = self.worker_probe()
        signal_sent = threading.Event()

        def interrupt_when_started():
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                if (self.root / "worker-started").exists():
                    signal_sent.set()
                    os.kill(os.getpid(), number)
                    return
                time.sleep(0.01)

        sender = threading.Thread(target=interrupt_when_started, daemon=True)
        sender.start()
        try:
            with patch.object(RUNNER, "CANCEL_GRACE_SECONDS", 0.05):
                status, report, directory = self.run_probes([probe, self.probe("later", "touch later-executed")])
        finally:
            sender.join(timeout=4)
        self.assertTrue(signal_sent.is_set())
        self.assertEqual(status, 128 + number, (directory / "descendant.log").read_text())
        self.assertEqual(report["runnerExitCode"], 128 + number)
        self.assertIn(report["results"][0]["exitCode"], [-signal.SIGTERM, -signal.SIGKILL])
        self.assertEqual(report["counts"], {"total": 2, "passed": 0, "failed": 1, "skipped": 1})
        self.assertFalse((self.root / "later-executed").exists())
        self.assert_worker_joined()
        with RUNNER.run_lock(self.root):
            pass

    def test_absent_group_needs_no_external_inspection(self):
        with patch.object(RUNNER.os, "killpg", side_effect=ProcessLookupError), \
             patch.object(RUNNER.subprocess, "run") as inspection:
            self.assertFalse(RUNNER.live_process_group(123456))
        inspection.assert_not_called()

    def test_darwin_inspects_only_owned_group_and_ignores_only_zombies(self):
        for rows, expected in (("123456 Z\n", False), ("123456 Z\n123456 S\n", True)):
            with self.subTest(rows=rows), patch.object(RUNNER.sys, "platform", "darwin"), \
                 patch.object(RUNNER.os, "killpg"), \
                 patch.object(RUNNER.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, rows, "")) as inspection:
                self.assertEqual(RUNNER.live_process_group(123456), expected)
                self.assertEqual(inspection.call_args.args[0], ["ps", "-g", "123456", "-o", "pgid=", "-o", "stat="])
                self.assertEqual(inspection.call_args.kwargs["timeout"], 2)

    def test_signal_zero_permission_denied_requires_group_inspection(self):
        for code, rows, expected in ((1, "", False), (0, "123456 Z\n", False),
                                     (0, "123456 S\n", True)):
            with self.subTest(rows=rows), patch.object(RUNNER.sys, "platform", "darwin"), \
                 patch.object(RUNNER.os, "killpg", side_effect=PermissionError(errno.EPERM, "synthetic denied group")) as group_signal, \
                 patch.object(RUNNER.subprocess, "run", return_value=subprocess.CompletedProcess([], code, rows, "")) as inspection:
                self.assertEqual(RUNNER.live_process_group(123456), expected)
                group_signal.assert_called_once_with(123456, 0)
                inspection.assert_called_once_with(["ps", "-g", "123456", "-o", "pgid=", "-o", "stat="],
                                                   capture_output=True, text=True, timeout=2)

    def test_permission_denied_group_retains_marker_when_live_or_unobservable(self):
        class Process:
            pid = 123456
            returncode = 0
            def wait(self): return 0
        for inspection_options in (
            {"return_value": subprocess.CompletedProcess([], 0, "123456 S\n", "")},
            {"side_effect": subprocess.TimeoutExpired(["ps"], 2)},
        ):
            with self.subTest(inspection_options=inspection_options), \
                 patch.object(RUNNER.subprocess, "Popen", return_value=Process()), \
                 patch.object(RUNNER.os, "killpg", side_effect=PermissionError(errno.EPERM, "synthetic denied group")), \
                 patch.object(RUNNER.subprocess, "run", **inspection_options):
                # Each scenario has its own marker: a live or unobservable group
                # must prevent another probe from acquiring the build storage.
                status, report, _ = self.run_probes([self.probe("denied"), self.probe("later")])
                self.assertEqual(status, 1)
                self.assertEqual(report["counts"], {"total": 2, "passed": 0, "failed": 1, "skipped": 1})
                self.assertEqual(report["results"][0]["exitCode"], 0)
                self.assertTrue((self.root / ".build" / RUNNER.PROCESS_MARKER).exists())
                with self.assertRaises((ValueError, subprocess.TimeoutExpired)):
                    with RUNNER.run_lock(self.root):
                        self.fail("An inaccessible live group must retain ownership")
            # Synthetic marker only; no real process was created by this case.
            (self.root / ".build" / RUNNER.PROCESS_MARKER).unlink()

    def test_permission_denied_absent_group_releases_marker_after_child_reap(self):
        class Process:
            pid = 123456
            returncode = 0
            def wait(self): return 0
        with patch.object(RUNNER.subprocess, "Popen", return_value=Process()), \
             patch.object(RUNNER.os, "killpg", side_effect=PermissionError(errno.EPERM, "synthetic disappearing group")) as group_signal, \
             patch.object(RUNNER.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "", "")):
            status, report, _ = self.run_probes([self.probe("disappeared")])
        self.assertEqual(status, 0)
        self.assertEqual(report["results"][0]["exitCode"], 0)
        self.assertFalse((self.root / ".build" / RUNNER.PROCESS_MARKER).exists())
        self.assertTrue(all(call.args == (123456, 0) for call in group_signal.call_args_list))

    def test_zombie_only_descendants_do_not_fail_successful_probe(self):
        class Process:
            pid = 123456
            returncode = 0
            def wait(self): return 0
        with patch.object(RUNNER.subprocess, "Popen", return_value=Process()), \
             patch.object(RUNNER.os, "killpg") as group_signal, \
             patch.object(RUNNER.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "123456 Z\n", "")):
            status, report, _ = self.run_probes([self.probe("zombie")])
        self.assertEqual(status, 0)
        self.assertEqual(report["results"][0]["exitCode"], 0)
        self.assertFalse((self.root / ".build" / RUNNER.PROCESS_MARKER).exists())
        self.assertTrue(all(call.args == (123456, 0) for call in group_signal.call_args_list))

    def test_group_inspection_fails_closed_on_error_or_malformed_output(self):
        for code, rows, error in ((2, "", ""), (1, "", "ps failure"), (0, "unreadable", "")):
            with self.subTest(code=code, rows=rows), patch.object(RUNNER.os, "killpg"), \
                 patch.object(RUNNER.subprocess, "run", return_value=subprocess.CompletedProcess([], code, rows, error)):
                with self.assertRaises(OSError):
                    RUNNER.live_process_group(123456)

    def test_stalled_inspection_cannot_prevent_term_escalation_and_join(self):
        self.assert_stalled_inspection_cleanup()

    def test_stalled_inspection_does_not_signal_a_disappearing_group_twice(self):
        original_killpg = RUNNER.os.killpg
        killed_groups = set()
        repeated_kills = []

        def disappearing_group(group, number):
            if number == signal.SIGKILL and group in killed_groups:
                repeated_kills.append(group)
                raise PermissionError(errno.EPERM, "synthetic disappearing process group")
            result = original_killpg(group, number)
            if number == signal.SIGKILL:
                killed_groups.add(group)
            return result

        # Reproduce Darwin's disappearing-group error on every platform while
        # retaining a real TERM-ignoring worker and the existing join proofs.
        with patch.object(RUNNER.os, "killpg", side_effect=disappearing_group):
            self.assert_stalled_inspection_cleanup()
        self.assertTrue(killed_groups)
        self.assertFalse(repeated_kills)

    def assert_stalled_inspection_cleanup(self):
        probe = self.worker_probe()
        original_killpg = RUNNER.os.killpg
        original_live = RUNNER.live_process_group
        escalation = threading.Event()
        successfully_killed_groups = set()
        inspected_after_join = []
        sender = threading.Thread(target=lambda: (self.wait_for_worker(), os.kill(os.getpid(), signal.SIGTERM)), daemon=True)

        def observe_kill(group, number):
            result = original_killpg(group, number)
            if number == signal.SIGKILL:
                successfully_killed_groups.add(group)
                escalation.set()
            return result

        def unavailable_inspection(group):
            # The slow/unavailable inspector is reached only after KILL and
            # direct-child reap, never while a TERM-ignoring worker can write.
            self.assertTrue(escalation.is_set())
            with self.assertRaises(OSError) as failure:
                descriptor = os.open(self.root / "worker-release", os.O_WRONLY | os.O_NONBLOCK)
                os.close(descriptor)
            self.assertEqual(failure.exception.errno, errno.ENXIO)
            inspected_after_join.append(group)
            raise subprocess.TimeoutExpired(["ps"], 2)

        sender.start()
        try:
            with patch.object(RUNNER.os, "killpg", side_effect=observe_kill), \
                 patch.object(RUNNER, "live_process_group", side_effect=unavailable_inspection), \
                 patch.object(RUNNER, "CANCEL_GRACE_SECONDS", 0.05):
                status, report, _ = self.run_probes([probe, self.probe("later", "touch later-executed")])
        finally:
            sender.join(timeout=4)
            # Retain fallback cleanup if escalation failed. Once KILL succeeded,
            # do not signal a reaped PGID again: Darwin may return EPERM, and the
            # identifier could have been reused by an unrelated process group.
            group_file = self.root / "worker-group"
            if group_file.exists():
                group = int(group_file.read_text())
                if group not in successfully_killed_groups and original_live(group):
                    try:
                        original_killpg(group, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
        self.assertFalse(sender.is_alive())
        self.assertEqual(status, 143)
        self.assertTrue(inspected_after_join)
        row = report["results"][0]
        self.assertIn(row["exitCode"], [-signal.SIGTERM, -signal.SIGKILL])
        self.assertIn("timed out", row["cleanupError"])
        self.assertIn("timed out", row["inspectionError"])
        self.assertEqual(report["counts"], {"total": 2, "passed": 0, "failed": 1, "skipped": 1})
        self.assertFalse((self.root / "later-executed").exists())
        self.assertTrue((self.root / ".build" / RUNNER.PROCESS_MARKER).exists())
        self.assertFalse(original_live(inspected_after_join[0]))
        self.assert_worker_joined()
        with RUNNER.run_lock(self.root):
            pass
        self.assertFalse((self.root / ".build" / RUNNER.PROCESS_MARKER).exists())

    def test_successful_shell_with_orphan_and_inspector_timeout_still_joins(self):
        probe = self.worker_probe(wait=False)
        inspections = []
        original_live = RUNNER.live_process_group

        def unavailable_inspection(group):
            inspections.append(group)
            raise subprocess.TimeoutExpired(["ps"], 2)

        with patch.object(RUNNER, "live_process_group", side_effect=unavailable_inspection), \
             patch.object(RUNNER, "CANCEL_GRACE_SECONDS", 0.05):
            status, report, _ = self.run_probes([probe, self.probe("later", "touch later-executed")])
        self.assertEqual(status, 1)
        self.assertEqual(report["results"][0]["exitCode"], 0)
        self.assertIn("timed out", report["results"][0]["reason"])
        self.assertEqual(report["counts"], {"total": 2, "passed": 0, "failed": 1, "skipped": 1})
        self.assertFalse((self.root / "later-executed").exists())
        self.assertTrue((self.root / ".build" / RUNNER.PROCESS_MARKER).exists())
        self.assertFalse(original_live(inspections[0]))
        self.assert_worker_joined()
        with RUNNER.run_lock(self.root):
            pass

    def test_real_interrupt_joins_descendant_that_ignores_term(self):
        self.verify_real_signal_cleanup(signal.SIGINT)

    def test_real_term_joins_descendant_and_preserves_exit_143(self):
        self.verify_real_signal_cleanup(signal.SIGTERM)

    def wait_for_worker(self):
        deadline = time.monotonic() + 3
        while not (self.root / "worker-started").exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertTrue((self.root / "worker-started").exists())

    def test_int_during_popen_creation_is_deferred_until_owner_is_recorded(self):
        probe = self.worker_probe()
        original = RUNNER.subprocess.Popen

        def interrupt_in_constructor(*args, **options):
            process = original(*args, **options)
            if options.get("start_new_session"):
                self.wait_for_worker()
                os.kill(os.getpid(), signal.SIGINT)
            return process

        with patch.object(RUNNER.subprocess, "Popen", side_effect=interrupt_in_constructor), patch.object(RUNNER, "CANCEL_GRACE_SECONDS", 0.05):
            status, report, _ = self.run_probes([probe])
        self.assertEqual(status, 130)
        self.assertEqual(report["status"], "FAIL")
        self.assertNotIn("cleanupError", report["results"][0])
        self.assertNotIn("inspectionError", report["results"][0])
        self.assert_worker_joined()
        self.assertFalse((self.root / ".build" / RUNNER.PROCESS_MARKER).exists())

    def test_term_during_marker_write_is_deferred_then_joined(self):
        probe = self.worker_probe()
        original = RUNNER.owned_file
        delivered = False

        def terminate_in_marker(path, *args, **options):
            nonlocal delivered
            if path.name == RUNNER.PROCESS_MARKER and args and args[0] & os.O_CREAT and not delivered:
                self.wait_for_worker()
                delivered = True
                os.kill(os.getpid(), signal.SIGTERM)
            return original(path, *args, **options)

        with patch.object(RUNNER, "owned_file", terminate_in_marker), patch.object(RUNNER, "CANCEL_GRACE_SECONDS", 0.05):
            status, report, _ = self.run_probes([probe])
        self.assertTrue(delivered)
        self.assertEqual(status, 143)
        self.assertEqual(report["runnerExitCode"], 143)
        self.assert_worker_joined()

    def test_creation_deferral_preserves_child_signal_mask(self):
        expected = sorted(int(number) for number in signal.pthread_sigmask(signal.SIG_BLOCK, set()))
        probe = self.probe("mask", 'import json, signal\nprint(json.dumps(sorted(int(n) for n in signal.pthread_sigmask(signal.SIG_BLOCK, set()))))', interpreter="python3")
        status, _, directory = self.run_probes([probe])
        self.assertEqual(status, 0)
        self.assertEqual(json.loads((directory / "mask.log").read_text()), expected)

    def test_incomplete_term_cleanup_retains_143_and_reserves_the_worktree(self):
        class Process:
            pid = 123456
            returncode = None
            def wait(self):
                raise RUNNER.RunTermination(signal.SIGTERM)
        with patch.object(RUNNER.subprocess, "Popen", return_value=Process()), \
             patch.object(RUNNER, "stop_process_group", side_effect=OSError("synthetic cleanup failure")), \
             patch.object(RUNNER, "live_process_group", return_value=True):
            status, report, _ = self.run_probes([self.probe("first"), self.probe("later")])
        self.assertEqual(status, 143)
        self.assertEqual(report["results"][0]["cleanupError"], "synthetic cleanup failure")
        self.assertEqual(report["counts"], {"total": 2, "passed": 0, "failed": 1, "skipped": 1})
        self.assertTrue((self.root / ".build" / RUNNER.PROCESS_MARKER).exists())

    def test_cleanup_inspection_failure_cannot_replace_original_term(self):
        class Process:
            pid = 123456
            returncode = -signal.SIGTERM
            def wait(self):
                raise RUNNER.RunTermination(signal.SIGTERM)
        with patch.object(RUNNER.subprocess, "Popen", return_value=Process()), \
             patch.object(RUNNER, "stop_process_group"), \
             patch.object(RUNNER, "live_process_group", side_effect=OSError("synthetic ps failure")):
            status, report, _ = self.run_probes([self.probe("term")])
        self.assertEqual(status, 143)
        self.assertEqual(report["results"][0]["exitCode"], -signal.SIGTERM)
        self.assertEqual(report["results"][0]["inspectionError"], "synthetic ps failure")
        self.assertTrue((self.root / ".build" / RUNNER.PROCESS_MARKER).exists())

    def test_ordinary_cleanup_failure_keeps_known_child_exit(self):
        class Process:
            pid = 123456
            returncode = 0
            def wait(self): return 0
        with patch.object(RUNNER.subprocess, "Popen", return_value=Process()), \
             patch.object(RUNNER, "stop_process_group", side_effect=OSError("synthetic cleanup failure")), \
             patch.object(RUNNER, "live_process_group", side_effect=[True, False]):
            status, report, _ = self.run_probes([self.probe("cleanup")])
        self.assertEqual(status, 1)
        self.assertEqual(report["results"][0]["exitCode"], 0)
        self.assertEqual(report["results"][0]["status"], "FAIL")

    def test_term_during_final_report_is_recorded_as_143_failure(self):
        original = Path.write_text
        delivered = False

        def interrupt_final_save(path, data, *args, **options):
            nonlocal delivered
            if path.name == "summary.json.tmp" and '"status": "PASS"' in data and not delivered:
                delivered = True
                os.kill(os.getpid(), signal.SIGTERM)
            return original(path, data, *args, **options)

        with patch.object(Path, "write_text", interrupt_final_save):
            status, report, _ = self.run_probes([self.probe("complete")])
        self.assertTrue(delivered)
        self.assertEqual(status, 143)
        self.assertEqual(report["status"], "FAIL")
        self.assertEqual(report["runnerExitCode"], 143)

    def test_term_during_initial_report_accounts_for_unstarted_probes(self):
        original = Path.write_text
        delivered = False

        def interrupt_initial_save(path, data, *args, **options):
            nonlocal delivered
            if path.name == "summary.json.tmp" and not delivered:
                delivered = True
                os.kill(os.getpid(), signal.SIGTERM)
            return original(path, data, *args, **options)

        with patch.object(Path, "write_text", interrupt_initial_save):
            status, report, _ = self.run_probes([self.probe("not_started", "touch wrongly-started")])
        self.assertEqual(status, 143)
        self.assertEqual(report["status"], "FAIL")
        self.assertEqual(report["counts"], {"total": 1, "passed": 0, "failed": 0, "skipped": 1})
        self.assertIsNone(report["results"][0]["exitCode"])
        self.assertIn("finishedAt", report)
        self.assertFalse((self.root / "wrongly-started").exists())

    def test_term_during_handler_install_restores_original_handlers(self):
        originals = {number: signal.getsignal(number) for number in (signal.SIGINT, signal.SIGTERM)}
        original_set = signal.signal
        delivered = False

        def interrupt_install(number, handler):
            nonlocal delivered
            result = original_set(number, handler)
            if number == signal.SIGTERM and callable(handler) and getattr(handler, "__name__", "") == "handle" and not delivered:
                delivered = True
                os.kill(os.getpid(), signal.SIGTERM)
            return result

        with patch.object(RUNNER.signal, "signal", interrupt_install), redirect_stdout(io.StringIO()):
            status, report = RUNNER.run_suite(self.root, [self.probe("not-started", "touch wrongly-started")])
        self.assertEqual(status, 143)
        self.assertEqual(report["status"], "FAIL")
        self.assertFalse((self.root / "wrongly-started").exists())
        for number, handler in originals.items():
            self.assertEqual(signal.getsignal(number), handler)

    def test_symlinked_marker_and_lock_are_rejected_before_write(self):
        (self.root / ".build").mkdir()
        for name in (RUNNER.PROCESS_MARKER, "standalone-regression.lock"):
            with self.subTest(name=name):
                outside = self.root / f"unowned-{name}"
                link = self.root / ".build" / name
                link.unlink(missing_ok=True)
                link.symlink_to(outside)
                with self.assertRaisesRegex(ValueError, "regular file"):
                    with RUNNER.run_lock(self.root):
                        self.fail("A dangling ownership symlink must not be accepted")
                self.assertFalse(outside.exists())
                link.unlink()

    def test_hardlinked_ownership_file_is_rejected_without_truncation(self):
        (self.root / ".build").mkdir()
        outside = self.root / "unowned-data"
        outside.write_text("must stay unchanged")
        marker = self.root / ".build" / RUNNER.PROCESS_MARKER
        os.link(outside, marker)
        with self.assertRaisesRegex(ValueError, "one link"):
            RUNNER.owned_file(marker, os.O_WRONLY | os.O_CREAT | os.O_TRUNC)
        self.assertEqual(outside.read_text(), "must stay unchanged")

    def test_term_during_handler_restoration_keeps_actual_report_and_exit(self):
        self.probe("complete")
        code = '''
import importlib.util, os, signal, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("runner", sys.argv[1])
runner = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = runner
spec.loader.exec_module(runner)
original = signal.signal
sent = False
def restore_with_term(number, handler):
    global sent
    value = original(number, handler)
    if number == signal.SIGTERM and handler == signal.SIG_DFL and not sent:
        sent = True
        os.kill(os.getpid(), signal.SIGTERM)
    return value
signal.signal = restore_with_term
status, report = runner.run_suite(Path(sys.argv[2]), [runner.Probe("Tests/run_complete_tests.sh", "sh")])
assert signal.getsignal(signal.SIGTERM) == signal.SIG_DFL
sys.exit(status)
'''
        completed = subprocess.run([sys.executable, "-S", "-c", code,
                                    str(ROOT / "scripts/dev/standalone-regression.py"), str(self.root)],
                                   capture_output=True, text=True, timeout=10)
        self.assertEqual(completed.returncode, 143, completed.stderr)
        report = json.loads(next(self.root.glob(".build/standalone-regression/*/summary.json")).read_text())
        self.assertEqual(report["status"], "FAIL")
        self.assertEqual(report["runnerExitCode"], 143)
        self.assertTrue(report["interrupted"])

    def test_caller_blocked_pending_term_and_child_mask_remain_owned_by_caller(self):
        previous = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM})
        try:
            os.kill(os.getpid(), signal.SIGTERM)
            probe = self.probe("caller_mask", 'import signal\nassert signal.SIGTERM in signal.pthread_sigmask(signal.SIG_BLOCK, set())', interpreter="python3")
            status, report, _ = self.run_probes([probe])
            self.assertEqual(status, 0)
            self.assertEqual(report["status"], "PASS")
            self.assertIn(signal.SIGTERM, signal.sigpending())
            self.assertIn(signal.SIGTERM, signal.pthread_sigmask(signal.SIG_BLOCK, set()))
        finally:
            if signal.SIGTERM in signal.sigpending():
                signal.sigwait({signal.SIGTERM})
            signal.pthread_sigmask(signal.SIG_SETMASK, previous)

    def test_background_descendant_is_not_a_success_or_left_running(self):
        probe = self.worker_probe(wait=False)
        with patch.object(RUNNER, "CANCEL_GRACE_SECONDS", 0.05):
            status, report, _ = self.run_probes([probe])
        self.assertEqual(status, 1)
        self.assertEqual(report["results"][0]["exitCode"], 0)
        self.assertIn("unjoined", report["results"][0]["reason"])
        self.assert_worker_joined()

    def test_interrupt_between_probes_still_finalizes_accounting(self):
        def stop_after_first(message, **options):
            if message == "PASS first":
                raise KeyboardInterrupt()
        with patch.object(RUNNER, "print", side_effect=stop_after_first, create=True):
            status, report, _ = self.run_probes([self.probe("first"), self.probe("later")])
        self.assertEqual(status, 130)
        self.assertEqual(report["status"], "FAIL")
        self.assertEqual(report["counts"], {"total": 2, "passed": 1, "failed": 0, "skipped": 1})

    def test_incomplete_cleanup_blocks_remaining_and_following_suites(self):
        marker = self.root / ".build" / RUNNER.PROCESS_MARKER

        def incomplete(*args):
            marker.write_text(json.dumps({"processGroup": 123456}))
            raise OSError("synthetic incomplete cleanup")

        with patch.object(RUNNER, "run_owned_process", side_effect=incomplete):
            status, report, _ = self.run_probes([self.probe("first"), self.probe("later")])
        self.assertEqual(status, 1)
        self.assertEqual(report["counts"]["skipped"], 1)
        with patch.object(RUNNER, "live_process_group", return_value=True):
            with self.assertRaisesRegex(ValueError, "previous probe still owns"):
                with RUNNER.run_lock(self.root):
                    self.fail("A new suite must not compete with an owned process")
        with patch.object(RUNNER, "live_process_group", return_value=False):
            with RUNNER.run_lock(self.root):
                pass
        self.assertFalse(marker.exists())

    def test_registry_drift_or_interpreter_change_requires_review(self):
        probe = self.probe("known")
        RUNNER.validate_registry(self.root, [probe])
        unknown = self.probe("unregistered")
        with self.assertRaisesRegex(ValueError, "registry mismatch"):
            RUNNER.validate_registry(self.root, [probe])
        (self.root / unknown.script).unlink()
        (self.root / probe.script).write_text("#!/usr/bin/env bash\nexit 0\n")
        with self.assertRaisesRegex(ValueError, "changed interpreter"):
            RUNNER.validate_registry(self.root, [probe])

    def test_selection_is_exact_ordered_and_deduplicated(self):
        probes = [self.probe("first"), self.probe("second")]
        self.assertEqual(RUNNER.select_probes(["second", "first", "first"], probes), tuple(probes))
        with self.assertRaisesRegex(ValueError, "Unknown"):
            RUNNER.select_probes(["typo"], probes)

    def test_parallel_runs_in_one_worktree_are_rejected_and_lock_releases(self):
        with RUNNER.run_lock(self.root):
            with self.assertRaisesRegex(ValueError, "already active"):
                with RUNNER.run_lock(self.root):
                    self.fail("Second run must not start")
        with RUNNER.run_lock(self.root):
            pass

    def test_symlinked_build_storage_is_rejected(self):
        outside = self.root / "shared-build"
        outside.mkdir()
        (self.root / ".build").symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "belong to this worktree"):
            self.run_probes([self.probe("storage")])


if __name__ == "__main__":
    unittest.main()
