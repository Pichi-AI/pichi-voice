#!/usr/bin/env python3
"""Local synthetic stimulus and end barriers for the opt-in continuity probe.

Never controls applications, capture, permissions, or models. Native acknowledgements
remain the only clock used to map phase windows to PCM.
"""
import argparse
import hmac
import http.client
import json
import math
import os
from pathlib import Path
import re
import secrets
import stat
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlsplit
import uuid


LIMIT = 8192
PHASES = {"browserBefore": (1, 2), "secondSource": (4, 5), "browserAfter": (7, 8)}
NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]*\.wav\Z")


class ProtocolError(ValueError):
    pass


def regular_file(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
        raise ProtocolError("Expected an owned regular file, without symlinks.")
    return info


def read_json(path):
    regular_file(path)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ProtocolError("Protocol file is not regular.")
        data = stream.read(LIMIT + 1)
    if len(data) > LIMIT:
        raise ProtocolError("Protocol file exceeded its size limit.")
    value = json.loads(data)
    if not isinstance(value, dict):
        raise ProtocolError("Expected a JSON object.")
    return value


def atomic_json(path, value):
    descriptor, temporary = tempfile.mkstemp(prefix=".fixture-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as stream:
            json.dump(value, stream, allow_nan=False)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def wait_ack(root, run_id, sequence, timeout=3):
    """Read-only operator gate. A missing/rejected ack must stop the shell sequence."""
    root = Path(root)
    if (not root.is_absolute() or root.resolve(strict=True) != root or not root.is_dir()
            or root.stat().st_uid != os.getuid() or stat.S_IMODE(root.stat().st_mode) != 0o700):
        raise ProtocolError("Expected a canonical private owned protocol root.")
    run_id = str(uuid.UUID(run_id)).upper()
    if not 1 <= sequence <= 8 or not 0 < timeout <= 3:
        raise ProtocolError("Invalid bounded acknowledgement wait.")
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if (root / "outcome.json").exists() and sequence != 8:
            raise ProtocolError("Native probe stopped; stop progression.")
        try:
            ready = read_json(root / "capture-ready.json")
            ack = read_json(root / "phase-ack.json")
        except FileNotFoundError:
            time.sleep(0.025)
            continue
        if (str(ready.get("runID", "")).upper() != run_id or str(ack.get("runID", "")).upper() != run_id
                or ready.get("durationSeconds") != 100):
            raise ProtocolError("Wrong run or probe duration; stop progression.")
        host, ready_host = ack.get("machAbsoluteHostSeconds"), ready.get("readyHostSeconds")
        if (not isinstance(host, (int, float)) or not isinstance(ready_host, (int, float))
                or not math.isfinite(host) or not math.isfinite(ready_host)
                or not ready_host <= host < ready_host + 100):
            raise ProtocolError("Invalid native acknowledgement clock.")
        if ack.get("sequence") == sequence:
            return ack
        if not isinstance(ack.get("sequence"), int) or ack["sequence"] > sequence:
            raise ProtocolError("Unexpected native acknowledgement sequence.")
        time.sleep(0.025)
    raise ProtocolError("Native acknowledgement timed out; stop progression.")


class Fixture:
    def __init__(self, root, run_id, token, stimulus_dir, wav_names, ack_timeout=3):
        self.root = Path(root)
        self.stimulus_dir = Path(stimulus_dir)
        for directory in (self.root, self.stimulus_dir):
            if not directory.is_absolute() or directory.resolve(strict=True) != directory:
                raise ProtocolError("Directories must be absolute canonical paths.")
            if not directory.is_dir() or directory.stat().st_uid != os.getuid():
                raise ProtocolError("Expected an owned directory.")
        if stat.S_IMODE(self.root.stat().st_mode) != 0o700:
            raise ProtocolError("Protocol root must have mode 0700.")
        if any((self.root / name).exists() or (self.root / name).is_symlink() for name in
               ("capture-ready.json", "phase-command.json", "phase-ack.json", "outcome.json", "fixture-events.jsonl",
                "browser-prepared.json")):
            raise ProtocolError("Use a fresh protocol root, before native capture starts.")
        self.run_id = str(uuid.UUID(run_id)).upper()
        if not re.fullmatch(r"[A-Za-z0-9_-]{32,128}", token):
            raise ProtocolError("Use a fresh random token of at least 32 characters.")
        self.token = token
        if not wav_names or any(not NAME.fullmatch(name) for name in wav_names):
            raise ProtocolError("Supply explicit simple WAV basenames.")
        self.wavs = set(wav_names)
        for name in self.wavs:
            regular_file(self.stimulus_dir / name)
        self.started_wall = time.time()
        self.ready = None
        self.ready_seen = None
        self.active = None
        self.completed = set()
        self.failed = False
        self.ack_timeout = ack_timeout
        self.lock = threading.Lock()
        self.prepared_phase = None

    def prepared(self, payload):
        """Transport-only receipt. It cannot launch, stop or play any process."""
        with self.lock:
            token, phase = payload.get("token"), payload.get("phase")
            if self.root.resolve(strict=True) != self.root:
                raise ProtocolError("Protocol root changed to a symlink.")
            if (not self.same_run(payload.get("runID")) or not isinstance(token, str)
                    or not re.fullmatch(r"[A-Za-z0-9_-]{32,128}", token)
                    or not hmac.compare_digest(token, self.token)
                    or phase not in ("browserBefore", "browserAfter") or payload.get("event") != "prepared"
                    or self.failed or (self.root / "outcome.json").exists()):
                raise ProtocolError("Unexpected transport preparation receipt.")
            if phase == "browserBefore":
                if self.completed or (self.root / "capture-ready.json").exists():
                    raise ProtocolError("Prepare the first browser before native capture.")
            else:
                self.authorize(payload)
                if self.completed != {"browserBefore", "secondSource"}:
                    raise ProtocolError("Restart preparation skipped a phase.")
                # The owned launch and page load may race the native 25ms acknowledgement.
                wait_ack(self.root, self.run_id, 6)
                command = read_json(self.root / "phase-command.json")
                ack = read_json(self.root / "phase-ack.json")
                if (not self.same_run(command.get("runID")) or command.get("sequence") != 6
                        or command.get("action") != "browserRestarted" or not self.same_run(ack.get("runID"))
                        or ack.get("sequence") != 6):
                    raise ProtocolError("Wait for native restart acknowledgement before preparation.")
            if self.prepared_phase == phase:
                raise ProtocolError("Repeated transport preparation receipt.")
            self.prepared_phase = phase
            atomic_json(self.root / "browser-prepared.json", dict(runID=self.run_id, phase=phase, speechStarted=False))
            return {"status": "transport-prepared"}

    def authorize(self, payload, final_ack=False):
        token = payload.get("token")
        if (not self.same_run(payload.get("runID")) or not isinstance(token, str)
                or not re.fullmatch(r"[A-Za-z0-9_-]{32,128}", token)
                or not hmac.compare_digest(token, self.token)):
            raise ProtocolError("Wrong run or token.")
        if self.root.resolve(strict=True) != self.root:
            raise ProtocolError("Protocol directory changed to a symlink.")
        if self.failed or (not final_ack and (self.root / "outcome.json").exists()):
            raise ProtocolError("This run has stopped or failed.")
        ready_path = self.root / "capture-ready.json"
        if regular_file(ready_path).st_mtime < self.started_wall:
            raise ProtocolError("Stale capture-ready file.")
        ready = read_json(ready_path)
        if not self.same_run(ready.get("runID")):
            raise ProtocolError("Capture-ready belongs to another run.")
        for key in ("readyHostSeconds", "captureStartHostSeconds", "durationSeconds"):
            if not isinstance(ready.get(key), (int, float)) or not math.isfinite(ready[key]):
                raise ProtocolError("Invalid native ready clock or duration.")
        if ready["durationSeconds"] != 100 or ready["captureStartHostSeconds"] > ready["readyHostSeconds"]:
            raise ProtocolError("This driver requires the bounded 100-second probe.")
        if self.ready is None:
            self.ready, self.ready_seen = ready, time.monotonic()
        if self.ready != ready or time.monotonic() - self.ready_seen >= 100:
            raise ProtocolError("Ready evidence changed or expired.")
        return ready

    def same_run(self, value):
        return isinstance(value, str) and value.upper() == self.run_id

    def begin_evidence(self, phase):
        begin, _ = PHASES[phase]
        command = read_json(self.root / "phase-command.json")
        ack = read_json(self.root / "phase-ack.json")
        if (not self.same_run(command.get("runID")) or command.get("sequence") != begin
                or command.get("action") != "begin" or command.get("phase") != phase
                or not self.same_run(ack.get("runID")) or ack.get("sequence") != begin):
            raise ProtocolError("Expected this phase's native begin command and acknowledgement.")
        host = ack.get("machAbsoluteHostSeconds")
        if (not isinstance(host, (int, float)) or not math.isfinite(host)
                or not self.ready["readyHostSeconds"] <= host < self.ready["readyHostSeconds"] + 100):
            raise ProtocolError("Invalid or stale native begin acknowledgement.")
        return host

    def journal(self, phase, event, **fields):
        path = self.root / "fixture-events.jsonl"
        # Private root and O_NOFOLLOW prevent writing through a replaced journal symlink.
        descriptor = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "a") as stream:
            stream.write(json.dumps(dict(runID=self.run_id, phase=phase, event=event, **fields)) + "\n")

    def event(self, payload):
        with self.lock:
            self.authorize(payload)
            phase, event = payload.get("phase"), payload.get("event")
            if not isinstance(phase, str) or phase not in PHASES or event not in ("starting", "ended"):
                raise ProtocolError("Unexpected phase event.")
            host = self.begin_evidence(phase)
            required = {"browserBefore": set(), "secondSource": {"browserBefore"},
                        "browserAfter": {"browserBefore", "secondSource"}}[phase]
            if phase in self.completed or self.completed != required:
                raise ProtocolError("Replayed or skipped phase.")
            if event == "starting":
                if self.active is not None:
                    raise ProtocolError("Playback is already active.")
                self.active = (phase, host, time.monotonic())
                self.journal(phase, "starting", beginMachAbsoluteHostSeconds=host)
                return {"status": "playback-authorized"}
            if self.active is None or self.active[:2] != (phase, host):
                raise ProtocolError("No matching authorized playback.")
            elapsed = time.monotonic() - self.active[2]
            if not 0 < elapsed < 59.5:
                raise ProtocolError("Playback cannot fit the existing 60-second phase limit.")
            # The WebRTC sender buffer has ended; retain a small tail for received PCM.
            time.sleep(0.5)
            try:
                self.authorize(payload)
                self.begin_evidence(phase)
                end = PHASES[phase][1]
                atomic_json(self.root / "phase-command.json", dict(
                    runID=self.run_id, sequence=end, action="end", phase=phase))
                self.journal(phase, "end-command", playbackElapsedSeconds=elapsed, drainSeconds=0.5)
                deadline = time.monotonic() + self.ack_timeout
                while time.monotonic() < deadline:
                    ack = read_json(self.root / "phase-ack.json")
                    self.authorize(payload, final_ack=end == 8 and ack.get("sequence") == 8)
                    if not self.same_run(ack.get("runID")):
                        raise ProtocolError("Native acknowledgement changed run.")
                    if ack.get("sequence") == end:
                        end_host = ack.get("machAbsoluteHostSeconds")
                        if (not isinstance(end_host, (int, float)) or not math.isfinite(end_host)
                                or not host < end_host <= host + 60
                                or end_host >= self.ready["readyHostSeconds"] + 100):
                            raise ProtocolError("Invalid native end clock or phase deadline.")
                        self.journal(phase, "end-ack", endMachAbsoluteHostSeconds=end_host)
                        self.completed.add(phase)
                        self.active = None
                        return {"status": "native-end-acknowledged", "sequence": end,
                                "machAbsoluteHostSeconds": end_host}
                    if ack.get("sequence") != PHASES[phase][0]:
                        raise ProtocolError("Native acknowledgement skipped a sequence.")
                    time.sleep(0.025)
                raise ProtocolError("Native end acknowledgement timed out; stop progression.")
            except Exception:
                self.failed = True
                raise


def handler_for(fixture):
    class Handler(BaseHTTPRequestHandler):
        def setup(self):
            super().setup()
            self.connection.settimeout(3)

        def log_message(self, *args):
            pass  # Do not log the ephemeral token or browser query.

        def reply(self, code, value):
            data = json.dumps(value).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            path = urlsplit(self.path).path
            if path == "/meeting_browser_speech_stimulus.html":
                source = Path(__file__).with_name("meeting_browser_speech_stimulus.html")
                media_type = "text/html; charset=utf-8"
            elif path.startswith("/") and path[1:] in fixture.wavs:
                source = fixture.stimulus_dir / path[1:]
                media_type = "audio/wav"
            else:
                self.reply(404, {"error": "Only the fixture and named WAVs are served."})
                return
            try:
                if source.parent.resolve(strict=True) != source.parent:
                    raise ProtocolError("Fixture directory changed to a symlink.")
                regular_file(source)
                descriptor = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
                with os.fdopen(descriptor, "rb") as stream:
                    self.send_response(200)
                    self.send_header("Content-Type", media_type)
                    self.send_header("Content-Length", str(os.fstat(stream.fileno()).st_size))
                    self.send_header("Cache-Control", "no-store")
                    self.end_headers()
                    while data := stream.read(65536):
                        self.wfile.write(data)
            except (OSError, ProtocolError):
                self.reply(404, {"error": "Fixture file unavailable."})

        def do_POST(self):
            if self.path not in ("/phase-event", "/browser-prepared"):
                self.reply(404, {"error": "Unknown endpoint."})
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if self.headers.get("Transfer-Encoding") or not 0 < length <= 2048:
                    raise ProtocolError("Expected a bounded event body.")
                if self.headers.get("Content-Type") != "application/json":
                    raise ProtocolError("Expected application/json.")
                origin = self.headers.get("Origin")
                if origin and origin != f"http://127.0.0.1:{self.server.server_port}":
                    raise ProtocolError("Expected the local fixture origin.")
                self.connection.settimeout(3)
                data = self.rfile.read(length)
                if len(data) != length:
                    raise ProtocolError("Incomplete event body.")
                payload = json.loads(data)
                if not isinstance(payload, dict):
                    raise ProtocolError("Expected an event object.")
                action = fixture.prepared if self.path == "/browser-prepared" else fixture.event
                self.reply(200, action(payload))
            except (OSError, ValueError, ProtocolError) as error:
                self.reply(409, {"error": str(error)})
    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="operation", required=True)
    serve = subparsers.add_parser("serve")
    serve.add_argument("--root", required=True, type=Path)
    serve.add_argument("--stimulus-dir", required=True, type=Path)
    serve.add_argument("--wav", required=True, action="append")
    serve.add_argument("--run-id", required=True)
    serve.add_argument("--token", required=True)
    serve.add_argument("--port", required=True, type=int)
    event = subparsers.add_parser("event")
    event.add_argument("--port", required=True, type=int)
    event.add_argument("--run-id", required=True)
    event.add_argument("--token", required=True)
    event.add_argument("--phase", required=True, choices=PHASES)
    event.add_argument("--event", required=True, choices=("starting", "ended"))
    wait = subparsers.add_parser("wait-ack")
    wait.add_argument("--root", required=True, type=Path)
    wait.add_argument("--run-id", required=True)
    wait.add_argument("--sequence", required=True, type=int)
    subparsers.add_parser("token")
    args = parser.parse_args()
    if args.operation == "token":
        print(secrets.token_urlsafe(32))
    elif args.operation == "wait-ack":
        print(json.dumps(wait_ack(args.root, args.run_id, args.sequence)))
    elif args.operation == "serve":
        fixture = Fixture(args.root, args.run_id, args.token, args.stimulus_dir, args.wav)
        server = HTTPServer(("127.0.0.1", args.port), handler_for(fixture))
        server.timeout = 3
        print(f"Fixture listening on 127.0.0.1:{server.server_port}", flush=True)
        try:
            server.serve_forever()
        finally:
            server.server_close()
    else:
        connection = http.client.HTTPConnection("127.0.0.1", args.port, timeout=5)
        try:
            body = json.dumps(dict(runID=args.run_id, token=args.token, phase=args.phase, event=args.event))
            connection.request("POST", "/phase-event", body, {"Content-Type": "application/json"})
            response = connection.getresponse()
            data = response.read(4096)
            if response.status != 200:
                raise ProtocolError(data.decode())
            print(data.decode())
        finally:
            connection.close()


if __name__ == "__main__":
    main()
