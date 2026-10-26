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
import re
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
        self.identity_receipt = None
        self.relocated_bundles = {}
        self.executable_proofs = {}
        self.proven_candidate_pids = set()
        self.launch_executable_sha256 = digest(self.executable)
        self.launch_signature = self.signature_identity(self.executable, None)

    def clone_parent(self, deadline):
        temporary = subprocess.check_output(["/usr/bin/getconf", "DARWIN_USER_TEMP_DIR"], text=True,
                                            timeout=self.process_timeout(deadline)).strip()
        directory = Path(temporary).resolve(strict=True)
        if directory.name != "T" or directory.stat().st_uid != os.getuid():
            raise ProtocolError("Cannot establish this user's OS-managed clone directory.")
        return directory.parent / "X" / "com.google.Chrome.code_sign_clone"

    def file_stamp(self, path):
        info = regular_file(path)
        if path.resolve(strict=True) != path:
            raise ProtocolError("Signed executable proof requires canonical regular files.")
        return (info.st_dev, info.st_ino, info.st_uid, info.st_mode, info.st_size,
                info.st_mtime_ns, info.st_ctime_ns)

    def signature_identity(self, path, deadline):
        output = subprocess.check_output(["/usr/bin/codesign", "--display", "--verbose=4", "-r-", str(path)],
                                         stderr=subprocess.STDOUT, text=True,
                                         timeout=self.process_timeout(deadline))
        identity = {}
        for line in output.splitlines():
            for field in ("CDHash", "TeamIdentifier"):
                if line.startswith(field + "="):
                    identity[field] = line.split("=", 1)[1]
            if line.startswith("designated => "):
                identity["designatedRequirement"] = line.removeprefix("designated => ")
        if (not re.fullmatch(r"[0-9a-fA-F]{40}", identity.get("CDHash", ""))
                or not re.fullmatch(r"[A-Z0-9]{10}", identity.get("TeamIdentifier", ""))
                or not identity.get("designatedRequirement")):
            raise ProtocolError("Signed executable lacks a complete CDHash, team or designated requirement.")
        return identity

    def equivalent_executable(self, child, expected, observed, deadline, bundle=None):
        expected, observed = Path(expected), Path(observed)
        # Signature bytes are in the executable. Include resource-seal/Info stamps for a
        # bundle proof, and inode/ctime so writes or replacements invalidate cached proof.
        paths = [expected, observed]
        if bundle is not None:
            paths += [app / "Contents" / name for app in (self.chrome_app, bundle)
                      for name in ("Info.plist", "_CodeSignature/CodeResources")]
        stamps = tuple(self.file_stamp(path) for path in paths)
        if stamps[0][4] != stamps[1][4]:
            raise ProtocolError("Relocated executable size differs from the verified owned copy.")
        if bundle is not None:
            # A seal's own stamp cannot establish that all sealed nested files stayed
            # unchanged. Revalidate the whole clone on every leader guard, even on cache hits.
            subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(bundle)],
                           check=True, timeout=self.process_timeout(deadline, limit=20), stdin=subprocess.DEVNULL,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        key = (child.pid, str(expected), str(observed), stamps)
        if key in self.executable_proofs:
            if stamps != tuple(self.file_stamp(path) for path in paths):
                raise ProtocolError("Signed executable changed during cached relocation verification.")
            return self.executable_proofs[key]
        def digest(path):
            result = hashlib.sha256()
            with path.open("rb") as stream:
                while block := stream.read(1024 * 1024):
                    self.process_timeout(deadline)
                    result.update(block)
            return result.hexdigest()
        expected_hash, observed_hash = digest(expected), digest(observed)
        if expected_hash != observed_hash or (expected == self.executable and expected_hash != self.launch_executable_sha256):
            raise ProtocolError("Relocated executable bytes differ from the verified owned copy.")
        for target in (expected, observed):
            arguments = ["/usr/bin/codesign", "--verify", "--strict"]
            subprocess.run(arguments + [str(target)], check=True, timeout=self.process_timeout(deadline),
                           stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        identity = self.signature_identity(expected, deadline)
        if (self.signature_identity(observed, deadline) != identity
                or (expected == self.executable and identity != self.launch_signature)):
            raise ProtocolError("Relocated executable signature differs from the verified owned copy.")
        if stamps != tuple(self.file_stamp(path) for path in paths):
            raise ProtocolError("Signed executable changed during relocation verification.")
        proof = dict(sha256=expected_hash, **identity)
        self.executable_proofs[key] = proof
        return proof

    def prove_relocated_leader(self, child, executable, deadline):
        if (child.process is None or child.process.pid != child.pid or child.process.poll() is not None
                or self.children.get(child.pid) is not child):
            raise ProtocolError("Relocation requires the live owned spawned Chrome child.")
        observed = Path(executable)
        bundle = observed.parent.parent.parent
        if (observed != bundle / "Contents/MacOS/Google Chrome"
                or bundle.name != "Google Chrome.app.bundle"
                or not re.fullmatch(r"code_sign_clone\.[A-Za-z0-9]{6}", bundle.parent.name)
                or bundle.parent.parent != self.clone_parent(deadline)
                or observed.resolve(strict=True) != observed):
            raise ProtocolError("Executable is not this user's canonical OS-managed Chrome clone.")
        proof = self.equivalent_executable(child, self.executable, observed, deadline, bundle=bundle)
        if self.poll(child) is not None or self.group_for(child.pid) != child.pid:
            raise ProtocolError("Owned Chrome lifetime changed during relocation verification.")
        self.relocated_bundles[child.pid] = bundle
        self.proven_candidate_pids.add(child.pid)
        self.record_identity("owned-executable-relocation-proven", processID=child.pid,
                             originalExecutable=str(self.executable), relocatedExecutable=executable,
                             relocatedBundle=str(bundle), **proof)
        return True

    def relocated_member(self, child, pid, executable, deadline):
        bundle = self.relocated_bundles.get(child.pid)
        if bundle is None:
            return False
        observed = Path(executable)
        try:
            relative = observed.relative_to(bundle)
        except ValueError:
            return False
        self.equivalent_executable(child, self.chrome_app / relative, observed, deadline,
                                   bundle=bundle if pid == child.pid else None)
        self.proven_candidate_pids.add(pid)
        return True

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

    def process_timeout(self, deadline, limit=5):
        # Deep bundle verification is slower than process inspection; neither may
        # extend an explicit absolute ownership or cleanup deadline.
        remaining = limit if deadline is None else deadline - time.monotonic()
        if remaining <= 0:
            raise ProtocolError("Owned process verification deadline expired.")
        return min(limit, remaining)

    def arguments_for(self, pid, deadline=None):
        return subprocess.check_output(["/bin/ps", "-p", str(pid), "-o", "command="], text=True,
                                       timeout=self.process_timeout(deadline)).strip()

    def group_members(self, group, deadline=None):
        output = subprocess.check_output(["/bin/ps", "-axo", "pid=,pgid=,stat="], text=True,
                                         timeout=self.process_timeout(deadline))
        return [int(pid) for pid, pgid, state in (line.split() for line in output.splitlines())
                if int(pgid) == group and not state.startswith("Z")]

    def assert_owned(self, child, deadline=None, require_live=True):
        deadline = deadline if deadline is not None else time.monotonic() + 30
        if self.children.get(child.pid) is not child:
            raise ProtocolError("Refuse to signal a foreign process.")
        if self.poll(child) is not None:
            if require_live:
                raise ProtocolError("Refuse to signal an exited process.")
            return []
        expected = str(self.executable) if child.kind == "chrome" else "/usr/bin/afplay"
        leader_proof = None
        observation = dict(processID=child.pid, kind=child.kind, expectedExecutable=expected,
                           expectedProcessGroup=child.pid, launchedExecutable=child.args[0])
        try:
            observation["observedExecutable"] = self.executable_for(child.pid)
            observation["observedProcessGroup"] = self.group_for(child.pid)
            predicates = dict(executableMatches=observation["observedExecutable"] == expected,
                              processGroupMatches=observation["observedProcessGroup"] == child.pid,
                              launchedExecutableMatches=child.args[0] == expected)
            observation["predicates"] = predicates
            if child.kind == "chrome":
                profile = f"--user-data-dir={self.profile}"
                arguments = self.arguments_for(child.pid, deadline).split()
                # The URL contains an ephemeral fixture token. Retain actual process arguments
                # for diagnosis without copying that query into the private ownership journal.
                observation["observedArguments"] = [
                    argument.split("?", 1)[0] + "?<fixture-query-redacted>"
                    if argument.startswith("http://127.0.0.1:") else argument for argument in arguments]
                observation["expectedProfileArgument"] = profile
                predicates.update(launchedProfileMatches=profile in child.args,
                                  observedProfileMatches=profile in arguments)
                if not predicates["executableMatches"] and all(value for name, value in predicates.items()
                                                                 if name != "executableMatches"):
                    observed_stamp = self.file_stamp(Path(observation["observedExecutable"]))
                    predicates["relocatedExecutableMatches"] = self.prove_relocated_leader(
                        child, observation["observedExecutable"], deadline)
                    leader_proof = (child, observation["observedExecutable"], observed_stamp)
            observation["predicates"] = predicates
        except Exception as error:
            observation["observationError"] = str(error)
            self.record_identity("ownership-identity", **observation)
            raise
        self.record_identity("ownership-identity", **observation)
        failed = [name for name, matches in predicates.items() if not matches
                  and not (name == "executableMatches" and predicates.get("relocatedExecutableMatches"))]
        if failed:
            raise ProtocolError("Owned process identity does not match: " + ", ".join(failed) + ".")
        verified = self.verify_members(child, self.group_members(child.pid, deadline), deadline,
                                       leader_proof=leader_proof)
        if require_live:
            self.require_live_owner(child, verified)
        return verified

    def record_identity(self, step, **fields):
        if self.identity_receipt is not None:
            self.identity_receipt(step, **fields)

    def copied_bundle_processes(self, deadline):
        """Report surviving copy users, including detached helpers; never signal them."""
        output = subprocess.check_output(
            ["/bin/ps", "-U", str(os.getuid()), "-o", "pid=,pgid=,stat=,comm="], text=True,
            timeout=self.process_timeout(deadline))
        remaining = []
        for row in output.splitlines():
            if time.monotonic() >= deadline:
                raise ProtocolError("Copied Chrome cleanup inspection deadline expired.")
            pid, group, state, command = row.split(None, 3)
            if state.startswith("Z"):
                continue
            known = int(group) in self.children or int(pid) in self.proven_candidate_pids
            if not known and "Google Chrome" not in command and "chrome_crashpad_handler" not in command:
                continue
            try:
                executable = self.executable_for(int(pid))
            except (ProtocolError, ProcessLookupError) as error:
                if known:
                    raise ProtocolError(f"Cannot inspect an owned candidate PID {pid}; cleanup is unverified.") from error
                self.record_identity("unknown-foreign-process-inspection", processID=int(pid), processGroup=int(group),
                                     owned=False, signalled=False)
                continue
            if (executable.startswith(str(self.chrome_app) + "/")
                    or any(executable.startswith(str(bundle) + "/") for bundle in self.relocated_bundles.values())):
                remaining.append(dict(processID=int(pid), processGroup=int(group), executablePath=executable))
        return remaining

    def require_live_owner(self, child, verified):
        if self.children.get(child.pid) is not child or child.pid not in verified or self.poll(child) is not None:
            raise ProtocolError("Owned live leader disappeared during verification.")

    def verify_members(self, child, members, deadline=None, leader_proof=None):
        deadline = deadline if deadline is not None else time.monotonic() + 30
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
                pending, verified, leader_proof = list(current), [], None
                continue
            owned_player = child.kind == "player" and pid == child.pid and executable == "/usr/bin/afplay"
            owned_chrome = False
            if child.kind == "chrome":
                if pid == child.pid and leader_proof is not None:
                    # Reuse only the full clone verification performed earlier in this
                    # assert_owned call. Never persist this proof across guards.
                    proven_child, proven_path, proven_stamp = leader_proof
                    profile = f"--user-data-dir={self.profile}"
                    if (proven_child is not child or self.children.get(pid) is not child
                            or child.process is None or child.process.pid != pid
                            or child.process.poll() is not None or self.poll(child) is not None
                            or executable != proven_path
                            or self.file_stamp(Path(executable)) != proven_stamp
                            or self.group_for(pid) != child.pid
                            or profile not in child.args
                            or profile not in self.arguments_for(pid, deadline).split()):
                        raise ProtocolError("Owned leader changed after signed-clone verification.")
                    owned_chrome = True
                elif executable.startswith(str(self.chrome_app) + "/"):
                    owned_chrome = True
                else:
                    owned_chrome = self.relocated_member(child, pid, executable, deadline)
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
        # One absolute budget includes full signed-clone proof, signalling and join.
        deadline = time.monotonic() + 30
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
        if deadline is not None and time.monotonic() >= deadline:
            raise ProtocolError("Owned process termination deadline expired.")
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
        if any(child.kind == "chrome" for child in self.children.values()):
            try:
                # Detached vendor helpers can exit shortly after their joined browser.
                # Observe natural exit only; an unproven process is never signalled.
                deadline = time.monotonic() + 3
                remaining = self.copied_bundle_processes(deadline)
                while remaining and time.monotonic() < deadline:
                    time.sleep(0.025)
                    if time.monotonic() >= deadline:
                        break
                    remaining = self.copied_bundle_processes(deadline)
                if remaining:
                    self.record_identity("unresolved-copied-bundle-processes", processes=remaining,
                                         signalled=False, ownershipProven=False)
                    errors.append("Copied Chrome processes remain outside joined-child proof; no extra signals sent.")
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
        self.preflight_complete = False
        self.failure = None
        self.state_path = fixture.root / "driver-state.json"
        journal = fixture.root / "driver-events.jsonl"
        if self.state_path.exists() or self.state_path.is_symlink() or journal.exists() or journal.is_symlink():
            raise ProtocolError("Use a fresh driver run.")
        self.processes.identity_receipt = self.receipt

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

    def run(self, preflight_only=False):
        try:
            self.check()
            browser = self.processes.chrome(self.url("browserBefore", self.before))
            self.receipt("browser-launched", processID=browser.pid, executablePath=browser.args[0])
            self.until(lambda: self.fixture.prepared_phase == "browserBefore", 30)
            self.processes.assert_owned(browser)
            self.receipt("prepared-before-capture", processID=browser.pid, speechStarted=False,
                         identityVerified=True)
            if preflight_only:
                if any((self.fixture.root / name).exists() or (self.fixture.root / name).is_symlink()
                       for name in ("capture-ready.json", "phase-command.json", "phase-ack.json", "outcome.json")):
                    raise ProtocolError("Preflight requires no native capture or phase files.")
                self.preflight_complete = True
                self.receipt("preflight-complete", nativeCaptureStarted=False, speechStarted=False,
                             cuaPlayClicks=0)
                return
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
                             preflightComplete=self.preflight_complete, failure=self.failure, liveOwnedChildren=0)
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
    parser.add_argument("--preflight-only", action="store_true",
                        help="Prepare the browser, verify identity and join cleanup without native capture or Play")
    args = parser.parse_args()
    if (args.chrome_app != args.workspace / "Google Chrome.app" or args.second_wave.parent != args.stimulus_dir
            or not NAME.fullmatch(args.second_wave.name) or args.before_wav == args.after_wav
            or not NAME.fullmatch(args.before_wav) or not NAME.fullmatch(args.after_wav) or not 1 <= args.port <= 65535):
        parser.error("Use the workspace's Google Chrome copy, distinct named WAVs and one localhost port.")
    if args.dry_run:
        if args.preflight_only:
            print(json.dumps(dict(runID=str(uuid.UUID(args.run_id)).upper(), mode="prepare-identity-cleanup",
                nativeCaptureStarted=False, speechStarted=False, applicationLaunched=False, serverStarted=False,
                prepareLimitSeconds=30, cuaPlayClicks=0)))
            return
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
        driver.run(preflight_only=args.preflight_only)
    finally:
        server.shutdown()
        worker.join(3)
        server.server_close()
        if worker.is_alive():
            driver.receipt("server-cleanup-failed")
            raise ProtocolError("Fixture server thread did not join.")
        driver.receipt("fixture-server-joined", protocolComplete=driver.protocol_complete,
                       preflightComplete=driver.preflight_complete,
                       failure=driver.failure, ownedProcessesJoined=driver.owned_joined,
                       liveOwnedChildren=0 if driver.owned_joined else None, serverRunning=False)


if __name__ == "__main__":
    main()
