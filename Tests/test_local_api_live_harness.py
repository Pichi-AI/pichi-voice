#!/usr/bin/env python3
"""Harness regression only: no listening sockets, app process, or real speech model."""

from contextlib import ExitStack, redirect_stderr, redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import socket
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
import wave

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("local_api_live", ROOT / "scripts/dev/local-api-live.py")
HARNESS = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = HARNESS
spec.loader.exec_module(HARNESS)
REAL_EXCHANGE = HARNESS.exchange


def response(status, value):
    body = json.dumps(value).encode()
    return (f"HTTP/1.1 {status} Fixture\r\nContent-Type: application/json; charset=utf-8\r\n"
            f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n").encode() + body


class FakeSocket:
    def __init__(self, chunks):
        self.chunks = chunks
        self.sent = []
        self.timeouts = []
        self.closed = False
    def __enter__(self):
        return self
    def __exit__(self, *args):
        self.closed = True
    def settimeout(self, value):
        self.timeouts.append(value)
    def connect(self, address):
        self.address = address
    def sendall(self, value):
        self.sent.append(value)
    def recv(self, limit):
        if not self.chunks:
            return b""
        result = self.chunks.pop(0)
        self.chunks.insert(0, result[limit:]) if len(result) > limit else None
        return result[:limit]


class LocalAPILiveHarnessTests(unittest.TestCase):
    def setUp(self):
        self.storage = tempfile.TemporaryDirectory()
        self.addCleanup(self.storage.cleanup)
        self.root = Path(self.storage.name).resolve()
        self.bundle = self.root / "Fixture.app"
        (self.bundle / "Contents/MacOS").mkdir(parents=True)
        self.executable = self.bundle / "Contents/MacOS/Fixture"
        self.executable.write_bytes(b"synthetic executable metadata fixture")
        self.executable.chmod(0o700)
        (self.bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "test.synthetic.api", "CFBundleExecutable": "Fixture",
            "CFBundleShortVersionString": "1.6.11",
        }))
        self.audio = self.root / "synthetic.wav"
        with wave.open(str(self.audio), "wb") as value:
            value.setnchannels(1)
            value.setsampwidth(2)
            value.setframerate(16000)
            value.writeframes(b"\0\0" * 16000)
        self.args = type("Arguments", (), dict(endpoint="http://127.0.0.1:47733", app_pid=12345,
            app_bundle=self.bundle, bundle_id="test.synthetic.api", synthetic_audio=self.audio,
            timeout=2.0, expect_provider="Synthetic provider", expect_text_contains="проверка"))()

    def guards(self):
        stack = ExitStack()
        stack.enter_context(patch.object(HARNESS, "process_path", return_value=self.executable))
        stack.enter_context(patch.object(HARNESS, "listener_pids", return_value={12345}))
        return stack

    def scripted_exchange(self, host, port, payload, timeout):
        self.assertEqual((host, port), ("127.0.0.1", 47733))
        first = payload.split(b"\r\n", 1)[0]
        if first == b"GET /v1/health HTTP/1.1":
            raw = response(200, {"status": "ok", "version": "1.6.11"})
        elif first.startswith(b"GET /__pichi_regression"):
            raw = response(404, {"error": "Route not found."})
        elif first == b"POST /v1/health HTTP/1.1":
            raw = response(405, {"error": "Method not allowed."})
        elif b'"path":' in payload:
            self.assertEqual(json.loads(payload.partition(b"\r\n\r\n")[2]), {"path": str(self.audio)})
            raw = response(200, {"text": "Синтетическая проверка Ё", "confidence": 0.9,
                                 "sampleCount": 16000, "provider": "Synthetic provider"})
        else:
            raw = response(400, {"error": "Synthetic error without any user data"})
        fake = FakeSocket([raw[:13], raw[13:]])
        with patch.object(socket, "socket", return_value=fake) as factory:
            result = REAL_EXCHANGE(host, port, payload, timeout)
        self.assertEqual(factory.call_args.args, (socket.AF_INET, socket.SOCK_STREAM))
        self.assertTrue(fake.closed)
        return result

    def test_default_has_no_network_audio_or_process_access_and_no_live_pass(self):
        output = io.StringIO()
        with patch.object(HARNESS, "run_live", side_effect=AssertionError("must not access live inputs")), redirect_stdout(output):
            self.assertEqual(HARNESS.main([]), 0)
        self.assertIn("DRY_RUN", output.getvalue())
        self.assertIn("Live HTTP was not tested", output.getvalue())
        self.assertNotIn("PASS", output.getvalue())

    def test_endpoint_refuses_dns_remote_credentials_and_extra_targets(self):
        for value in ["https://127.0.0.1:47733", "http://localhost:47733", "http://192.168.1.1:47733",
                      "http://127.0.0.2:47733", "http://user:secret@127.0.0.1:47733", "http://127.0.0.1",
                      "http://127.0.0.1:47733/v1/history", "http://127.0.0.1:47733?q=secret", "http://[::1]:0"]:
            with self.subTest(value=value), self.assertRaises(HARNESS.HarnessError):
                HARNESS.endpoint(value)
        self.assertEqual(HARNESS.endpoint("http://[::1]:47733"), ("::1", 47733))

    def test_invalid_preflight_never_sends_http(self):
        for key, value in [("synthetic_audio", None), ("timeout", 0), ("timeout", 181),
                           ("timeout", float("nan")), ("app_pid", None), ("app_pid", 1),
                           ("bundle_id", "wrong.identity"), ("expect_text_contains", " "), ("expect_provider", "")]:
            previous = getattr(self.args, key)
            setattr(self.args, key, value)
            with self.subTest(key=key), self.guards(), patch.object(HARNESS, "exchange") as send:
                with self.assertRaises(HARNESS.HarnessError):
                    HARNESS.run_live(self.args)
                send.assert_not_called()
            setattr(self.args, key, previous)

    def test_exact_pid_executable_and_exclusive_listener_required(self):
        for path, pids in [(self.root / "Other", {12345}), (self.executable, {999}),
                           (self.executable, {12345, 999}), (self.executable, set())]:
            with patch.object(HARNESS, "process_path", return_value=path), \
                 patch.object(HARNESS, "listener_pids", return_value=pids), \
                 patch.object(HARNESS, "exchange") as send, self.assertRaises(HARNESS.HarnessError):
                HARNESS.run_live(self.args)
            send.assert_not_called()

    def test_native_identity_adapters_use_only_pid_path_and_numeric_listener_fields(self):
        def pid_path(pid, buffer, size):
            self.assertEqual(pid, 12345)
            self.assertEqual(size, 4096)
            buffer.value = os.fsencode(self.executable)
            return len(buffer.value)
        library = Mock(proc_pidpath=Mock(side_effect=pid_path))
        with patch.object(HARNESS.sys, "platform", "darwin"), patch.object(HARNESS.ctypes, "CDLL", return_value=library):
            self.assertEqual(HARNESS.process_path(12345), self.executable)
        # Darwin -Fp also emits file-descriptor fields (for example p12345\nf5\n).
        # -t is the PID-only format, including duplicate rows for multiple sockets.
        result = type("Result", (), dict(returncode=0, stdout="12345\n12345\n"))()
        with patch.object(HARNESS.subprocess, "run", return_value=result) as command:
            self.assertEqual(HARNESS.listener_pids(47733), {12345})
        self.assertEqual(command.call_args.args[0], ["/usr/sbin/lsof", "-nP", "-iTCP:47733", "-sTCP:LISTEN", "-t"])
        self.assertEqual(command.call_args.kwargs["timeout"], 3)

    def test_listener_output_requires_bounded_ascii_positive_pid_rows(self):
        result = type("Result", (), dict(returncode=0, stdout=""))()
        for bad in ["", "\n", "12345\n\n", "p12345\nf5\n", "12345\ncPrivate command line\n",
                    "NotNumeric\n", "0\n", "-12345\n", "+12345\n", " 12345\n", "12345 \n",
                    "１２３４５\n", "١٢٣٤٥\n", "²\n", "1\n" * 8193]:
            result.stdout = bad
            with self.subTest(output=bad[:30]), patch.object(HARNESS.subprocess, "run", return_value=result), \
                 self.assertRaisesRegex(HARNESS.HarnessError, "^listener_identity_unavailable$"):
                HARNESS.listener_pids(47733)
        for status, output in [(1, ""), (1, "12345\n"), (2, "12345\n")]:
            result.returncode, result.stdout = status, output
            with self.subTest(status=status), patch.object(HARNESS.subprocess, "run", return_value=result), \
                 self.assertRaisesRegex(HARNESS.HarnessError, "^listener_identity_unavailable$"):
                HARNESS.listener_pids(47733)

    def test_listener_pid_only_output_retains_exclusive_ownership_checks(self):
        for output in ["999\n", "12345\n999\n"]:
            result = type("Result", (), dict(returncode=0, stdout=output))()
            with self.subTest(output=output), patch.object(HARNESS, "process_path", return_value=self.executable), \
                 patch.object(HARNESS.subprocess, "run", return_value=result), patch.object(HARNESS, "exchange") as send, \
                 self.assertRaisesRegex(HARNESS.HarnessError, "^target_does_not_exclusively_own_listener$"):
                HARNESS.run_live(self.args)
            send.assert_not_called()

    def test_pid_only_adapter_is_rechecked_before_and_after_every_request(self):
        good = type("Result", (), dict(returncode=0, stdout="12345\n"))()
        with patch.object(HARNESS, "process_path", return_value=self.executable), \
             patch.object(HARNESS.subprocess, "run", return_value=good) as command, \
             patch.object(HARNESS, "exchange", side_effect=self.scripted_exchange) as send:
            rows = HARNESS.run_live(self.args)
        self.assertEqual(HARNESS.summarize(rows), {"pass": 10, "fail": 0, "skip": 0})
        self.assertEqual(send.call_count, 10)
        self.assertEqual(command.call_count, 21, "One preflight plus ownership checks before and after all ten requests")
        for output in ["999\n", "12345\n999\n", ""]:
            changed = type("Result", (), dict(returncode=0, stdout=output))()
            with self.subTest(output=output), patch.object(HARNESS, "process_path", return_value=self.executable), \
                 patch.object(HARNESS.subprocess, "run", side_effect=[good, good, changed]), \
                 patch.object(HARNESS, "exchange", side_effect=self.scripted_exchange) as send:
                rows = HARNESS.run_live(self.args)
            self.assertEqual(send.call_count, 1)
            self.assertEqual([row["status"] for row in rows], ["FAIL"] + ["SKIP"] * 9)

    def test_listener_timeout_or_unavailable_utility_never_sends_http(self):
        for error in [subprocess.TimeoutExpired("lsof", 3), FileNotFoundError("lsof")]:
            with self.subTest(error=type(error).__name__), \
                 patch.object(HARNESS, "process_path", return_value=self.executable), \
                 patch.object(HARNESS.subprocess, "run", side_effect=error), \
                 patch.object(HARNESS, "exchange") as send, self.assertRaises(type(error)):
                HARNESS.run_live(self.args)
            send.assert_not_called()

    def test_bundle_and_fixture_symlinks_refused(self):
        alias = self.root / "alias.wav"
        alias.symlink_to(self.audio)
        with self.assertRaises(HARNESS.HarnessError):
            HARNESS.audio_fixture(alias)
        alias_bundle = self.root / "Alias.app"
        alias_bundle.symlink_to(self.bundle)
        self.args.app_bundle = alias_bundle
        with self.guards(), self.assertRaises(HARNESS.HarnessError):
            HARNESS.target(self.args, 47733)

    def test_wav_duration_and_declared_data_are_bounded(self):
        self.assertEqual(HARNESS.audio_fixture(self.audio)[1], 16000)
        for frames in [0, 31 * 16000]:
            with wave.open(str(self.audio), "wb") as value:
                value.setnchannels(1)
                value.setsampwidth(2)
                value.setframerate(16000)
                value.writeframes(b"\0\0" * frames)
            with self.assertRaises(HARNESS.HarnessError):
                HARNESS.audio_fixture(self.audio)
        self.audio.write_bytes(self.audio.read_bytes()[:-2])
        with self.assertRaises(HARNESS.HarnessError):
            HARNESS.audio_fixture(self.audio)

    def test_live_roundtrip_plan_and_nonempty_transcription_gate(self):
        with self.guards(), patch.object(HARNESS, "exchange", side_effect=self.scripted_exchange) as send:
            rows = HARNESS.run_live(self.args)
        self.assertEqual(send.call_count, 10)
        self.assertEqual(HARNESS.summarize(rows), {"pass": 10, "fail": 0, "skip": 0})
        self.assertEqual([row["case"] for row in rows], list(HARNESS.CASE_NAMES))
        self.assertNotIn("Синтетическая", json.dumps(rows, ensure_ascii=False))
        with self.assertRaises(HARNESS.HarnessError):
            HARNESS.validate_transcription(200, {"text": " ", "confidence": 1,
                "sampleCount": 16000, "provider": "Synthetic provider"}, 16000)

    def test_identity_rechecked_before_each_request_and_change_stops_remaining(self):
        with self.guards(), patch.object(HARNESS.Target, "verify", side_effect=[None, None, None, HARNESS.HarnessError("target_executable_mismatch")]), \
             patch.object(HARNESS, "exchange", side_effect=self.scripted_exchange) as send:
            rows = HARNESS.run_live(self.args)
        self.assertEqual(send.call_count, 1)
        self.assertEqual([row["status"] for row in rows], ["PASS", "FAIL"] + ["SKIP"] * 8)
        with self.assertRaises(HARNESS.HarnessError):
            HARNESS.summarize(rows)

    def test_changed_fixture_and_identity_during_response_cannot_pass(self):
        real_exchange = self.scripted_exchange
        def changed_fixture(*args):
            result = real_exchange(*args)
            with self.audio.open("ab") as fixture:
                fixture.write(b"changed")
            return result
        with self.guards(), patch.object(HARNESS, "exchange", side_effect=changed_fixture) as send:
            rows = HARNESS.run_live(self.args)
        self.assertEqual(send.call_count, 1)
        self.assertEqual(rows[0]["reason"], "synthetic_fixture_changed")
        with self.guards(), patch.object(HARNESS.Target, "verify", side_effect=[None, None, HARNESS.HarnessError("target_executable_mismatch")]), \
             patch.object(HARNESS, "exchange", side_effect=self.scripted_exchange):
            rows = HARNESS.run_live(self.args)
        self.assertEqual(rows[0]["status"], "FAIL")
        self.assertEqual(rows[0]["reason"], "target_executable_mismatch")

    def test_response_requires_strict_framing_and_bounded_body(self):
        for raw in [b"", b"HTTP/1.1 200 OK\r\n\r\n{}", response(200, []) ,
                    response(200, {}) + b"unexpected", response(200, {}).replace(b"application/json", b"text/plain"),
                    response(200, {}).replace(b"Content-Length: 2", b"Content-Length: 2\r\nContent-Length: 2"),
                    b"H" * (HARNESS.MAX_HEADER_BYTES + 1), b"B" * (HARNESS.MAX_HEADER_BYTES + HARNESS.MAX_BODY_BYTES + 1)]:
            with self.subTest(size=len(raw)), self.assertRaises(HARNESS.HarnessError):
                HARNESS.parse_response(raw)

    def test_socket_response_limit_and_total_deadline(self):
        for chunks, clock in [([b"X" * (HARNESS.MAX_HEADER_BYTES + 1)], [0, 0, 0, 0, 0]),
                              ([b""], [0, 3])]:
            fake = FakeSocket(chunks)
            with patch.object(socket, "socket", return_value=fake), patch.object(HARNESS.time, "monotonic", side_effect=clock), \
                 self.assertRaises(HARNESS.HarnessError):
                HARNESS.exchange("127.0.0.1", 47733, b"synthetic", 2)
            self.assertTrue(fake.closed)
            if clock == [0, 3]:
                self.assertEqual(fake.sent, [], "An expired connection budget must stop before writing any request")

    def test_health_and_error_shape_refuse_success_html_empty_and_wrong_version(self):
        for status, value in [(200, {}), (200, {"status": "ok", "version": "wrong"}), (400, {"status": "ok", "version": "1.6.11"})]:
            with self.assertRaises(HARNESS.HarnessError):
                HARNESS.validate_health(status, value, "1.6.11")
        for status, value in [(200, {"error": "Oops"}), (400, {}), (400, {"error": ""}), (400, {"error": 1})]:
            with self.assertRaises(HARNESS.HarnessError):
                HARNESS.validate_error(status, value, 400)

    def test_transcription_shape_and_optional_expectations(self):
        valid = {"text": "Синтетическая проверка", "confidence": 0.5, "sampleCount": 16000, "provider": "Synthetic"}
        HARNESS.validate_transcription(200, valid, 16000, "Synthetic", "ПРОВЕРКА")
        for key, value in [("confidence", float("nan")), ("confidence", True), ("confidence", -1),
                           ("sampleCount", True), ("sampleCount", 0), ("provider", ""), ("text", None)]:
            with self.subTest(key=key), self.assertRaises(HARNESS.HarnessError):
                HARNESS.validate_transcription(200, dict(valid, **{key: value}), 16000)
        for provider, text in [("Wrong", None), (None, "absent")]:
            with self.assertRaises(HARNESS.HarnessError):
                HARNESS.validate_transcription(200, valid, 16000, provider, text)

    def test_empty_all_skipped_failed_and_duplicate_reports_never_pass(self):
        passing = [{"case": name, "status": "PASS"} for name in HARNESS.CASE_NAMES]
        for rows in [[], ["invalid"], [{"case": name, "status": "SKIP"} for name in HARNESS.CASE_NAMES],
                     passing[:-1], passing[:-1] + [passing[0]], passing[:-1] + [{"case": HARNESS.CASE_NAMES[-1], "status": "FAIL"}]]:
            with self.assertRaises(HARNESS.HarnessError):
                HARNESS.summarize(rows)

    def test_retained_report_and_failure_output_cannot_contain_bodies_or_paths(self):
        with self.guards(), patch.object(HARNESS, "exchange", side_effect=self.scripted_exchange):
            rows = HARNESS.run_live(self.args)
        output = io.StringIO()
        with patch.object(HARNESS, "ROOT", self.root), redirect_stdout(output):
            self.assertEqual(HARNESS.retain_report(rows), 0)
        reports = list((self.root / ".build").glob("local-api-live-*/summary.json"))
        content = reports[0].read_text()
        self.assertEqual(json.loads(content)["mode"], "live_http")
        for forbidden in ["проверка", "Synthetic provider", str(self.audio), str(self.bundle), "Synthetic error"]:
            self.assertNotIn(forbidden, content + output.getvalue())
        with patch.object(HARNESS, "run_live", side_effect=OSError("SECRET PRIVATE BODY")), redirect_stderr(output):
            self.assertEqual(HARNESS.main(["--run-live"]), 1)
        self.assertNotIn("SECRET", output.getvalue())

    def test_live_plan_tracks_current_source_contract_without_private_routes(self):
        router = (ROOT / "Sources/Fluid/Services/LocalAPI/LocalAPIRouter.swift").read_text()
        inference = (ROOT / "Sources/Fluid/Services/LocalAPI/InferenceAPIController.swift").read_text()
        for method, path in [("GET", "/v1/health"), ("POST", "/v1/transcribe")]:
            self.assertIn(f'self.register(method: "{method}", path: "{path}"', router)
        self.assertIn("struct TranscribeResponse: Encodable", inference)
        for property in ["let text: String", "let confidence: Float", "let sampleCount: Int", "let provider: String"]:
            self.assertIn(property, inference)
        self.assertTrue(all(path in ("/v1/health", "/v1/transcribe", "/__pichi_regression_missing_route__")
                            for _, _, path, _, _ in HARNESS.ERROR_CASES))


if __name__ == "__main__":
    unittest.main()
