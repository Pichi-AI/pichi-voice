#!/usr/bin/env python3
"""Explicit, bounded HTTP regression against an already running frozen macOS app.

No app startup, preferences, permissions, private-data routes, or fixture discovery.
The caller attests that --synthetic-audio contains only synthetic speech.
"""

import argparse
import ctypes
from dataclasses import dataclass
import json
import math
import os
from pathlib import Path
import plistlib
import socket
import stat
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit
import wave


ROOT = Path(__file__).resolve().parents[2]
MAX_HEADER_BYTES = 8192
MAX_BODY_BYTES = 65536
MAX_AUDIO_BYTES = 16 * 1024 * 1024
ERROR_CASES = (
    ("missing_route", "GET", "/__pichi_regression_missing_route__", b"", 404),
    ("method_not_allowed", "POST", "/v1/health", b"", 405),
    ("malformed_json", "POST", "/v1/transcribe", b"{", 400),
    ("missing_audio", "POST", "/v1/transcribe", b"{}", 400),
    ("invalid_base64", "POST", "/v1/transcribe", b'{"audioBase64":"!"}', 400),
)
CASE_NAMES = ("socket_health",) + tuple(row[0] for row in ERROR_CASES) + (
    "malformed_http", "invalid_content_length", "empty_audio_body", "synthetic_path_transcription",
)


class HarnessError(ValueError):
    """Only fixed diagnostic codes are eligible for the retained report."""


def require(condition, code):
    if not condition:
        raise HarnessError(code)


def endpoint(value):
    try:
        parts = urlsplit(value)
        port = parts.port
    except ValueError:
        raise HarnessError("invalid_endpoint") from None
    require(parts.scheme == "http" and parts.hostname in ("127.0.0.1", "::1")
            and port is not None and 1 <= port <= 65535 and not parts.username
            and not parts.password and parts.path in ("", "/") and not parts.query
            and not parts.fragment, "endpoint_must_be_literal_loopback")
    return parts.hostname, port


def regular_file(path):
    require(path.is_absolute() and not path.is_symlink(), "regular_absolute_file_required")
    metadata = path.stat()
    require(stat.S_ISREG(metadata.st_mode) and path.resolve() == path, "regular_absolute_file_required")
    return metadata


def audio_fixture(path):
    metadata = regular_file(path)
    require(44 < metadata.st_size <= MAX_AUDIO_BYTES, "fixture_size_out_of_bounds")
    with wave.open(str(path), "rb") as audio:
        require(audio.getcomptype() == "NONE" and audio.getnchannels() in (1, 2)
                and audio.getsampwidth() in (1, 2, 3, 4)
                and 8000 <= audio.getframerate() <= 48000, "fixture_must_be_short_pcm_wav")
        duration = audio.getnframes() / audio.getframerate()
        require(0 < duration <= 30, "fixture_duration_out_of_bounds")
        frames = audio.getnframes()
        # Check declared PCM length against the real data; do not retain samples.
        require(len(audio.readframes(frames)) == frames * audio.getnchannels() * audio.getsampwidth(),
                "fixture_pcm_is_truncated")
    samples = round(duration * 16000)
    require(samples > 0, "fixture_has_no_resampled_audio")
    return (metadata.st_dev, metadata.st_ino, metadata.st_size, metadata.st_mtime_ns), samples


def verify_fixture(path, fingerprint):
    metadata = regular_file(path)
    require((metadata.st_dev, metadata.st_ino, metadata.st_size, metadata.st_mtime_ns) == fingerprint,
            "synthetic_fixture_changed")


def process_path(pid):
    require(sys.platform == "darwin", "live_requires_macos")
    library = ctypes.CDLL("/usr/lib/libproc.dylib")
    library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    library.proc_pidpath.restype = ctypes.c_int
    buffer = ctypes.create_string_buffer(4096)
    require(library.proc_pidpath(pid, buffer, len(buffer)) > 0, "target_process_unavailable")
    return Path(os.fsdecode(buffer.value))


def listener_pids(port):
    result = subprocess.run(["/usr/sbin/lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-Fp"],
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                            text=True, timeout=3, check=False)
    require(result.returncode == 0 and len(result.stdout) <= 16384, "listener_identity_unavailable")
    rows = result.stdout.splitlines()
    require(rows and all(row.startswith("p") and row[1:].isdigit() for row in rows),
            "listener_identity_unavailable")
    return {int(row[1:]) for row in rows}


@dataclass(frozen=True)
class Target:
    pid: int
    executable: Path
    version: str
    port: int

    def verify(self):
        require(process_path(self.pid) == self.executable, "target_executable_mismatch")
        require(listener_pids(self.port) == {self.pid}, "target_does_not_exclusively_own_listener")


def target(args, port):
    require(type(args.app_pid) is int and args.app_pid > 1 and args.app_pid != os.getpid(), "invalid_target_pid")
    bundle = args.app_bundle
    require(bundle is not None and bundle.is_absolute() and bundle.suffix == ".app"
            and bundle.is_dir() and not bundle.is_symlink() and bundle.resolve() == bundle,
            "absolute_app_bundle_required")
    info = bundle / "Contents/Info.plist"
    regular_file(info)
    require(info.stat().st_size <= 1048576, "invalid_bundle_metadata")
    value = plistlib.loads(info.read_bytes())
    require(isinstance(value, dict) and value.get("CFBundleIdentifier") == args.bundle_id
            and isinstance(args.bundle_id, str) and bool(args.bundle_id), "bundle_identity_mismatch")
    name = value.get("CFBundleExecutable")
    version = value.get("CFBundleShortVersionString")
    require(isinstance(name, str) and name not in ("", ".", "..") and Path(name).name == name
            and isinstance(version, str) and bool(version.strip()), "invalid_bundle_metadata")
    executable = bundle / "Contents/MacOS" / name
    regular_file(executable)
    require(os.access(executable, os.X_OK), "target_executable_not_executable")
    result = Target(args.app_pid, executable, version, port)
    result.verify()
    return result


def request_bytes(method, path, body=b"", content_type="application/json", length=None):
    size = len(body) if length is None else length
    return (f"{method} {path} HTTP/1.1\r\nHost: localhost\r\nContent-Type: {content_type}\r\n"
            f"Content-Length: {size}\r\nConnection: close\r\n\r\n").encode("ascii") + body


def parse_response(raw):
    require(len(raw) <= MAX_HEADER_BYTES + MAX_BODY_BYTES, "response_too_large")
    headers, separator, body = raw.partition(b"\r\n\r\n")
    require(separator and len(headers) <= MAX_HEADER_BYTES and len(body) <= MAX_BODY_BYTES,
            "invalid_response_framing")
    try:
        lines = headers.decode("ascii").split("\r\n")
        version, status_code, _reason = lines[0].split(" ", 2)
        require(version == "HTTP/1.1" and status_code.isdigit(), "invalid_response_status")
        status_code = int(status_code)
        require(100 <= status_code <= 599, "invalid_response_status")
        fields = {}
        for line in lines[1:]:
            key, value = line.split(":", 1)
            key = key.lower().strip()
            require(key not in fields, "duplicate_response_header")
            fields[key] = value.strip()
        require(fields.get("content-type", "").lower().split(";", 1)[0] == "application/json"
                and fields.get("content-length") == str(len(body)) and "transfer-encoding" not in fields,
                "invalid_response_headers")
        value = json.loads(body, parse_constant=lambda _value: None)
        require(isinstance(value, dict), "response_must_be_json_object")
        return status_code, value
    except (UnicodeError, ValueError):
        raise HarnessError("invalid_response_encoding") from None


def exchange(host, port, payload, timeout):
    # Numeric addresses bypass DNS/proxies; redirects are never followed.
    family = socket.AF_INET6 if host == "::1" else socket.AF_INET
    deadline = time.monotonic() + timeout
    with socket.socket(family, socket.SOCK_STREAM) as connection:
        connection.settimeout(timeout)
        connection.connect((host, port))
        remaining = deadline - time.monotonic()
        require(remaining > 0, "request_deadline_exceeded")
        connection.settimeout(remaining)
        connection.sendall(payload)
        raw = bytearray()
        while True:
            remaining = deadline - time.monotonic()
            require(remaining > 0, "request_deadline_exceeded")
            connection.settimeout(remaining)
            chunk = connection.recv(min(4096, MAX_HEADER_BYTES + MAX_BODY_BYTES + 1 - len(raw)))
            if not chunk:
                break
            raw.extend(chunk)
            require(len(raw) <= MAX_HEADER_BYTES + MAX_BODY_BYTES, "response_too_large")
            separator = raw.find(b"\r\n\r\n")
            require(separator <= MAX_HEADER_BYTES if separator >= 0 else len(raw) <= MAX_HEADER_BYTES,
                    "response_header_too_large")
    return parse_response(bytes(raw))


def validate_health(status_code, value, version):
    require(status_code == 200 and set(value) == {"status", "version"}
            and value["status"] == "ok" and value["version"] == version, "health_contract_failed")


def validate_error(status_code, value, expected):
    require(status_code == expected and set(value) == {"error"} and isinstance(value["error"], str)
            and bool(value["error"].strip()), "error_contract_failed")


def validate_transcription(status_code, value, samples, expected_provider=None, expected_text=None):
    require(status_code == 200 and set(value) == {"text", "confidence", "sampleCount", "provider"},
            "transcription_contract_failed")
    require(isinstance(value["text"], str) and bool(value["text"].strip())
            and isinstance(value["provider"], str) and bool(value["provider"].strip())
            and type(value["sampleCount"]) is int and value["sampleCount"] > 0
            and abs(value["sampleCount"] - samples) <= 2
            and type(value["confidence"]) in (int, float) and math.isfinite(value["confidence"])
            and 0 <= value["confidence"] <= 1, "transcription_shape_failed")
    require(expected_provider is None or value["provider"] == expected_provider, "provider_expectation_failed")
    require(expected_text is None or expected_text.casefold() in value["text"].casefold(), "text_expectation_failed")


def summarize(rows):
    require(isinstance(rows, list) and all(isinstance(row, dict) for row in rows), "invalid_live_results")
    require(len(rows) == len(CASE_NAMES) and {row.get("case") for row in rows} == set(CASE_NAMES)
            and all(row.get("status") in ("PASS", "FAIL", "SKIP") for row in rows), "incomplete_live_results")
    counts = {state.lower(): sum(row["status"] == state for row in rows) for state in ("PASS", "FAIL", "SKIP")}
    require(counts["pass"] == len(CASE_NAMES) and counts["fail"] == 0 and counts["skip"] == 0,
            "live_run_did_not_pass")
    return counts


def run_live(args):
    host, port = endpoint(args.endpoint)
    require(args.synthetic_audio is not None, "caller_supplied_synthetic_audio_required")
    require(1 <= args.timeout <= 180, "timeout_out_of_bounds")
    require(args.expect_text_contains is None or bool(args.expect_text_contains.strip()), "empty_text_expectation")
    require(args.expect_provider is None or bool(args.expect_provider.strip()), "empty_provider_expectation")
    fingerprint, samples = audio_fixture(args.synthetic_audio)
    app = target(args, port)
    rows = []
    cases = [("socket_health", request_bytes("GET", "/v1/health"), "health", 200)]
    cases += [(name, request_bytes(method, path, body), "error", status_code)
              for name, method, path, body, status_code in ERROR_CASES]
    cases += [
        ("malformed_http", b"INVALID\r\n\r\n", "error", 400),
        ("invalid_content_length", request_bytes("POST", "/v1/transcribe", length=-1), "error", 400),
        ("empty_audio_body", request_bytes("POST", "/v1/transcribe", content_type="audio/wav"), "error", 400),
        ("synthetic_path_transcription", request_bytes("POST", "/v1/transcribe",
             json.dumps({"path": str(args.synthetic_audio)}).encode()), "transcription", 200),
    ]
    for name, payload, kind, expected in cases:
        row = {"case": name, "status": "FAIL"}
        rows.append(row)
        try:
            app.verify()
            verify_fixture(args.synthetic_audio, fingerprint)
            status_code, value = exchange(host, port, payload, args.timeout if kind == "transcription" else min(args.timeout, 5))
            app.verify()
            verify_fixture(args.synthetic_audio, fingerprint)
            if kind == "health":
                validate_health(status_code, value, app.version)
            elif kind == "error":
                validate_error(status_code, value, expected)
            else:
                validate_transcription(status_code, value, samples, args.expect_provider, args.expect_text_contains)
            row.update(status="PASS", httpStatus=status_code)
        except HarnessError as error:
            row["reason"] = str(error)
            break
        except (OSError, subprocess.SubprocessError):
            row["reason"] = "request_or_identity_check_failed"
            break
    for name in CASE_NAMES[len(rows):]:
        rows.append({"case": name, "status": "SKIP", "reason": "prior_case_failed"})
    # No raw error, transcript, expected phrase, request body, fixture/bundle path or model response is logged.
    return rows


def retain_report(rows):
    build = ROOT / ".build"
    require(not build.is_symlink(), "unsafe_report_storage")
    build.mkdir(exist_ok=True)
    directory = Path(tempfile.mkdtemp(prefix="local-api-live-", dir=build))
    os.chmod(directory, 0o700)
    try:
        counts = summarize(rows)
        status = "PASS"
    except HarnessError:
        status = "FAIL"
        counts = {state.lower(): sum(row["status"] == state for row in rows) for state in ("PASS", "FAIL", "SKIP")}
    report = {"mode": "live_http", "status": status, "counts": counts, "results": rows,
              "limits": {"maxHeaderBytes": MAX_HEADER_BYTES, "maxResponseBodyBytes": MAX_BODY_BYTES,
                         "maxAudioBytes": MAX_AUDIO_BYTES, "maxAudioSeconds": 30}}
    (directory / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"LIVE_HTTP {status}: {counts['pass']} passed, {counts['fail']} failed, {counts['skip']} skipped.")
    print(f"Local report: {directory.relative_to(ROOT)}/summary.json")
    return 0 if status == "PASS" else 1


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-live", action="store_true", help="Explicitly permit requests to the verified already running app")
    parser.add_argument("--endpoint", default="http://127.0.0.1:47733")
    parser.add_argument("--app-pid", type=int)
    parser.add_argument("--app-bundle", type=Path)
    parser.add_argument("--bundle-id")
    parser.add_argument("--synthetic-audio", type=Path, help="Caller attests this short PCM WAV contains only synthetic speech")
    parser.add_argument("--timeout", type=float, default=120, help="Transcription deadline, 1-180 seconds; other requests at most 5")
    parser.add_argument("--expect-provider")
    parser.add_argument("--expect-text-contains", help="Optional synthetic phrase, compared in memory and never logged")
    args = parser.parse_args(argv)
    if not args.run_live:
        print("DRY_RUN: no network, app, preferences, permissions or audio accessed. Live HTTP was not tested.")
        return 0
    try:
        rows = run_live(args)
        return retain_report(rows)
    except (HarnessError, OSError, ValueError, TypeError, subprocess.SubprocessError, wave.Error, EOFError):
        print("LIVE_HTTP REFUSED: safety preflight failed; no live PASS.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
