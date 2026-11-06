#!/usr/bin/env python3
"""Run the registered native standalone probes and retain their actual outcomes."""

import argparse
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import platform
import signal
import stat
import subprocess
import sys
import tempfile
import time
import traceback


CANCEL_GRACE_SECONDS = 2
KILL_WAIT_SECONDS = 2
PROCESS_MARKER = "standalone-regression.process.json"


def owned_file(path, flags):
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        pass
    else:
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
            raise ValueError(f"Ownership file must be a regular file with one link: {path.name}")
    descriptor = os.open(path, (flags & ~os.O_TRUNC) | os.O_NOFOLLOW, 0o600)
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
            raise ValueError(f"Ownership file changed: {path.name}")
        if flags & os.O_TRUNC:
            os.ftruncate(descriptor, 0)
    except BaseException:
        os.close(descriptor)
        raise
    return descriptor


class RunTermination(BaseException):
    def __init__(self, signal_number):
        self.signal_number = signal_number


def interruption_status(error):
    return 128 + (error.signal_number if isinstance(error, RunTermination) else signal.SIGINT)


@contextmanager
def defer_interrupts():
    previous = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM})
    try:
        yield
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous)


@contextmanager
def suite_signal_handlers():
    depth = 0
    pending = None

    def deliver(number):
        if number == signal.SIGINT:
            raise KeyboardInterrupt()
        raise RunTermination(number)

    def handle(number, frame):
        nonlocal pending
        if depth:
            pending = pending or number
        else:
            deliver(number)

    @contextmanager
    def protect_creation():
        nonlocal depth, pending
        depth += 1
        try:
            yield
        finally:
            depth -= 1
            if not depth and pending:
                number, pending = pending, None
                deliver(number)

    originals = {number: signal.getsignal(number) for number in (signal.SIGINT, signal.SIGTERM)}
    failure = None
    try:
        with defer_interrupts():
            for number in originals:
                signal.signal(number, handle)
        yield protect_creation
    except BaseException as error:
        failure = error
        raise
    finally:
        # Consume signals queued during restoration before reinstating the
        # caller's mask, which could otherwise deliver TERM to SIG_DFL.
        previous = signal.pthread_sigmask(signal.SIG_BLOCK, set(originals))
        queued = set()
        try:
            for number, original in originals.items():
                signal.signal(number, original)
            queued = signal.sigpending() & (set(originals) - previous)
            for number in queued:
                signal.sigwait({number})
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous)
        if queued and failure is None:
            deliver(signal.SIGTERM if signal.SIGTERM in queued else signal.SIGINT)


def process_group_exists(group):
    if type(group) is not int or group <= 1:
        raise ValueError("Invalid owned process group")
    try:
        os.killpg(group, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        # EPERM is not proof of absence. Darwin can return it while a killed
        # group is disappearing; inspect its members before releasing ownership.
        return True
    return True


def live_process_group(group):
    if not process_group_exists(group):
        return False
    # Zombies cannot keep writing and may wait for an external init to reap them.
    # Darwin can select the owned group in the kernel rather than scanning every
    # process (including slow, unrelated process metadata).
    if sys.platform == "darwin":
        selection = ["-g", str(group)]
    else:
        selection = ["-A"]
    completed = subprocess.run(["ps", *selection, "-o", "pgid=", "-o", "stat="],
                               capture_output=True, text=True, timeout=2)
    if completed.returncode not in (0, 1) or completed.stderr.strip() or (completed.returncode == 1 and completed.stdout.strip()):
        raise OSError(f"Cannot inspect owned process group: ps exit {completed.returncode}")
    for line in completed.stdout.splitlines():
        fields = line.split()
        if len(fields) != 2 or not fields[0].isdigit():
            raise OSError("Cannot inspect owned process group: malformed ps output")
        if fields[0] == str(group) and not fields[1].startswith("Z"):
            return True
    return False


def stop_process_group(process):
    with defer_interrupts():
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        deadline = time.monotonic() + CANCEL_GRACE_SECONDS
        # No external inspection can delay escalation. In particular, a stalled
        # ps must never leave a TERM-ignoring descendant runnable during cleanup.
        while process_group_exists(process.pid) and time.monotonic() < deadline:
            process.poll()
            time.sleep(min(0.02, max(0, deadline - time.monotonic())))
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        # Reap the direct child even if the subsequent descendant inspection
        # fails. An unobservable group keeps its ownership marker and fails.
        process.wait(timeout=KILL_WAIT_SECONDS)
        deadline = time.monotonic() + KILL_WAIT_SECONDS
        while live_process_group(process.pid):
            if time.monotonic() >= deadline:
                raise OSError("Owned descendants did not stop; this worktree remains reserved")
            time.sleep(0.02)


def run_owned_process(command, root, stream, protect_creation):
    marker = root / ".build" / PROCESS_MARKER
    process = None
    failure = None
    try:
        # Defer handler delivery rather than blocking OS signals: children must
        # inherit their normal signal mask. Record ownership before delivering.
        with protect_creation():
            process = subprocess.Popen(command, cwd=root, stdin=subprocess.DEVNULL,
                                       stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
            with os.fdopen(owned_file(marker, os.O_WRONLY | os.O_CREAT | os.O_TRUNC), "w") as output:
                output.write(json.dumps({"processGroup": process.pid}) + "\n")
        code = process.wait()
        if live_process_group(process.pid):
            stop_process_group(process)
            return code, "Probe left unjoined descendant processes"
        return code, None
    except BaseException as error:
        failure = error
        if process is not None:
            try:
                stop_process_group(process)
            except (OSError, subprocess.SubprocessError) as cleanup_error:
                error.cleanup_error = str(cleanup_error)
            error.child_exit_code = process.returncode
        raise
    finally:
        if process is not None:
            try:
                if not live_process_group(process.pid):
                    marker.unlink(missing_ok=True)
            except (OSError, ValueError, subprocess.SubprocessError) as inspection_error:
                if failure is not None:
                    failure.inspection_error = str(inspection_error)
                else:
                    inspection_error.child_exit_code = process.returncode
                    raise


@dataclass(frozen=True)
class Probe:
    script: str
    interpreter: str
    requires_ui: bool = False

    @property
    def name(self):
        return Path(self.script).stem.removeprefix("run_").removesuffix("_tests")

    @property
    def command(self):
        interpreters = {"python3": sys.executable, "sh": "/bin/sh", "bash": "/bin/bash"}
        return [interpreters[self.interpreter], self.script]


# Registration is explicit: a new probe needs a reviewed interpreter/UI classification.
# This reviewed orchestrator invokes the complete CI sequence; it is not a leaf probe.
ORCHESTRATOR_SCRIPTS = {"Tests/run_ci_checks.sh"}
SHELL_PROBES = (
    "account_session", "mobile_account", "admitted_history_writes", "admitted_pronunciation_read", "analytics_config", "analytics_private_profile", "app_search_private_profile", "apple_speech_lifecycle", "brand_logo_rendering", "brand_owned_native_menu", "brand_profile",
    "command_archive_search", "command_cancellation", "command_markdown",
    "credential_startup", "command_model_catalog", "command_session_boundary", "command_ui_localization", "command_workspace_presentation",
    "dictation_accessibility_preparation", "dictation_prompt_defaults", "dictation_prompt_request", "dictionary_correction",
    "dictionary_matcher_experiment", "dictionary_inline_focus", "factory_brand_vocabulary", "file_error_localization", "file_export", "file_operation_isolation",
    "file_history_publisher", "file_transcript_relative_date", "file_transcript_rename", "file_transcript_view",
    "fluid_serve", "fluid_typography", "history_decode_recovery", "history_persistence", "hotkey_initialization",
    "local_text_model_catalog", "meeting_capture_pcm", "meeting_capture_activity", "meeting_microphone_capture_contracts", "meeting_pending_speech", "native_window_appearance",
    "meeting_private_view", "n4_file_private_projection", "meeting_summary_evidence", "meeting_audio_export", "onboarding",
    "page_presentation", "participant_input_contrast", "paste_command_event", "paste_key_cache", "paste_read_receipt", "paste_recovery_policy", "private_profile_defaults", "private_profile_logging", "private_profile_stores", "private_ai_idle_unloader", "provider_dictation_capture_options",
    "release_highlights", "settings_owned_copy", "settings_viewport", "speech_model_provider_presentation", "ui_contrast",
    "stats_snapshot", "terminal_service_lifecycle", "voice_edit_cancellation",
)
PYTHON_PROBES = (
    "delivery_failure_copy", "dictation_context_profile", "diarization_repeatability", "dictionary_training_save", "dictation_capture_admission", "fluid_audio_capture_options", "gigaam_artifact_ownership", "gigaam_encoder_dictionary_storage", "local_api_lease", "local_api_live_harness", "meeting_audio_scope", "meeting_backup_refresh",
    "meeting_speaker_attribution", "mobile_recording_activity_lifecycle",
    "private_capture_feedback", "private_profile_activation_summary", "private_panel_concealment", "settings_backup_concurrency",
)
PROBES = tuple(sorted(
    [Probe(f"Tests/run_{name}_tests.sh", "sh") for name in SHELL_PROBES]
    + [Probe(f"Tests/run_{name}_tests.py", "python3") for name in PYTHON_PROBES]
    + [Probe("Tests/run_clipboard_backup_reproduction.sh", "sh"),
       Probe("Tests/run_overlay_captions.sh", "sh"),
       Probe("Tests/run_history_private_projection_tests.sh", "bash"),
       Probe("Tests/run_history_inline_audio_private_tests.sh", "bash"),
       Probe("Tests/run_meeting_asr_prepared_provider_tests.sh", "bash"),
       Probe("Tests/run_meeting_idle_prepared_resource_tests.sh", "bash"),
       Probe("Tests/run_meeting_privacy_context_tests.sh", "bash"),
       Probe("Tests/run_meeting_session_store_checkpoint_tests.sh", "bash"),
       Probe("Tests/run_meeting_universal_title_engine_tests.sh", "bash"),
       Probe("Tests/run_meeting_timeline_trace_tests.sh", "sh"),
       Probe("Tests/run_meeting_streaming_echo_tests.sh", "bash"),
       Probe("Tests/run_process_cpu_diagnostics_tests.sh", "bash"),
       Probe("Tests/run_publication_composition_tests.sh", "bash"),
       Probe("Tests/run_publication_consent_tests.sh", "bash"),
       Probe("Tests/run_publication_outbox_tests.sh", "bash"),
       Probe("Tests/run_transcript_privacy_tests.sh", "bash"),
       Probe("Tests/run_sensitive_topic_classifier_tests.sh", "bash"),
       Probe("Tests/run_sensitive_policy_settings_tests.sh", "bash"),
       Probe("Tests/run_privacy_idle_preparation_tests.sh", "bash"),
       Probe("Tests/run_upstream_sync_tests.sh", "bash"),
       Probe("Tests/run_update_prompt_tests.sh", "sh", requires_ui=True)],
    key=lambda probe: probe.name,
))


def validate_registry(root, probes=PROBES):
    registered = {probe.script for probe in probes}
    if len(registered) != len(probes) or len({probe.name for probe in probes}) != len(probes):
        raise ValueError("Standalone registry contains duplicate paths or names")
    discovered = {str(path.relative_to(root)) for path in (root / "Tests").glob("run_*")
                  if path.suffix in (".sh", ".py") and str(path.relative_to(root)) not in ORCHESTRATOR_SCRIPTS}
    if registered != discovered:
        raise ValueError(f"Standalone registry mismatch: unregistered={sorted(discovered - registered)}, missing={sorted(registered - discovered)}")
    for probe in probes:
        path = root / probe.script
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"Standalone probe must be a regular tracked script: {probe.script}")
        first_line = path.read_text().splitlines()[0]
        expected = {"sh": ("#!/bin/sh",), "bash": ("#!/bin/bash", "#!/usr/bin/env bash"),
                    "python3": ("#!/usr/bin/env python3",)}.get(probe.interpreter, ())
        if first_line not in expected:
            raise ValueError(f"Review changed interpreter for {probe.script}: {first_line}")


def select_probes(names, probes=PROBES):
    if not names:
        return probes
    unknown = set(names) - {probe.name for probe in probes}
    if unknown:
        raise ValueError(f"Unknown standalone probe(s): {', '.join(sorted(unknown))}; use --list")
    return tuple(probe for probe in probes if probe.name in set(names))


@contextmanager
def run_lock(root):
    build = root / ".build"
    if build.is_symlink():
        raise ValueError("Standalone build storage must belong to this worktree")
    build.mkdir(exist_ok=True)
    with os.fdopen(owned_file(build / "standalone-regression.lock", os.O_RDWR | os.O_CREAT | os.O_APPEND), "a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ValueError("A standalone regression run is already active in this worktree") from error
        try:
            marker = build / PROCESS_MARKER
            try:
                descriptor = owned_file(marker, os.O_RDONLY)
            except FileNotFoundError:
                pass
            else:
                with os.fdopen(descriptor, "r") as source:
                    group = json.load(source)["processGroup"]
                if live_process_group(group):
                    raise ValueError("A previous probe still owns this worktree's build storage")
                marker.unlink()
            yield
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def timestamp():
    return datetime.now(timezone.utc).isoformat()


def run_suite(root, probes, *, include_ui=False, revision="unknown", dirty=False):
    state = {}
    try:
        with suite_signal_handlers() as protect_creation:
            return _run_suite(root, probes, include_ui=include_ui, revision=revision, dirty=dirty,
                              protect_creation=protect_creation, state=state)
    except (KeyboardInterrupt, RunTermination) as error:
        code = interruption_status(error)
        if state:
            report = state["report"]
            with defer_interrupts():
                state["record_interruption"](error)
                state["finish"](True, code)
        else:
            report = {"status": "FAIL", "interrupted": True, "runnerExitCode": code,
                      "reason": "Interrupted before suite started", "results": [],
                      "counts": {"total": len(probes), "passed": 0, "failed": 0, "skipped": len(probes)}}
        return code, report


def _run_suite(root, probes, *, include_ui, revision, dirty, protect_creation, state):
    root = root.resolve()
    with run_lock(root):
        base = root / ".build/standalone-regression"
        if base.is_symlink():
            raise ValueError("Standalone artifacts must belong to this worktree")
        base.mkdir(exist_ok=True)
        directory = Path(tempfile.mkdtemp(prefix=f"{datetime.now(timezone.utc):%Y%m%dT%H%M%SZ}-{revision[:8]}-", dir=base))
        report = {"version": 1, "revision": revision, "workingTree": "dirty" if dirty else "clean",
                  "platform": platform.system(), "startedAt": timestamp(), "status": "RUNNING",
                  "artifactDirectory": str(directory), "uiOptIn": include_ui, "results": []}
        print(f"Standalone artifacts: {directory}", flush=True)

        def save():
            results = report["results"]
            report["counts"] = {"total": len(probes), "passed": sum(item["status"] == "PASS" for item in results),
                                "failed": sum(item["status"] == "FAIL" for item in results),
                                "skipped": sum(item["status"] == "SKIP" for item in results)}
            temporary = directory / "summary.json.tmp"
            temporary.write_text(json.dumps(report, indent=2) + "\n")
            temporary.replace(directory / "summary.json")

        def make_row(probe):
            return {"name": probe.name, "script": probe.script, "interpreter": probe.interpreter,
                    "command": probe.command, "requiresUI": probe.requires_ui, "status": "RUNNING",
                    "exitCode": None, "durationSeconds": 0.0, "log": f"{probe.name}.log"}

        def record_interruption(error):
            code = interruption_status(error)
            for row in report["results"]:
                if row["status"] == "RUNNING":
                    row.update(status="FAIL", exitCode=getattr(error, "child_exit_code", None),
                               runnerExitCode=code, reason="interrupted")
                    (directory / row["log"]).touch()
            for probe in probes[len(report["results"]):]:
                row = make_row(probe)
                row.update(status="SKIP", reason="not run after interruption")
                (directory / row["log"]).write_text("SKIP: not run after interruption\n")
                report["results"].append(row)
            save()

        def finish(interrupted, interrupt_code):
            counts = report["counts"]
            report["interrupted"] = interrupted
            report["runnerExitCode"] = interrupt_code if interrupted else (0 if counts["passed"] and not counts["failed"] else 1)
            report["status"] = "PASS" if counts["passed"] and not counts["failed"] and not interrupted else "FAIL"
            if interrupted:
                report["reason"] = "Run interrupted"
            elif not counts["passed"] and not counts["failed"]:
                report["reason"] = "No probes executed successfully"
            report["finishedAt"] = timestamp()
            save()
            lines = [f"Revision: {revision} ({report['workingTree']})", f"Status: {report['status']}",
                     f"Probes: {counts['total']} total, {counts['passed']} passed, {counts['failed']} failed, {counts['skipped']} skipped"]
            lines += [f"{row['status']} {row['name']} exit={row['exitCode']} log={row['log']}" for row in report["results"]]
            (directory / "summary.txt").write_text("\n".join(lines) + "\n")
            print(lines[2], flush=True)

        state.update(report=report, record_interruption=record_interruption, finish=finish)
        save()
        interrupted = False
        interrupt_code = 130
        abort_reason = None
        try:
            for probe in probes:
                row = make_row(probe)
                report["results"].append(row)
                log = directory / row["log"]
                if interrupted or abort_reason or (probe.requires_ui and not include_ui):
                    row.update(status="SKIP", reason="not run after interruption" if interrupted else (abort_reason or "UI probe requires --include-ui"))
                    log.write_text(f"SKIP: {row['reason']}\n")
                elif not (root / probe.script).is_file():
                    row.update(status="FAIL", reason="registered script missing")
                    log.write_text(f"FAIL: {row['reason']}\n")
                else:
                    save()
                    print(f"RUN {probe.name}", flush=True)
                    start = time.monotonic()
                    with log.open("wb") as stream:
                        try:
                            code, ownership_error = run_owned_process(probe.command, root, stream, protect_creation)
                            row.update(status="PASS" if code == 0 and not ownership_error else "FAIL", exitCode=code)
                            if ownership_error:
                                row["reason"] = ownership_error
                        except (OSError, ValueError, subprocess.SubprocessError) as error:
                            row.update(status="FAIL", reason=str(error), exitCode=getattr(error, "child_exit_code", None))
                            stream.write(f"Runner error: {error}\n".encode())
                            stream.write(traceback.format_exc().encode())
                            if (root / ".build" / PROCESS_MARKER).exists():
                                abort_reason = "not run while previous process cleanup is incomplete"
                        except (KeyboardInterrupt, RunTermination) as error:
                            interrupt_code = interruption_status(error)
                            row.update(status="FAIL", exitCode=getattr(error, "child_exit_code", None),
                                       runnerExitCode=interrupt_code, reason="interrupted")
                            if hasattr(error, "cleanup_error"):
                                row["cleanupError"] = error.cleanup_error
                            if hasattr(error, "inspection_error"):
                                row["inspectionError"] = error.inspection_error
                            interrupted = True
                    row["durationSeconds"] = round(time.monotonic() - start, 3)
                print(f"{row['status']} {probe.name}", flush=True)
                save()
        except (KeyboardInterrupt, RunTermination) as error:
            interrupted = True
            interrupt_code = interruption_status(error)
            record_interruption(error)
        while True:
            try:
                with defer_interrupts():
                    finish(interrupted, interrupt_code)
                return report["runnerExitCode"], report
            except (KeyboardInterrupt, RunTermination) as error:
                interrupted = True
                interrupt_code = interruption_status(error)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list", action="store_true", help="List registered probes without running them")
    parser.add_argument("--only", action="append", metavar="NAME", help="Run a named probe; repeat for several")
    parser.add_argument("--include-ui", action="store_true", help="Also run the update prompt probe, which can activate UI")
    arguments = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    try:
        validate_registry(root)
        probes = select_probes(arguments.only)
        if arguments.list:
            for probe in probes:
                print(f"{probe.name}\t{probe.interpreter}\t{'UI opt-in' if probe.requires_ui else 'native'}")
            return 0
        subprocess.run(["bash", "scripts/dev/assert-worktree.sh"], cwd=root, check=True)
        if platform.system() != "Darwin":
            raise ValueError("Native standalone regressions require macOS and full Xcode; --list and runner unit tests are portable")
        developer = os.environ.get("DEVELOPER_DIR") or subprocess.check_output(["xcode-select", "-p"], text=True).strip()
        if not (Path(developer) / "Platforms/MacOSX.platform").is_dir():
            raise ValueError("Select an installed full Xcode before running native standalone regressions")
        os.environ["DEVELOPER_DIR"] = developer
        revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
        dirty = bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=root, text=True).strip())
        status, _ = run_suite(root, probes, include_ui=arguments.include_ui, revision=revision, dirty=dirty)
        return status
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Standalone regression setup failed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
