#!/usr/bin/env python3
"""Owned Chrome/afplay fixture protocol. Only the two Play clicks belong to CUA.

This opt-in test CLI never starts native capture or controls permissions, preferences,
microphones, arbitrary apps, the user's Chrome, or HTTP-triggered process actions.
"""
import argparse
import ctypes
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import threading
import time
from urllib.parse import urlencode, urlsplit
import uuid

from meeting_continuity_fixture import Fixture, HTTPServer, NAME, ProtocolError, atomic_json, handler_for, read_json, regular_file, wait_ack


@dataclass(frozen=True)
class Child:
    pid: int
    args: tuple
    kind: str
    process: object = None


class OwnedProcesses:
    """Only children created here, from the one copied Chrome and one named WAV."""
    def __init__(self, workspace, chrome_app, wave):
        self.workspace, self.chrome_app, self.wave = map(Path, (workspace, chrome_app, wave))
        if (self.workspace.resolve(strict=True) != self.workspace or not self.workspace.is_absolute()
                or self.workspace.stat().st_uid != os.getuid() or self.workspace.stat().st_mode & 0o777 != 0o700
                or any(character.isspace() for character in str(self.workspace))
                or self.chrome_app != self.workspace / "Google Chrome.app"):
            raise ProtocolError("Use an owned private fixture workspace with its copied Google Chrome.app.")
        self.executable = self.chrome_app / "Contents/MacOS/Google Chrome"
        vendor = Path("/Applications/Google Chrome.app")
        for app in (self.chrome_app, vendor):
            with (app / "Contents/Info.plist").open("rb") as stream:
                info = plistlib.load(stream)
            if info.get("CFBundleIdentifier") != "com.google.Chrome" or info.get("CFBundleExecutable") != "Google Chrome":
                raise ProtocolError("Expected the full vendor Google Chrome bundle.")
        regular_file(self.executable)
        regular_file(self.wave)
        if self.executable.resolve(strict=True) != self.executable or self.wave.resolve(strict=True) != self.wave:
            raise ProtocolError("Use canonical fixture executable and WAV paths.")
        def digest(path):
            with path.open("rb") as stream:
                return hashlib.file_digest(stream, "sha256").hexdigest()
        if digest(self.executable) != digest(vendor / "Contents/MacOS/Google Chrome"):
            raise ProtocolError("Copied Chrome executable differs from the installed vendor executable.")
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(self.chrome_app)],
                       check=True, timeout=30, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.profile = self.workspace / "profile"
        if self.profile.exists() or self.profile.is_symlink():
            raise ProtocolError("Use a fresh owned profile for this trial.")
        self.profile.mkdir(mode=0o700)
        self.children = {}
        self.statuses = {}

    def chrome(self, url):
        parsed = urlsplit(url)
        if (parsed.scheme != "http" or parsed.hostname != "127.0.0.1" or not parsed.port
                or parsed.username is not None or parsed.password is not None or parsed.fragment
                or parsed.path != "/meeting_browser_speech_stimulus.html" or not parsed.query):
            raise ProtocolError("Only the explicit localhost fixture URL is allowed.")
        args = (str(self.executable), f"--user-data-dir={self.profile}", "--no-first-run",
                "--no-default-browser-check", "--disable-background-mode", "--new-window", url)
        process = subprocess.Popen(args, start_new_session=True, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        child = Child(process.pid, args, "chrome", process)
        self.children[child.pid] = child
        return child

    def player(self):
        # Darwin creates afplay suspended before any instruction, with its own process group.
        # A post-Popen SIGSTOP can race playback; preexec_fn can deadlock with the server thread.
        library = ctypes.CDLL(None)
        attribute, pid = ctypes.c_void_p(), ctypes.c_int()
        pointer = ctypes.POINTER(ctypes.c_void_p)
        library.posix_spawnattr_init.argtypes = [pointer]
        library.posix_spawnattr_setflags.argtypes = [pointer, ctypes.c_short]
        library.posix_spawnattr_setpgroup.argtypes = [pointer, ctypes.c_int]
        library.posix_spawnattr_destroy.argtypes = [pointer]
        library.posix_spawn.argtypes = [ctypes.POINTER(ctypes.c_int), ctypes.c_char_p,
                                      ctypes.c_void_p, pointer, ctypes.POINTER(ctypes.c_char_p),
                                      ctypes.POINTER(ctypes.c_char_p)]
        args = ("/usr/bin/afplay", str(self.wave))
        argv = (ctypes.c_char_p * 3)(*(arg.encode() for arg in args), None)
        environment = (ctypes.c_char_p * 2)(b"PATH=/usr/bin:/bin", None)
        if library.posix_spawnattr_init(ctypes.byref(attribute)):
            raise ProtocolError("Cannot initialize suspended player spawn.")
        try:
            for error in (library.posix_spawnattr_setflags(ctypes.byref(attribute), 0x0080 | 0x0002),
                          library.posix_spawnattr_setpgroup(ctypes.byref(attribute), 0)):
                if error:
                    raise OSError(error, "Cannot configure suspended player spawn.")
            error = library.posix_spawn(ctypes.byref(pid), b"/usr/bin/afplay", None,
                                       ctypes.byref(attribute), argv, environment)
            if error:
                raise OSError(error, "Cannot spawn suspended player.")
        finally:
            library.posix_spawnattr_destroy(ctypes.byref(attribute))
        child = Child(pid.value, args, "player")
        self.children[child.pid] = child
        return child

    def poll(self, child):
        if child.kind == "chrome":
            return child.process.poll()
        if child.pid not in self.statuses:
            pid, status = os.waitpid(child.pid, os.WNOHANG)
            if pid:
                self.statuses[child.pid] = os.waitstatus_to_exitcode(status)
        return self.statuses.get(child.pid)

    def executable_for(self, pid):
        library = ctypes.CDLL("/usr/lib/libproc.dylib")
        buffer = ctypes.create_string_buffer(4096)
        if library.proc_pidpath(pid, buffer, len(buffer)) <= 0:
            raise ProtocolError("Cannot verify owned process executable.")
        return buffer.value.decode()

    def group_for(self, pid):
        return os.getpgid(pid)

    def process_timeout(self, deadline):
        remaining = 2 if deadline is None else deadline - time.monotonic()
        if remaining <= 0:
            raise ProtocolError("Owned process verification deadline expired.")
        return min(2, remaining)

    def arguments_for(self, pid, deadline=None):
        return subprocess.check_output(["/bin/ps", "-p", str(pid), "-o", "command="], text=True,
                                       timeout=self.process_timeout(deadline)).strip()

    def group_members(self, group, deadline=None):
        output = subprocess.check_output(["/bin/ps", "-axo", "pid=,pgid=,stat="], text=True,
                                         timeout=self.process_timeout(deadline))
        return [int(pid) for pid, pgid, state in (line.split() for line in output.splitlines())
                if int(pgid) == group and not state.startswith("Z")]

    def assert_owned(self, child, deadline=None, require_live=True):
        if self.children.get(child.pid) is not child:
            raise ProtocolError("Refuse to signal a foreign process.")
        if self.poll(child) is not None:
            if require_live:
                raise ProtocolError("Refuse to signal an exited process.")
            return []
        expected = str(self.executable) if child.kind == "chrome" else "/usr/bin/afplay"
        if (self.executable_for(child.pid) != expected or self.group_for(child.pid) != child.pid
                or child.args[0] != expected or (child.kind == "chrome"
                and (f"--user-data-dir={self.profile}" not in child.args
                     or f"--user-data-dir={self.profile}" not in self.arguments_for(child.pid, deadline).split()))):
            raise ProtocolError("Owned executable, profile or process group does not match.")
        verified = self.verify_members(child, self.group_members(child.pid, deadline), deadline)
        if require_live:
            self.require_live_owner(child, verified)
        return verified

    def require_live_owner(self, child, verified):
        if self.children.get(child.pid) is not child or child.pid not in verified or self.poll(child) is not None:
            raise ProtocolError("Owned live leader disappeared during verification.")

    def verify_members(self, child, members, deadline=None):
        deadline = deadline if deadline is not None else time.monotonic() + 3
        pending, verified = list(members), []
        while pending:
            if time.monotonic() >= deadline:
                raise ProtocolError("Owned process group verification timed out.")
            pid = pending.pop(0)
            try:
                if pid == child.pid and self.poll(child) is not None:
                    raise ProtocolError("Exited leader PID may have been reused.")
                executable = self.executable_for(pid)
            except (ProtocolError, ProcessLookupError) as error:
                current = self.group_members(child.pid, deadline)
                if pid in current:
                    raise ProtocolError("Refuse an unverified live or reused group member.") from error
                # The old PS snapshot raced exit. Reverify the complete fresh snapshot,
                # including any newly observed members, before allowing a group signal.
                pending, verified = list(current), []
                continue
            owned_player = child.kind == "player" and pid == child.pid and executable == "/usr/bin/afplay"
            owned_chrome = child.kind == "chrome" and executable.startswith(str(self.chrome_app) + "/")
            if not (owned_player or owned_chrome):
                raise ProtocolError("Refuse to signal an unverified process group member.")
            verified.append(pid)
        return verified

    def send_group(self, pid, value):
        os.killpg(pid, value)

    def resume(self, child):
        verified = self.assert_owned(child)
        self.require_live_owner(child, verified)
        self.send_group(child.pid, signal.SIGCONT)

    def stop(self, child):
        if self.children.get(child.pid) is not child:
            raise ProtocolError("Refuse cleanup of a foreign process.")
        deadline = time.monotonic() + 3
        if self.poll(child) is None:
            verified = self.assert_owned(child, deadline, require_live=False)
            if child.pid in verified and self.poll(child) is None:
                self.kill_group(child, deadline)
            elif self.poll(child) is not None and not self.group_members(child.pid, deadline):
                return
            elif self.poll(child) is None:
                raise ProtocolError("Owned leader disappearance has no joined-child proof.")
        # After leader exit, only members from this unique copied bundle may remain.
        while time.monotonic() < deadline:
            self.poll(child)
            members = self.group_members(child.pid, deadline)
            if not members and self.poll(child) is not None:
                return
            verified = self.verify_members(child, members, deadline)
            if verified:
                self.kill_group(child, deadline)
            time.sleep(0.025)
        raise ProtocolError("Owned process group did not join after termination.")

    def kill_group(self, child, deadline=None):
        try:
            self.send_group(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            # Exit can also win between verification and killpg. ESRCH alone is not
            # disappearance proof; require a fresh empty group and the joined child.
            if self.group_members(child.pid, deadline) or self.poll(child) is None:
                raise ProtocolError("Group signal failed without confirmed process disappearance.")

    def cleanup(self):
        errors = []
        for child in self.children.values():
            try:
                self.stop(child)
            except Exception as error:
                errors.append(str(error))
        if errors:
            raise ProtocolError("Owned fixture cleanup failed: " + "; ".join(errors))


class Driver:
    def __init__(self, fixture, processes, port, before, after, clock=time.monotonic, pause=time.sleep):
        self.fixture, self.processes, self.port = fixture, processes, port
        self.before, self.after = before, after
        self.clock, self.pause = clock, pause
        self.cancelled = threading.Event()
        self.capture_seen = None
        self.protocol_complete = False
        self.owned_joined = False
        self.failure = None
        self.state_path = fixture.root / "driver-state.json"
        journal = fixture.root / "driver-events.jsonl"
        if self.state_path.exists() or self.state_path.is_symlink() or journal.exists() or journal.is_symlink():
            raise ProtocolError("Use a fresh driver run.")

    def check(self):
        if self.fixture.root.resolve(strict=True) != self.fixture.root:
            raise ProtocolError("Protocol root changed to a symlink.")
        if self.cancelled.is_set() or self.fixture.failed or (self.fixture.root / "outcome.json").exists():
            raise ProtocolError("Trial cancelled or native probe stopped; stop progression.")
        if self.capture_seen is not None and self.clock() - self.capture_seen >= 100:
            raise ProtocolError("Native 100-second trial window expired.")

    def receipt(self, step, **fields):
        fields.pop("runID", None)
        value = dict(runID=self.fixture.run_id, step=step,
                     utc=datetime.now(timezone.utc).isoformat(), **fields)
        path = self.fixture.root / "driver-events.jsonl"
        descriptor = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "a") as stream:
            stream.write(json.dumps(value) + "\n")
        atomic_json(self.state_path, value)

    def url(self, phase, stimulus):
        return f"http://127.0.0.1:{self.port}/meeting_browser_speech_stimulus.html?" + urlencode(dict(
            runID=self.fixture.run_id, token=self.fixture.token, phase=phase, stimulus=stimulus, autoPrepare="1"))

    def until(self, predicate, timeout):
        deadline = self.clock() + timeout
        while self.clock() < deadline:
            self.check()
            value = predicate()
            if value:
                return value
            self.pause(0.025)
        raise ProtocolError("Fixture gate timed out; stop progression.")

    def command(self, sequence, action, phase=None, child=None):
        self.check()
        value = dict(runID=self.fixture.run_id, sequence=sequence, action=action)
        if phase:
            value["phase"] = phase
        if child:
            value["processID"] = child.pid
            if action != "browserExited":
                verified = self.processes.assert_owned(child)
                self.processes.require_live_owner(child, verified)
            if action == "begin":
                value["executablePath"] = child.args[0]
            if child.kind == "chrome" and action != "browserExited":
                value["bundleID"] = "com.google.Chrome"
        atomic_json(self.fixture.root / "phase-command.json", value)
        ack = wait_ack(self.fixture.root, self.fixture.run_id, sequence)
        self.receipt("native-ack", **ack)
        return ack

    def completed(self, phase, sequence):
        deadline = self.clock() + 60
        while self.clock() < deadline:
            # Final native outcome can follow ack8 immediately. Retain that valid end barrier.
            if phase in self.fixture.completed:
                return wait_ack(self.fixture.root, self.fixture.run_id, sequence)
            self.check()
            self.pause(0.025)
        raise ProtocolError("Natural playback completion timed out.")

    def run(self):
        try:
            self.check()
            browser = self.processes.chrome(self.url("browserBefore", self.before))
            self.receipt("browser-launched", processID=browser.pid, executablePath=browser.args[0])
            self.until(lambda: self.fixture.prepared_phase == "browserBefore", 30)
            self.receipt("prepared-before-capture", processID=browser.pid, speechStarted=False)
            self.until(lambda: (self.fixture.root / "capture-ready.json").exists(), 120)
            self.capture_seen = self.clock()
            self.fixture.authorize(dict(runID=self.fixture.run_id, token=self.fixture.token))
            self.command(1, "begin", "browserBefore", browser)
            self.receipt("await-first-cua-play", processID=browser.pid, phase="browserBefore",
                         nativeSequence=1, speechStarted=False)
            self.completed("browserBefore", 2)
            self.check()
            self.processes.assert_owned(browser)
            self.processes.stop(browser)
            self.receipt("browser-exited", processID=browser.pid)
            self.command(3, "browserExited", child=browser)
            absent_since = self.clock()  # Never count time before native exit ack as absence.
            self.check()
            player = self.processes.player()
            self.receipt("player-created-suspended", processID=player.pid, executablePath=player.args[0])
            self.command(4, "begin", "secondSource", player)
            self.fixture.event(dict(runID=self.fixture.run_id, token=self.fixture.token,
                                    phase="secondSource", event="starting"))
            self.check()
            self.processes.resume(player)
            self.until(lambda: self.processes.poll(player) is not None, 30)
            if self.processes.poll(player) != 0:
                raise ProtocolError("Owned second-source player failed; stop progression.")
            self.receipt("player-exited", processID=player.pid, exitCode=0)
            self.fixture.event(dict(runID=self.fixture.run_id, token=self.fixture.token,
                                    phase="secondSource", event="ended"))
            self.until(lambda: self.clock() - absent_since >= 8, 8.5)
            self.check()
            restarted = self.processes.chrome(self.url("browserAfter", self.after))
            if restarted.pid == browser.pid:
                raise ProtocolError("Restart did not create a new browser PID.")
            self.receipt("browser-restarted", processID=restarted.pid,
                         previousProcessID=browser.pid, absentSeconds=self.clock() - absent_since)
            self.command(6, "browserRestarted", child=restarted)
            self.until(lambda: self.fixture.prepared_phase == "browserAfter", 10)
            self.command(7, "begin", "browserAfter", restarted)
            self.receipt("await-final-cua-play", processID=restarted.pid, phase="browserAfter",
                         nativeSequence=7, speechStarted=False)
            self.completed("browserAfter", 8)
            self.protocol_complete = True
            self.receipt("protocol-complete")
        except Exception as error:
            self.failure = str(error)
            self.receipt("failed", reason=str(error))
            raise
        finally:
            try:
                self.processes.cleanup()
                self.owned_joined = True
                self.receipt("owned-processes-joined", protocolComplete=self.protocol_complete,
                             failure=self.failure, liveOwnedChildren=0)
            except Exception as error:
                self.failure = str(error)
                self.receipt("cleanup-failed", reason=str(error))
                raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ("root", "workspace", "chrome-app", "stimulus-dir", "second-wave"):
        parser.add_argument("--" + option, required=True, type=Path)
    for option in ("run-id", "token", "before-wav", "after-wav"):
        parser.add_argument("--" + option, required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--dry-run", action="store_true", help="Print the concrete plan without serving or launching anything")
    args = parser.parse_args()
    if (args.chrome_app != args.workspace / "Google Chrome.app" or args.second_wave.parent != args.stimulus_dir
            or not NAME.fullmatch(args.second_wave.name) or args.before_wav == args.after_wav
            or not NAME.fullmatch(args.before_wav) or not NAME.fullmatch(args.after_wav) or not 1 <= args.port <= 65535):
        parser.error("Use the workspace's Google Chrome copy, distinct named WAVs and one localhost port.")
    if args.dry_run:
        print(json.dumps(dict(runID=str(uuid.UUID(args.run_id)).upper(), nativeCaptureStarted=False,
            applicationLaunched=False, serverStarted=False, durationSeconds=100, phaseLimitSeconds=60,
            cues=["prepared-before-capture", "await-first-cua-play", "await-final-cua-play"], cuaPlayClicks=2,
            middle=["native-end2", "owned-Chrome-exit", "native-exit3", "suspended-afplay-begin4",
                    "owned-afplay-exit0", "native-end5", "actual-absence-at-least8s", "new-Chrome-PID-restart6",
                    "transport-only-prepare", "native-begin7"])))
        return
    if sys.platform != "darwin":
        parser.error("The real owned process fixture requires macOS. Offline mocks are portable.")
    fixture = Fixture(args.root, args.run_id, args.token, args.stimulus_dir, [args.before_wav, args.after_wav])
    processes = OwnedProcesses(args.workspace, args.chrome_app, args.second_wave)
    server = HTTPServer(("127.0.0.1", args.port), handler_for(fixture))
    driver = Driver(fixture, processes, server.server_port, args.before_wav, args.after_wav)
    def cancel(signum, frame):
        driver.cancelled.set()
    signal.signal(signal.SIGINT, cancel)
    signal.signal(signal.SIGTERM, cancel)
    worker = threading.Thread(target=server.serve_forever)
    worker.start()
    try:
        driver.run()
    finally:
        server.shutdown()
        worker.join(3)
        server.server_close()
        if worker.is_alive():
            driver.receipt("server-cleanup-failed")
            raise ProtocolError("Fixture server thread did not join.")
        driver.receipt("fixture-server-joined", protocolComplete=driver.protocol_complete,
                       failure=driver.failure, ownedProcessesJoined=driver.owned_joined,
                       liveOwnedChildren=0 if driver.owned_joined else None, serverRunning=False)


if __name__ == "__main__":
    main()
