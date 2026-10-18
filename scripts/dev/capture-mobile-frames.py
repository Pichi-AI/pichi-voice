#!/usr/bin/env python3
"""Save native mobile frames at one-second cadence and index pixel changes locally.

Requires Xcode and Pillow. The default uses devicectl or simctl screenshots.
For physical devices, --stream-device-id selects ONLY that exact paired muxed
screen, using an isolated source-hash/compiler-keyed native video-only tool.
Existing video authorization is required; no prompts or camera fallback.
READY.json means the first streamed frame was decoded and indexed successfully.
Never deletes frames. STOP or SIGTERM requests a joined bounded shutdown.
--self-test runs synthetic transport/index tests without opening any device.
"""
import argparse
import hashlib
import json
import os
import shutil
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

from PIL import Image


NATIVE_STOP_GRACE_SECONDS = 3
NATIVE_TERMINATE_GRACE_SECONDS = 2
NATIVE_KILL_GRACE_SECONDS = 2


def utc():
    return datetime.now(timezone.utc).isoformat()


def pixel_digest(path):
    with Image.open(path) as source:
        image = source.convert("RGBA")
        digest = hashlib.sha256()
        digest.update(f"{image.width}x{image.height}:RGBA:".encode())
        digest.update(image.tobytes())
        return digest.hexdigest(), list(image.size)


def join_native_process(process):
    """Reap only the child we own, escalating when its native stop is stuck."""
    if process.poll() is not None:
        return process.wait(timeout=NATIVE_KILL_GRACE_SECONDS)
    process.terminate()
    try:
        return process.wait(timeout=NATIVE_TERMINATE_GRACE_SECONDS)
    except subprocess.TimeoutExpired:
        process.kill()
        return process.wait(timeout=NATIVE_KILL_GRACE_SECONDS)


def stop_preparation_group(process):
    """The compiler may have frontend children even after its driver exits."""
    def send(number):
        try:
            os.killpg(process.pid, number)
        except ProcessLookupError:
            pass
    send(signal.SIGTERM)
    try:
        process.wait(timeout=NATIVE_TERMINATE_GRACE_SECONDS)
    except subprocess.TimeoutExpired:
        pass
    send(signal.SIGKILL)
    return process.wait(timeout=NATIVE_KILL_GRACE_SECONDS)


def run_preparation(command, *, timeout, should_stop, out, **streams):
    """Keep compiler discovery/build cancellation joined before any capture opens."""
    if should_stop() or (out / "STOP").exists():
        raise InterruptedError("Capture preparation was stopped")
    process = subprocess.Popen(command, start_new_session=True, **streams)
    started = time.monotonic()
    try:
        while True:
            if should_stop() or (out / "STOP").exists():
                raise InterruptedError("Capture preparation was stopped")
            remaining = timeout - (time.monotonic() - started)
            if remaining <= 0:
                raise subprocess.TimeoutExpired(command, timeout)
            try:
                stdout, stderr = process.communicate(timeout=min(0.1, remaining))
                break
            except subprocess.TimeoutExpired:
                continue
        if process.returncode != 0:
            raise subprocess.CalledProcessError(process.returncode, command, output=stdout, stderr=stderr)
        return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
    finally:
        try:
            stop_preparation_group(process)
        finally:
            for pipe in (process.stdout, process.stderr):
                if pipe is not None:
                    pipe.close()



def capture_stream(args, out, state, should_stop):
    """Index independently of the native capture queue; retain every PNG."""
    source = Path(__file__).resolve().with_name("mobile-screen-stream.swift")
    source_bytes = source.read_bytes()
    source_hash = hashlib.sha256(source_bytes).hexdigest()
    compiler = run_preparation(["xcrun", "swiftc", "--version"], timeout=20,
                               should_stop=should_stop, out=out,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout
    build_key = hashlib.sha256(source_hash.encode() + compiler).hexdigest()
    build = source.parents[2] / ".build" / "mobile-screen-capture" / build_key
    build.mkdir(parents=True, exist_ok=True)
    binary = build / "mobile-screen-stream"
    with (out / "capture.log").open("ab") as log:
        if not binary.exists():
            temporary = build / f"compiler-{__import__('os').getpid()}"
            snapshot = build / "mobile-screen-stream.swift"
            snapshot.write_bytes(source_bytes)
            run_preparation(["xcrun", "swiftc", "-O", "-module-cache-path", str(build / "ModuleCache"),
                             str(snapshot), "-o", str(temporary)], timeout=90,
                            should_stop=should_stop, out=out, stdout=log, stderr=log)
            temporary.replace(binary)
        if should_stop() or (out / "STOP").exists():
            raise InterruptedError("Capture preparation was stopped")
        state.update(captureBackend="pairedMuxedVideoStream", nativeSourceSHA256=source_hash,
                     nativeToolSHA256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                     schedule="First delivered native frame in each one-second native PTS slot; no cached backfill",
                     audioOutputs=0, streamDeviceIDSHA256=hashlib.sha256(args.stream_device_id.encode()).hexdigest())
        process = subprocess.Popen([str(binary), "--stream-device-id", args.stream_device_id,
                                    "--output", str(out), "--prefix", f"{args.test_case}-{args.revision[:8]}",
                                    "--duration", str(args.duration)], stdout=log, stderr=log)
        previous = None
        seen = {}
        reason = "duration"
        started = time.monotonic()
        native_path = out / "native-frames.jsonl"
        reader = None
        pending_line = ""
        stop_requested_at = None
        def persist():
            state["elapsedSeconds"] = time.monotonic() - started
            temporary = out / "status.pending.json"
            temporary.write_text(json.dumps(state, indent=2))
            temporary.replace(out / "status.json")
        try:
            with (out / "frames.jsonl").open("a") as index, (out / "changed.jsonl").open("a") as changed, \
                    (out / "unique.jsonl").open("a") as unique:
                print(json.dumps(dict(captureStarted=True, output=str(out), intervalSeconds=1,
                                      captureBackend="pairedMuxedVideoStream")), flush=True)
                while True:
                    if should_stop() or (out / "STOP").exists():
                        if stop_requested_at is None:
                            stop_requested_at = time.monotonic()
                        (out / "STOP").touch(exist_ok=True)
                    # Observe exit before reading: if finished is true, the following
                    # read drains an immutable file. Never poll again for this EOF decision.
                    finished = process.poll() is not None
                    if not finished and stop_requested_at is not None and time.monotonic() - stop_requested_at >= NATIVE_STOP_GRACE_SECONDS:
                        raise TimeoutError("Native capture did not join after stop request")
                    if reader is None and native_path.exists():
                        reader = native_path.open()
                    fragment = reader.readline() if reader is not None else ""
                    pending_line += fragment
                    if not pending_line.endswith("\n"):
                        if finished:
                            if pending_line:
                                raise ValueError("Truncated native frame index")
                            break
                        if time.monotonic() - started > args.duration + 15:
                            raise TimeoutError("Native capture exceeded bounded duration")
                        time.sleep(0.05)
                        continue
                    row = json.loads(pending_line)
                    pending_line = ""
                    if row.get("kind") == "stopped":
                        state["nativeSummary"] = row["summary"]
                        reason = row["summary"]["stopReason"]
                    if row.get("kind") != "frame":
                        persist()
                        continue
                    relative = Path(row["file"])
                    if relative.is_absolute() or len(relative.parts) != 2 or relative.parts[0] != "frames" or relative.suffix != ".png":
                        raise ValueError("Invalid native frame index path")
                    target = out / relative
                    digest, dimensions = pixel_digest(target)
                    row.update(dimensions=dimensions, pixelSHA256=digest,
                               pngSHA256=hashlib.sha256(target.read_bytes()).hexdigest(),
                               changedFromPrevious=digest != previous, firstPixelOccurrence=digest not in seen,
                               matchesEarlierSecond=seen.get(digest))
                    state["savedFrames"] += 1
                    state["missedScheduleSlots"] += row["missedSlotsBefore"]
                    if row["changedFromPrevious"]:
                        state["changedFrames"] += 1
                        changed.write(json.dumps(row) + "\n"); changed.flush()
                    if row["firstPixelOccurrence"]:
                        state["uniquePixelFrames"] += 1
                        seen[digest] = row["requestedSecond"]
                        unique.write(json.dumps(row) + "\n"); unique.flush()
                    previous = digest
                    index.write(json.dumps(row) + "\n"); index.flush()
                    state["lastAttempt"] = row
                    persist()
                    if state["savedFrames"] == 1:
                        (out / "READY.json").write_text(json.dumps(dict(firstValidFrame=row["file"], nativeSourceSHA256=source_hash)))
            code = process.wait(timeout=10)
            if code != 0 or state["savedFrames"] == 0 or "nativeSummary" not in state:
                state["captureErrors"] += 1
                reason = "nativeCaptureFailure"
        except Exception as error:
            state["captureErrors"] += 1
            state["errorType"] = type(error).__name__
            reason = "nativeCaptureFailure"
            raise
        finally:
            try:
                if reader is not None:
                    reader.close()
            finally:
                try:
                    state["nativeExitCode"] = join_native_process(process)
                    state["nativeProcessJoined"] = True
                except Exception as error:
                    state["nativeProcessJoined"] = False
                    state["shutdownErrorType"] = type(error).__name__
                    state["captureErrors"] += 1
                    reason = "nativeCaptureFailure"
                    raise
                finally:
                    state.update(status="stopped", stopReason=reason, endedAtUTC=utc())
                    persist()
    print(json.dumps({k: state[k] for k in ["status", "stopReason", "savedFrames", "changedFrames",
                                          "uniquePixelFrames", "missedScheduleSlots", "captureErrors"]}), flush=True)
    return 0 if reason in ["duration", "stopRequested"] else 1


def self_test():
    """Synthetic transport tests only; never enumerate or open capture devices."""
    import tempfile
    import unittest
    from unittest.mock import patch
    from types import SimpleNamespace

    class StreamTests(unittest.TestCase):
        def run_transport(self, invalid=False, stop=False):
            with tempfile.TemporaryDirectory(prefix="mobile-frame-test-") as temporary:
                out = Path(temporary)
                (out / "frames").mkdir()
                (out / "native-frames.jsonl").touch()
                state = dict(savedFrames=0, changedFrames=0, uniquePixelFrames=0,
                             missedScheduleSlots=0, captureErrors=0)
                args = SimpleNamespace(stream_device_id="synthetic-only", test_case="synthetic",
                                       revision="abcdef12", duration=3)
                native_started = [False]
                class Process:
                    polls = 0
                    def poll(inner):
                        inner.polls += 1
                        if inner.polls == 1:
                            return None
                        if inner.polls == 2:
                            rows = []
                            for slot, color in enumerate(["red", "red", "blue"]):
                                name = f"frames/synthetic-abcdef12-{slot:06d}.png"
                                Image.new("RGB", (3, 2), color).save(out / name)
                                rows.append(dict(kind="frame", file=name, requestedSecond=slot,
                                                 missedSlotsBefore=0, valid=True))
                            rows.append(dict(kind="stopped", summary=dict(stopReason="stopRequested" if stop else "duration")))
                            with (out / "native-frames.jsonl").open("a") as index:
                                if invalid:
                                    index.write("{broken\n")
                                else:
                                    index.write("".join(json.dumps(row) + "\n" for row in rows))
                        return 0
                    def wait(inner, timeout=None):
                        return 0
                def compile_mock(command, **kwargs):
                    if "--version" in command:
                        return SimpleNamespace(stdout=b"synthetic-test-compiler-no-device")
                    Path(command[-1]).write_bytes(b"synthetic-test-binary-never-executed")
                    return SimpleNamespace(returncode=0)
                def open_capture(*args, **kwargs):
                    native_started[0] = True
                    return Process()
                with patch.dict(globals(), {"run_preparation": compile_mock}), patch.object(subprocess, "Popen", side_effect=open_capture), patch.object(time, "sleep"):
                    if invalid:
                        with self.assertRaises(ValueError):
                            capture_stream(args, out, state, lambda: stop and native_started[0])
                        final = json.loads((out / "status.json").read_text())
                        self.assertEqual(final["stopReason"], "nativeCaptureFailure")
                        self.assertEqual(final["captureErrors"], 1)
                    else:
                        self.assertEqual(capture_stream(args, out, state, lambda: stop and native_started[0]), 0)
                        self.assertEqual(state["savedFrames"], 3)
                        self.assertEqual(state["changedFrames"], 2)
                        self.assertEqual(state["uniquePixelFrames"], 2)
                        self.assertEqual(len(list((out / "frames").glob("*.png"))), 3)
                        self.assertEqual(len((out / "frames.jsonl").read_text().splitlines()), 3)
                        self.assertTrue((out / "READY.json").exists())
                        self.assertIn("nativeSummary", state)
                        self.assertTrue(state["nativeProcessJoined"])
                        self.assertEqual(state["stopReason"], "stopRequested" if stop else "duration")
        def test_exit_drains_final_native_records_and_keeps_unchanged_frames(self):
            self.run_transport()
        def test_parse_failure_cannot_record_clean_stop(self):
            self.run_transport(invalid=True)
        def test_requested_stop_drains_clean_summary_before_join(self):
            self.run_transport(stop=True)
        def check_stuck_stop(self, stop_file):
            with tempfile.TemporaryDirectory(prefix="mobile-frame-stop-test-") as temporary:
                out = Path(temporary)
                (out / "frames").mkdir()
                state = dict(savedFrames=0, changedFrames=0, uniquePixelFrames=0,
                             missedScheduleSlots=0, captureErrors=0)
                args = SimpleNamespace(stream_device_id="synthetic-only", test_case="synthetic",
                                       revision="abcdef12", duration=7200)
                clock = [0.0]
                native_started = [False]
                class StuckProcess:
                    terminated = False
                    killed = False
                    waits = []
                    def poll(inner):
                        return -9 if inner.killed else None
                    def terminate(inner):
                        inner.terminated = True
                    def kill(inner):
                        inner.killed = True
                    def wait(inner, timeout=None):
                        inner.waits.append(timeout)
                        if inner.killed:
                            return -9
                        raise subprocess.TimeoutExpired("synthetic", timeout)
                process = StuckProcess()
                def compile_mock(command, **kwargs):
                    if "--version" in command:
                        return SimpleNamespace(stdout=b"synthetic-stop-test-compiler-no-device")
                    Path(command[-1]).write_bytes(b"synthetic-stop-test-binary-never-executed")
                    return SimpleNamespace(returncode=0)
                def advance(seconds):
                    clock[0] += seconds
                def open_capture(*args, **kwargs):
                    native_started[0] = True
                    if stop_file:
                        (out / "STOP").touch()
                    return process
                with patch.dict(globals(), {"run_preparation": compile_mock}), patch.object(subprocess, "Popen", side_effect=open_capture), \
                        patch.object(time, "sleep", advance), patch.object(time, "monotonic", lambda: clock[0]):
                    with self.assertRaisesRegex(TimeoutError, "after stop request"):
                        capture_stream(args, out, state, lambda: not stop_file and native_started[0])
                self.assertLess(clock[0], NATIVE_STOP_GRACE_SECONDS + 0.1)
                self.assertTrue(process.terminated)
                self.assertTrue(process.killed)
                self.assertEqual(process.waits, [NATIVE_TERMINATE_GRACE_SECONDS, NATIVE_KILL_GRACE_SECONDS])
                final = json.loads((out / "status.json").read_text())
                self.assertEqual(final["stopReason"], "nativeCaptureFailure")
                self.assertEqual(final["captureErrors"], 1)
                self.assertTrue(final["nativeProcessJoined"])
                self.assertEqual(final["nativeExitCode"], -9)
        def test_signal_stop_has_own_deadline_and_kills_stuck_native_child(self):
            self.check_stuck_stop(stop_file=False)
        def test_stop_file_has_own_deadline_and_kills_stuck_native_child(self):
            self.check_stuck_stop(stop_file=True)
        def check_preparation_cancel(self, timeout):
            import io
            with tempfile.TemporaryDirectory(prefix="mobile-frame-prepare-test-") as temporary:
                out = Path(temporary)
                clock = [0.0]
                class PreparingProcess:
                    pid = 123456789
                    stdout = io.BytesIO()
                    stderr = io.BytesIO()
                    returncode = None
                    terminated = False
                    def communicate(inner, timeout=None):
                        clock[0] += timeout
                        raise subprocess.TimeoutExpired("synthetic", timeout)
                    def poll(inner):
                        return inner.returncode
                    def terminate(inner):
                        inner.terminated = True
                        inner.returncode = -15
                    def wait(inner, timeout=None):
                        return inner.returncode
                process = PreparingProcess()
                sent = []
                def signal_group(pid, number):
                    self.assertEqual(pid, process.pid)
                    sent.append(number)
                    process.terminate()
                with patch.object(subprocess, "Popen", return_value=process) as popen, patch.object(time, "monotonic", lambda: clock[0]), patch.object(os, "killpg", signal_group):
                    expected = subprocess.TimeoutExpired if timeout else InterruptedError
                    with self.assertRaises(expected):
                        run_preparation(["synthetic-never-executed"], timeout=0.2 if timeout else 90,
                                        should_stop=lambda: not timeout and clock[0] >= 0.25, out=out,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                self.assertTrue(popen.call_args.kwargs["start_new_session"])
                self.assertEqual(sent, [signal.SIGTERM, signal.SIGKILL])
                self.assertLess(clock[0], 0.4)
                self.assertTrue(process.terminated)
                self.assertEqual(process.returncode, -15)
                self.assertTrue(process.stdout.closed)
                self.assertTrue(process.stderr.closed)
        def test_preparation_cancellation_joins_owned_compiler(self):
            self.check_preparation_cancel(timeout=False)
        def test_preparation_timeout_joins_owned_compiler(self):
            self.check_preparation_cancel(timeout=True)
        def test_preparation_cleanup_signals_group_after_driver_exit(self):
            process = SimpleNamespace(pid=123456789, wait=lambda timeout: 0)
            with patch.object(os, "killpg") as send:
                self.assertEqual(stop_preparation_group(process), 0)
            self.assertEqual([call.args for call in send.call_args_list],
                             [(process.pid, signal.SIGTERM), (process.pid, signal.SIGKILL)])

    result = unittest.TextTestRunner().run(unittest.defaultTestLoader.loadTestsFromTestCase(StreamTests))
    if not result.wasSuccessful():
        raise SystemExit(1)


def main():
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        return
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True)
    parser.add_argument("--stream-device-id", help="Explicit AVFoundation muxed device ID. Enables USB video-only streaming on physical devices; no camera fallback.")
    parser.add_argument("--platform", choices=["device", "simulator"], default="device")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--test-case", required=True)
    parser.add_argument("--duration", type=float, default=7200)
    args = parser.parse_args()
    if args.stream_device_id and args.platform != "device":
        parser.error("stream-device-id is only supported for physical devices")
    if not 0 < args.duration <= 43_200:
        parser.error("duration must be positive and at most twelve hours")
    if not all(c.isalnum() or c in "-_." for c in args.test_case) or not args.test_case:
        parser.error("test-case must be a safe filename component")
    if not 7 <= len(args.revision) <= 64 or any(c not in "0123456789abcdef" for c in args.revision):
        parser.error("revision must identify the tested source")
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    frames = out / "frames"
    frames.mkdir()
    stopped = False

    def stop(_signal, _frame):
        nonlocal stopped
        stopped = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    start = time.monotonic()
    state = dict(startedAtUTC=utc(), platform=args.platform, testedRevision=args.revision,
                 testCase=args.test_case, intervalSeconds=1, status="running", savedFrames=0,
                 changedFrames=0, uniquePixelFrames=0, missedScheduleSlots=0, captureErrors=0,
                 differenceMethod="SHA256 of decoded RGBA pixels and dimensions; PNG metadata ignored",
                 scope="Native device display capture. All valid frames retained; changed and unique indexes select review candidates. Capture can affect runtime measurements; this is not touch-latency or FPS evidence.")
    if args.stream_device_id:
        try:
            code = capture_stream(args, out, state, lambda: stopped)
        except Exception as error:
            state.update(status="stopped", stopReason="nativeCaptureFailure", endedAtUTC=utc(),
                         errorType=type(error).__name__)
            state["captureErrors"] = max(1, state["captureErrors"])
            (out / "status.json").write_text(json.dumps(state, indent=2))
            raise
        raise SystemExit(code)
    previous = None
    seen = {}
    slot = 0
    consecutive_errors = 0
    reason = "duration"
    with (out / "frames.jsonl").open("a") as index, (out / "changed.jsonl").open("a") as changed, \
            (out / "unique.jsonl").open("a") as unique, (out / "capture.log").open("ab") as log:
        print(json.dumps(dict(captureStarted=True, output=str(out), intervalSeconds=1)), flush=True)
        try:
            while time.monotonic() - start < args.duration:
                if stopped or (out / "STOP").exists():
                    reason = "stopRequested"
                    break
                if shutil.disk_usage(out).free < 2 * 1024**3:
                    reason = "insufficientDiskSpace"
                    break
                delay = start + slot - time.monotonic()
                if delay > 0:
                    time.sleep(min(delay, 1))
                    continue
                actual_slot = int(time.monotonic() - start)
                missed = max(0, actual_slot - slot)
                state["missedScheduleSlots"] += missed
                slot = max(slot, actual_slot)
                target = frames / f"{args.test_case}-{args.revision[:8]}-{slot:06d}.png"
                began = time.monotonic()
                row = dict(requestedSecond=slot, startedAtUTC=utc(), missedSlotsBefore=missed)
                try:
                    command = (["xcrun", "devicectl", "device", "capture", "screenshot", "--device", args.device,
                                "--destination", str(target), "--timeout", "5"] if args.platform == "device" else
                               ["xcrun", "simctl", "io", args.device, "screenshot", str(target)])
                    subprocess.run(command, check=True, stdout=log, stderr=log, timeout=6)
                    digest, dimensions = pixel_digest(target)
                    row.update(file=str(target.relative_to(out)), capturedAtUTC=utc(),
                               captureSeconds=time.monotonic() - began, dimensions=dimensions,
                               pixelSHA256=digest, pngSHA256=hashlib.sha256(target.read_bytes()).hexdigest(),
                               changedFromPrevious=digest != previous, firstPixelOccurrence=digest not in seen,
                               matchesEarlierSecond=seen.get(digest), valid=True)
                    state["savedFrames"] += 1
                    if row["changedFromPrevious"]:
                        state["changedFrames"] += 1
                        changed.write(json.dumps(row) + "\n"); changed.flush()
                    if row["firstPixelOccurrence"]:
                        state["uniquePixelFrames"] += 1
                        seen[digest] = slot
                        unique.write(json.dumps(row) + "\n"); unique.flush()
                    previous = digest
                    consecutive_errors = 0
                except (subprocess.SubprocessError, OSError, ValueError) as error:
                    state["captureErrors"] += 1
                    consecutive_errors += 1
                    row.update(valid=False, error=type(error).__name__, captureSeconds=time.monotonic() - began)
                index.write(json.dumps(row) + "\n"); index.flush()
                state.update(elapsedSeconds=time.monotonic() - start, lastAttempt=row)
                temporary = out / "status.pending.json"
                temporary.write_text(json.dumps(state, indent=2))
                temporary.replace(out / "status.json")
                slot += 1
                if consecutive_errors >= 3:
                    reason = "repeatedCaptureFailure"
                    break
        finally:
            state.update(status="stopped", stopReason=reason, endedAtUTC=utc(), elapsedSeconds=time.monotonic() - start)
            (out / "status.json").write_text(json.dumps(state, indent=2))
    print(json.dumps({k: state[k] for k in ["status", "stopReason", "savedFrames", "changedFrames",
                                          "uniquePixelFrames", "missedScheduleSlots", "captureErrors"]}), flush=True)
    if reason in ["repeatedCaptureFailure", "insufficientDiskSpace"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
