#!/usr/bin/env python3
"""Owned fixture control on private mock protocol files. Never launches an app."""
import json
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import uuid

from meeting_continuity_driver import Child, Driver, OwnedProcesses
from meeting_continuity_fixture import ProtocolError, atomic_json, read_json


class Clock:
    def __init__(self):
        self.now = 0.0
        self.pump = lambda: None

    def read(self):
        return self.now

    def pause(self, seconds):
        self.now += seconds
        self.pump()


class MockProcesses(OwnedProcesses):
    def __init__(self, clock):
        self.clock = clock
        self.workspace = Path("/owned-fixture")
        self.chrome_app = self.workspace / "Google Chrome.app"
        self.executable = self.chrome_app / "Contents/MacOS/Google Chrome"
        self.profile = self.workspace / "profile"
        self.wave = Path("/synthetic/second.wav")
        self.children, self.statuses, self.metadata = {}, {}, {}
        self.signals, self.launches = [], []
        self.after_resume = lambda: None

    def child(self, kind):
        pid = 200 + len(self.children)
        args = ((str(self.executable), f"--user-data-dir={self.profile}") if kind == "chrome"
                else ("/usr/bin/afplay", str(self.wave)))
        child = Child(pid, args, kind)
        self.children[pid] = child
        self.statuses[pid] = None
        self.metadata[pid] = dict(executable=args[0], group=pid, arguments=" ".join(args))
        self.launches.append((kind, pid, self.clock.now))
        return child

    def chrome(self, url):
        return self.child("chrome")

    def player(self):
        return self.child("player")

    def poll(self, child):
        return self.statuses.get(child.pid)

    def executable_for(self, pid):
        return self.metadata[pid]["executable"]

    def group_for(self, pid):
        return self.metadata[pid]["group"]

    def arguments_for(self, pid, deadline=None):
        return self.metadata[pid]["arguments"]

    def group_members(self, group, deadline=None):
        return [pid for pid, value in self.metadata.items()
                if value["group"] == group and self.statuses.get(pid) is None]

    def send_group(self, pid, value):
        self.signals.append((pid, value))
        if value == signal.SIGKILL:
            for member in self.group_members(pid):
                self.statuses[member] = -9
        if value == signal.SIGCONT:
            self.clock.now += 1.0  # Deliberately short playback proves actual >=8s absence gate.
            self.statuses[pid] = 0
            self.after_resume()


class MockFixture:
    def __init__(self, root, clock):
        self.root, self.clock = root, clock
        self.run_id, self.token = str(uuid.uuid4()).upper(), "a" * 43
        self.failed = False
        self.prepared_phase = None
        self.completed = set()
        self.commands = []
        self.after_ack = lambda sequence: None

    def authorize(self, payload):
        if (self.root / "outcome.json").exists():
            raise ProtocolError("Native probe failed")

    def ack(self, root, run, sequence):
        command = read_json(root / "phase-command.json")
        if command["sequence"] != sequence or command["runID"] != run:
            raise ProtocolError("Unexpected command")
        if sequence != len(self.commands) + 1:
            raise ProtocolError("Skipped sequence")
        self.commands.append(command)
        ack = dict(runID=run, sequence=sequence, machAbsoluteHostSeconds=100 + self.clock.now)
        atomic_json(root / "phase-ack.json", ack)
        self.after_ack(sequence)
        return ack

    def automatic_end(self, phase, sequence):
        atomic_json(self.root / "phase-command.json", dict(
            runID=self.run_id, sequence=sequence, action="end", phase=phase))
        self.ack(self.root, self.run_id, sequence)
        self.completed.add(phase)

    def event(self, payload):
        if payload["phase"] != "secondSource":
            raise ProtocolError("Unexpected second-source event")
        if payload["event"] == "ended":
            self.automatic_end("secondSource", 5)


class DriverTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.root.chmod(0o700)
        self.clock = Clock()
        self.fixture = MockFixture(self.root, self.clock)
        self.processes = MockProcesses(self.clock)
        self.driver = Driver(self.fixture, self.processes, 8888, "before.wav", "after.wav",
                             clock=self.clock.read, pause=self.clock.pause)
        self.clock.pump = self.pump

    def tearDown(self):
        self.temporary.cleanup()

    def pump(self):
        step = read_json(self.driver.state_path)["step"]
        if step == "browser-launched":
            self.fixture.prepared_phase = "browserBefore"
        elif step == "prepared-before-capture":
            atomic_json(self.root / "capture-ready.json", dict(
                runID=self.fixture.run_id, readyHostSeconds=100, captureStartHostSeconds=99, durationSeconds=100))
        elif step == "await-first-cua-play" and "browserBefore" not in self.fixture.completed:
            self.fixture.automatic_end("browserBefore", 2)
        elif len(self.fixture.commands) == 6:
            self.fixture.prepared_phase = "browserAfter"
        elif step == "await-final-cua-play" and "browserAfter" not in self.fixture.completed:
            self.fixture.automatic_end("browserAfter", 8)
            atomic_json(self.root / "outcome.json", dict(runID=self.fixture.run_id, status="mock-completed"))

    def wait(self, root, run, sequence):
        ack = read_json(root / "phase-ack.json") if (root / "phase-ack.json").exists() else None
        if ack and ack["sequence"] == sequence:
            return ack
        return self.fixture.ack(root, run, sequence)

    def run_driver(self):
        with patch("meeting_continuity_driver.wait_ack", side_effect=self.wait):
            self.driver.run()

    def test_private_mock_first_phase_and_whole_sequence_no_model_roundtrips(self):
        self.run_driver()
        self.assertEqual([value["sequence"] for value in self.fixture.commands], list(range(1, 9)))
        self.assertEqual([value["action"] for value in self.fixture.commands],
                         ["begin", "end", "browserExited", "begin", "end", "browserRestarted", "begin", "end"])
        initial, player, restarted = self.processes.launches
        self.assertNotEqual(initial[1], restarted[1])
        self.assertNotEqual(initial[1], player[1])
        self.assertGreaterEqual(restarted[2] - player[2], 8)
        self.assertEqual(self.fixture.commands[2]["processID"], initial[1])
        self.assertEqual(self.fixture.commands[3]["executablePath"], "/usr/bin/afplay")
        self.assertNotIn("bundleID", self.fixture.commands[3])
        self.assertEqual(self.fixture.commands[5]["processID"], restarted[1])
        events = [json.loads(line) for line in (self.root / "driver-events.jsonl").read_text().splitlines()]
        self.assertTrue(all(event["utc"].endswith("+00:00") for event in events))
        self.assertLess(next(i for i, e in enumerate(events) if e["step"] == "prepared-before-capture"),
                        next(i for i, e in enumerate(events) if e.get("sequence") == 1))
        self.assertEqual([e["nativeSequence"] for e in events if "nativeSequence" in e], [1, 7])
        self.assertEqual(read_json(self.driver.state_path)["step"], "owned-processes-joined")
        self.assertEqual(read_json(self.driver.state_path)["protocolComplete"], True)
        self.assertEqual(read_json(self.driver.state_path)["liveOwnedChildren"], 0)
        self.assertTrue(all(status is not None for status in self.processes.statuses.values()))

    def test_wrong_pid_executable_profile_group_or_foreign_member_never_signalled(self):
        for fault in ("pid", "executable", "profile", "group", "member"):
            with self.subTest(fault=fault):
                processes = MockProcesses(Clock())
                child = processes.child("chrome")
                if fault == "pid":
                    child = Child(child.pid, child.args, child.kind)
                elif fault == "executable":
                    processes.metadata[child.pid]["executable"] = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
                elif fault == "profile":
                    processes.metadata[child.pid]["arguments"] = "Google Chrome --user-data-dir=/user-primary"
                elif fault == "group":
                    processes.metadata[child.pid]["group"] = 999
                else:
                    processes.metadata[999] = dict(group=child.pid, executable="/foreign/app", arguments="foreign")
                    processes.statuses[999] = None
                with self.assertRaises(ProtocolError):
                    processes.stop(child)
                self.assertEqual(processes.signals, [])

    def test_native_failure_prevents_second_source_process_start(self):
        def fail(sequence):
            if sequence == 3:
                atomic_json(self.root / "outcome.json", dict(runID=self.fixture.run_id, status="failed"))
        self.fixture.after_ack = fail
        with self.assertRaisesRegex(ProtocolError, "stopped"):
            self.run_driver()
        self.assertEqual([kind for kind, _, _ in self.processes.launches], ["chrome"])
        self.assertTrue(all(status is not None for status in self.processes.statuses.values()))

    def test_cleanup_helper_exit_between_snapshot_and_executable_lookup_is_rechecked(self):
        child = self.processes.child("chrome")
        self.processes.statuses[child.pid] = -9
        helper = 900
        self.processes.metadata[helper] = dict(group=child.pid, executable=str(self.processes.chrome_app / "helper"))
        self.processes.statuses[helper] = None
        def disappears(pid):
            self.assertEqual(pid, helper)
            self.processes.statuses[helper] = -9
            raise ProtocolError("Cannot verify owned process executable")
        with patch.object(self.processes, "executable_for", side_effect=disappears):
            self.processes.stop(child)
        self.assertEqual(self.processes.signals, [])
        self.assertEqual(self.processes.group_members(child.pid), [])

    def test_failed_lookup_of_still_live_unknown_member_is_never_signalled(self):
        child = self.processes.child("chrome")
        self.processes.statuses[child.pid] = -9
        self.processes.metadata[900] = dict(group=child.pid, executable="/unknown/helper")
        self.processes.statuses[900] = None
        with patch.object(self.processes, "executable_for", side_effect=ProtocolError("Lookup failed")):
            with self.assertRaisesRegex(ProtocolError, "unverified live"):
                self.processes.stop(child)
        self.assertEqual(self.processes.signals, [])

    def test_initial_stop_live_leader_and_helper_exit_during_lookup_sends_no_signal(self):
        child = self.processes.child("chrome")
        self.processes.metadata[900] = dict(group=child.pid, executable=str(self.processes.chrome_app / "helper"))
        self.processes.statuses[900] = None
        def lookup(pid):
            if pid == 900:
                self.processes.statuses[child.pid] = -9
                self.processes.statuses[900] = -9
                raise ProtocolError("Helper and leader exited")
            return self.processes.metadata[pid]["executable"]
        with patch.object(self.processes, "executable_for", side_effect=lookup):
            self.processes.stop(child)
        self.assertEqual(self.processes.signals, [])
        self.assertIsNotNone(self.processes.poll(child))
        self.assertEqual(self.processes.group_members(child.pid), [])

    def exit_player_during_validation(self, child):
        calls = 0
        def lookup(pid):
            nonlocal calls
            calls += 1
            if calls == 2:
                self.processes.statuses[child.pid] = 0
                raise ProtocolError("Suspended player exited during validation")
            return self.processes.metadata[pid]["executable"]
        return lookup

    def test_suspended_player_exit_during_validation_never_sends_sigcont(self):
        child = self.processes.child("player")
        with patch.object(self.processes, "executable_for", side_effect=self.exit_player_during_validation(child)):
            with self.assertRaisesRegex(ProtocolError, "live leader disappeared"):
                self.processes.resume(child)
        self.assertEqual(self.processes.signals, [])

    def test_phase_begin_rejects_player_that_exits_during_validation(self):
        child = self.processes.child("player")
        with patch.object(self.processes, "executable_for", side_effect=self.exit_player_during_validation(child)):
            with self.assertRaisesRegex(ProtocolError, "live leader disappeared"):
                self.driver.command(4, "begin", "secondSource", child)
        self.assertFalse((self.root / "phase-command.json").exists())
        self.assertEqual(self.processes.signals, [])

    def test_joined_child_and_fresh_empty_group_cleanup_need_no_signal(self):
        child = self.processes.child("chrome")
        self.processes.statuses[child.pid] = -9
        with patch.object(self.processes, "executable_for", side_effect=AssertionError("No lookup for absent members")):
            self.processes.stop(child)
        self.assertEqual(self.processes.signals, [])

    def test_empty_group_without_joined_child_is_not_successful_cleanup(self):
        child = self.processes.child("chrome")
        with patch.object(self.processes, "group_members", return_value=[]):
            with self.assertRaisesRegex(ProtocolError, "joined-child proof"):
                self.processes.stop(child)
        self.assertEqual(self.processes.signals, [])

    def test_exited_leader_pid_reuse_is_refused_even_for_same_copy_executable(self):
        child = self.processes.child("chrome")
        self.processes.statuses[child.pid] = -9
        with patch.object(self.processes, "group_members", return_value=[child.pid]):
            with self.assertRaisesRegex(ProtocolError, "reused"):
                self.processes.stop(child)
        self.assertEqual(self.processes.signals, [])

    def test_disappearing_member_refresh_verifies_new_unknown_member(self):
        child = self.processes.child("chrome")
        self.processes.statuses[child.pid] = -9
        self.processes.metadata[900] = dict(group=child.pid, executable="/old/helper")
        self.processes.statuses[900] = None
        def lookup(pid):
            if pid == 900:
                self.processes.statuses[900] = -9
                self.processes.metadata[901] = dict(group=child.pid, executable="/foreign/new-helper")
                self.processes.statuses[901] = None
                raise ProcessLookupError("Member exited")
            return self.processes.metadata[pid]["executable"]
        with patch.object(self.processes, "executable_for", side_effect=lookup):
            with self.assertRaisesRegex(ProtocolError, "unverified process"):
                self.processes.stop(child)
        self.assertEqual(self.processes.signals, [])

    def test_signal_esrch_requires_both_empty_group_and_joined_child(self):
        child = self.processes.child("chrome")
        self.processes.statuses[child.pid] = -9
        with patch.object(self.processes, "send_group", side_effect=ProcessLookupError("Gone")):
            self.processes.kill_group(child)
            self.processes.statuses[child.pid] = None
            with self.assertRaisesRegex(ProtocolError, "disappearance"):
                self.processes.kill_group(child)

    def test_cleanup_refresh_and_ps_timeout_keep_existing_three_second_deadline(self):
        child = self.processes.child("chrome")
        self.processes.statuses[child.pid] = -9
        with patch("meeting_continuity_driver.time.monotonic", return_value=10):
            self.assertEqual(self.processes.process_timeout(11), 1)
            with self.assertRaisesRegex(ProtocolError, "deadline"):
                self.processes.process_timeout(10)
            with self.assertRaisesRegex(ProtocolError, "timed out"):
                self.processes.verify_members(child, [900], deadline=10)

    def test_failed_ack_does_not_progress_and_cancellation_joins_owned_children(self):
        with patch("meeting_continuity_driver.wait_ack", side_effect=ProtocolError("ack failed")):
            with self.assertRaisesRegex(ProtocolError, "ack failed"):
                self.driver.run()
        self.assertEqual(len(self.processes.launches), 1)
        self.assertEqual(self.fixture.commands, [])
        self.assertTrue(all(status is not None for status in self.processes.statuses.values()))

    def test_cancel_during_player_does_not_restart_and_cleans_up(self):
        def cancel_player():
            pid = self.processes.launches[-1][1]
            self.processes.statuses[pid] = None
            self.driver.cancelled.set()
        self.processes.after_resume = cancel_player
        with self.assertRaisesRegex(ProtocolError, "cancelled"):
            self.run_driver()
        self.assertEqual([kind for kind, _, _ in self.processes.launches], ["chrome", "player"])
        self.assertTrue(all(status is not None for status in self.processes.statuses.values()))

    def test_failed_player_never_sends_end_or_restarts_browser(self):
        self.processes.after_resume = lambda: self.processes.statuses.update({201: 3})
        with self.assertRaisesRegex(ProtocolError, "player failed"):
            self.run_driver()
        self.assertEqual([value["sequence"] for value in self.fixture.commands], [1, 2, 3, 4])
        self.assertEqual([kind for kind, _, _ in self.processes.launches], ["chrome", "player"])

    def test_existing_failed_outcome_prevents_initial_launch(self):
        atomic_json(self.root / "outcome.json", dict(runID=self.fixture.run_id, status="failed"))
        with self.assertRaises(ProtocolError):
            self.run_driver()
        self.assertEqual(self.processes.launches, [])

    def test_cli_dry_run_does_not_touch_missing_fixture_or_start_server(self):
        command = [sys.executable, "-B", "-S", str(Path(__file__).with_name("meeting_continuity_driver.py")),
            "--dry-run", "--root", "/missing/capture", "--workspace", "/missing/owned",
            "--chrome-app", "/missing/owned/Google Chrome.app", "--stimulus-dir", "/missing/stimulus",
            "--second-wave", "/missing/stimulus/second.wav", "--run-id", self.fixture.run_id,
            "--token", self.fixture.token, "--before-wav", "before.wav", "--after-wav", "after.wav", "--port", "8888"]
        result = subprocess.run(command, check=True, capture_output=True, text=True, timeout=3)
        plan = json.loads(result.stdout)
        self.assertFalse(plan["nativeCaptureStarted"])
        self.assertFalse(plan["applicationLaunched"])
        self.assertFalse(plan["serverStarted"])
        self.assertEqual(plan["cuaPlayClicks"], 2)
        self.assertEqual(plan["durationSeconds"], 100)
        self.assertEqual(plan["phaseLimitSeconds"], 60)

    def test_cleanup_failure_is_retained_without_claiming_owned_children_joined(self):
        with patch.object(self.processes, "cleanup", side_effect=ProtocolError("unverified cleanup")):
            with self.assertRaisesRegex(ProtocolError, "unverified cleanup"):
                self.run_driver()
        self.assertFalse(self.driver.owned_joined)
        self.assertEqual(read_json(self.driver.state_path)["step"], "cleanup-failed")
        self.assertEqual(self.driver.failure, "unverified cleanup")


if __name__ == "__main__":
    unittest.main()
