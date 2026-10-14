#!/usr/bin/env python3
"""Offline protocol slices only: no capture, audio playback, UI or model loading."""
import http.client
import json
import os
from pathlib import Path
import tempfile
import threading
import time
import unittest
import uuid
import shutil
import subprocess

from meeting_continuity_fixture import Fixture, HTTPServer, ProtocolError, atomic_json, handler_for, read_json, wait_ack


class FixtureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name).resolve()
        self.root = self.directory / "run"
        self.root.mkdir(mode=0o700)
        self.stimulus = self.directory / "stimulus"
        self.stimulus.mkdir()
        (self.stimulus / "speech.wav").write_bytes(b"synthetic test placeholder")
        self.run = str(uuid.uuid4()).upper()
        self.token = "a" * 43
        self.fixture = Fixture(self.root, self.run, self.token, self.stimulus, ["speech.wav"], ack_timeout=0.25)
        self.ready = dict(runID=self.run, captureStartHostSeconds=99, readyHostSeconds=100, durationSeconds=100)
        atomic_json(self.root / "capture-ready.json", self.ready)
        self.begin("browserBefore", 1, 101)

    def tearDown(self):
        self.temporary.cleanup()

    def begin(self, phase, sequence, host):
        atomic_json(self.root / "phase-command.json", dict(
            runID=self.run, phase=phase, action="begin", sequence=sequence))
        atomic_json(self.root / "phase-ack.json", dict(
            runID=self.run, sequence=sequence, machAbsoluteHostSeconds=host))

    def payload(self, phase="browserBefore", event="starting", **changes):
        value = dict(runID=self.run, token=self.token, phase=phase, event=event)
        value.update(changes)
        return value

    def finish(self, phase, sequence, host, outcome=False):
        errors = []
        def native_mock():
            try:
                deadline = time.monotonic() + 2
                while time.monotonic() < deadline:
                    if read_json(self.root / "phase-command.json").get("sequence") == sequence:
                        atomic_json(self.root / "phase-ack.json", dict(
                            runID=self.run, sequence=sequence, machAbsoluteHostSeconds=host))
                        if outcome:
                            atomic_json(self.root / "outcome.json", dict(runID=self.run, status="mock"))
                        return
                    time.sleep(0.005)
                raise AssertionError("Mock did not see end command")
            except Exception as error:
                errors.append(error)
        worker = threading.Thread(target=native_mock)
        worker.start()
        try:
            return self.fixture.event(self.payload(phase, "ended"))
        finally:
            worker.join(3)
            self.assertFalse(worker.is_alive())
            self.assertFalse(errors, errors)

    def test_first_phase_slice_automatic_end_drains_then_retains_native_clock(self):
        self.assertEqual(self.fixture.event(self.payload())["status"], "playback-authorized")
        began = time.monotonic()
        result = self.finish("browserBefore", 2, 103.25)
        self.assertGreaterEqual(time.monotonic() - began, 0.5)
        self.assertEqual(result["sequence"], 2)
        self.assertEqual(result["machAbsoluteHostSeconds"], 103.25)
        self.assertEqual(read_json(self.root / "phase-command.json"), dict(
            runID=self.run, sequence=2, action="end", phase="browserBefore"))
        journal = [json.loads(line) for line in (self.root / "fixture-events.jsonl").read_text().splitlines()]
        self.assertEqual([entry["event"] for entry in journal], ["starting", "end-command", "end-ack"])
        self.assertEqual(journal[-1]["endMachAbsoluteHostSeconds"], 103.25)
        self.assertEqual((self.root / "phase-command.json").stat().st_mode & 0o777, 0o600)

    def test_three_phase_mock_slice_including_final_outcome_race(self):
        for phase, begin, end, host in [("browserBefore", 1, 2, 101), ("secondSource", 4, 5, 106),
                                         ("browserAfter", 7, 8, 115)]:
            self.begin(phase, begin, host)
            self.fixture.event(self.payload(phase))
            self.assertEqual(self.finish(phase, end, host + 1, outcome=end == 8)["sequence"], end)
        self.assertEqual(self.fixture.completed, {"browserBefore", "secondSource", "browserAfter"})

    def test_wrong_runs_tokens_skipped_and_unstarted_end_are_refused(self):
        for payload in [self.payload(runID=str(uuid.uuid4())), self.payload(token="wrong"),
                        self.payload(token="ё" * 43), self.payload(token={}),
                        self.payload(runID=12), self.payload(phase=[]),
                        self.payload("browserAfter"), self.payload(event="ended")]:
            with self.subTest(payload=payload), self.assertRaises(ProtocolError):
                self.fixture.event(payload)
        self.assertEqual(read_json(self.root / "phase-command.json")["sequence"], 1)

    def test_duplicate_start_and_completed_replay_refused(self):
        self.fixture.event(self.payload())
        with self.assertRaises(ProtocolError):
            self.fixture.event(self.payload())
        self.finish("browserBefore", 2, 102)
        self.begin("browserBefore", 1, 101)
        with self.assertRaises(ProtocolError):
            self.fixture.event(self.payload())

    def test_wrong_native_ack_and_command_phase_refused(self):
        for change in [dict(runID=str(uuid.uuid4())), dict(sequence=7), dict(machAbsoluteHostSeconds=99),
                       dict(machAbsoluteHostSeconds=float("inf"))]:
            value = dict(runID=self.run, sequence=1, machAbsoluteHostSeconds=101)
            value.update(change)
            (self.root / "phase-ack.json").write_text(json.dumps(value))
            with self.assertRaises(ProtocolError):
                self.fixture.event(self.payload())
        self.begin("browserAfter", 1, 101)
        with self.assertRaises(ProtocolError):
            self.fixture.event(self.payload())

    def test_stale_changed_ready_and_stopped_run_refused(self):
        os.utime(self.root / "capture-ready.json", (1, 1))
        with self.assertRaises(ProtocolError):
            self.fixture.event(self.payload())
        atomic_json(self.root / "capture-ready.json", self.ready)
        self.fixture.event(self.payload())
        atomic_json(self.root / "capture-ready.json", {**self.ready, "readyHostSeconds": 100.5})
        with self.assertRaises(ProtocolError):
            self.fixture.event(self.payload(event="ended"))
        atomic_json(self.root / "capture-ready.json", self.ready)
        atomic_json(self.root / "outcome.json", dict(runID=self.run))
        with self.assertRaises(ProtocolError):
            self.fixture.event(self.payload(event="ended"))

    def test_no_ack_is_failure_and_prevents_further_progression(self):
        self.fixture.event(self.payload())
        with self.assertRaisesRegex(ProtocolError, "timed out"):
            self.fixture.event(self.payload(event="ended"))
        self.assertTrue(self.fixture.failed)
        self.begin("secondSource", 4, 106)
        with self.assertRaises(ProtocolError):
            self.fixture.event(self.payload("secondSource"))

    def test_existing_native_phase_limit_not_extended(self):
        self.fixture.event(self.payload())
        phase, host, _ = self.fixture.active
        self.fixture.active = (phase, host, time.monotonic() - 59.6)
        with self.assertRaises(ProtocolError):
            self.fixture.event(self.payload(event="ended"))
        self.assertEqual(read_json(self.root / "phase-command.json")["sequence"], 1)

    def test_native_end_ack_cannot_expand_phase_duration(self):
        self.fixture.event(self.payload())
        with self.assertRaisesRegex(ProtocolError, "end clock"):
            self.finish("browserBefore", 2, 162)
        self.assertTrue(self.fixture.failed)

    def test_read_only_operator_ack_gate_is_fail_fast(self):
        self.assertEqual(wait_ack(self.root, self.run, 1)["machAbsoluteHostSeconds"], 101)
        with self.assertRaisesRegex(ProtocolError, "timed out"):
            wait_ack(self.root, self.run, 2, timeout=0.05)
        with self.assertRaisesRegex(ProtocolError, "sequence"):
            self.begin("browserAfter", 7, 115)
            wait_ack(self.root, self.run, 2)
        self.assertEqual(read_json(self.root / "phase-command.json")["sequence"], 7)

    def test_symlink_and_large_protocol_files_refused(self):
        path = self.root / "phase-ack.json"
        path.unlink()
        outside = self.directory / "outside.json"
        outside.write_text('{}')
        path.symlink_to(outside)
        with self.assertRaises(ProtocolError):
            self.fixture.event(self.payload())
        path.unlink()
        path.write_bytes(b" " * 8193)
        with self.assertRaises(ProtocolError):
            self.fixture.event(self.payload())

    def test_fresh_private_root_and_explicit_owned_wavs_required(self):
        with self.assertRaisesRegex(ProtocolError, "fresh"):
            Fixture(self.root, self.run, self.token, self.stimulus, ["speech.wav"])
        fresh = self.directory / "fresh"
        fresh.mkdir(mode=0o700)
        for name in ["../speech.wav", "speech.wav/anything", "missing.wav"]:
            with self.assertRaises((ProtocolError, FileNotFoundError)):
                Fixture(fresh, self.run, self.token, self.stimulus, [name])
        (self.stimulus / "link.wav").symlink_to(self.stimulus / "speech.wav")
        with self.assertRaises(ProtocolError):
            Fixture(fresh, self.run, self.token, self.stimulus, ["link.wav"])
        fresh.chmod(0o755)
        with self.assertRaises(ProtocolError):
            Fixture(fresh, self.run, self.token, self.stimulus, ["speech.wav"])

    def test_transport_prepared_receipt_before_capture_and_after_native_restart(self):
        (self.root / "capture-ready.json").unlink()
        self.assertEqual(self.fixture.prepared(self.payload(event="prepared"))["status"], "transport-prepared")
        self.assertEqual(read_json(self.root / "browser-prepared.json")["speechStarted"], False)
        with self.assertRaises(ProtocolError):
            self.fixture.prepared(self.payload(event="prepared"))
        atomic_json(self.root / "capture-ready.json", self.ready)
        with self.assertRaises(ProtocolError):
            self.fixture.prepared(self.payload("browserAfter", "prepared"))
        self.fixture.completed = {"browserBefore", "secondSource"}
        atomic_json(self.root / "phase-command.json", dict(runID=self.run, sequence=6, action="browserRestarted"))
        atomic_json(self.root / "phase-ack.json", dict(runID=self.run, sequence=6, machAbsoluteHostSeconds=115))
        self.assertEqual(self.fixture.prepared(self.payload("browserAfter", "prepared"))["status"], "transport-prepared")
        self.assertEqual(self.fixture.prepared_phase, "browserAfter")

    def test_http_only_serves_allowlist_and_bounded_authenticated_events(self):
        server = HTTPServer(("127.0.0.1", 0), handler_for(self.fixture))
        worker = threading.Thread(target=server.serve_forever)
        worker.start()
        try:
            def request(method, path, body=None, headers=None):
                connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=2)
                try:
                    connection.request(method, path, body, headers or {})
                    response = connection.getresponse()
                    return response.status, response.read()
                finally:
                    connection.close()
            self.assertEqual(request("GET", "/speech.wav")[0], 200)
            self.assertEqual(request("GET", "/meeting_browser_speech_stimulus.html")[0], 200)
            for path in ["/", "/capture-ready.json", "/../speech.wav", "/%2e%2e/speech.wav", "/secret.wav"]:
                self.assertEqual(request("GET", path)[0], 404)
            (self.stimulus / "speech.wav").unlink()
            (self.stimulus / "speech.wav").symlink_to(self.directory / "outside.wav")
            self.assertEqual(request("GET", "/speech.wav")[0], 404)
            headers = {"Content-Type": "application/json"}
            for body in ["x" * 2049, "[]", "null", json.dumps(self.payload(runID=42))]:
                self.assertEqual(request("POST", "/phase-event", body, headers)[0], 409)
            self.assertEqual(request("POST", "/phase-event", json.dumps(self.payload()),
                                     {**headers, "Origin": "https://example.invalid"})[0], 409)
            self.assertEqual(request("POST", "/phase-event", json.dumps(self.payload()), headers)[0], 200)
        finally:
            server.shutdown()
            worker.join(3)
            server.server_close()

    @unittest.skipUnless(shutil.which("node"), "Node is optional for browser-script mock tests")
    def test_browser_preparation_manual_compatibility_and_natural_end_event(self):
        # Runs the actual fixture script with pure DOM/WebRTC doubles. No browser or audio.
        script = r'''
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync(process.argv[1], 'utf8').split('<script>')[1].split('</script>')[0];
function fixture(query, rejectStart = false) {
  const events = [], sources = [];
  let starts = 0, resumes = 0, plays = 0;
  const elements = Object.fromEntries(['output', 'status', 'direct', 'rtc', 'prepare'].map(id =>
    [id, { disabled: false, hidden: id === 'prepare', textContent: '',
      play: async () => { plays++; }, pause() {}, removeAttribute() {} }]));
  class AudioContext {
    async resume() { resumes++; } async close() {}
    async decodeAudioData() { return {}; }
    createBufferSource() {
      const buffer = { connect() {}, start() { starts++; } };
      sources.push(buffer); return buffer;
    }
    createMediaStreamDestination() { return { stream: { getTracks: () => [{}] } }; }
  }
  class RTCPeerConnection {
    constructor() { this.connectionState = 'connected'; }
    addTrack() {} close() {} async createOffer() { return {}; } async createAnswer() { return {}; }
    async setLocalDescription(value) { this.localDescription = value; }
    async setRemoteDescription(value) {
      this.remoteDescription = value;
      if (this.ontrack) await this.ontrack({ streams: [{}] });
    }
    async addIceCandidate() {}
  }
  const context = vm.createContext({ URLSearchParams, location: { search: query },
    document: { querySelector: selector => elements[selector.slice(1)],
      querySelectorAll: () => [elements.direct, elements.rtc, elements.prepare] },
    AudioContext, RTCPeerConnection, setTimeout, clearTimeout,
    fetch: async (url, options) => {
      if (!options) return { arrayBuffer: async () => new ArrayBuffer(0) };
      const payload = JSON.parse(options.body); events.push(payload);
      const ok = !(rejectStart && payload.event === 'starting');
      return { ok, json: async () => ok ? { sequence: 2 } : { error: 'Missing native begin ack' } };
    } });
  vm.runInContext(source, context);
  return { elements, events, sources, starts: () => starts,
    resumes: () => resumes, plays: () => plays };
}
(async () => {
  const query = '?runID=00000000-0000-4000-8000-000000000000&token=' + 'a'.repeat(43) +
    '&phase=browserBefore&stimulus=browser-before.wav';
  const gated = fixture(query);
  assert.equal(gated.elements.rtc.disabled, true);
  await gated.elements.prepare.onclick();
  assert.equal(gated.starts(), 0);
  assert.equal(gated.events.length, 0);
  assert.match(gated.elements.status.textContent, /^Prepared/);
  await gated.elements.rtc.onclick();
  assert.equal(gated.starts(), 1);
  assert.equal(gated.events[0].event, 'starting');
  await gated.sources[0].onended();
  assert.deepEqual(gated.events.map(event => event.event), ['starting', 'ended']);
  assert.match(gated.elements.status.textContent, /Native end acknowledged \(2\)/);
  await gated.sources[0].onended();
  assert.equal(gated.events.length, 2);
  const denied = fixture(query, true);
  await denied.elements.prepare.onclick();
  await denied.elements.rtc.onclick();
  assert.equal(denied.starts(), 0);
  await denied.sources[0].onended();
  assert.equal(denied.events.length, 1);
  assert.match(denied.elements.status.textContent, /Playback failed/);
  const manual = fixture('');
  await manual.elements.direct.onclick();
  await manual.elements.output.onended();
  assert.equal(manual.elements.output.src, 'speech.wav');
  assert.equal(manual.elements.status.textContent, 'Direct speech complete.');
  await manual.elements.rtc.onclick();
  assert.equal(manual.starts(), 1);
  await manual.sources[0].onended();
  assert.equal(manual.elements.status.textContent, 'Received WebRTC speech complete.');
  assert.equal(manual.events.length, 0);
  const automatic = fixture(query + '&autoPrepare=1');
  await new Promise(resolve => setImmediate(resolve));
  assert.match(automatic.elements.status.textContent, /^Prepared/);
  assert.equal(automatic.starts(), 0);
  assert.equal(automatic.resumes(), 0);
  assert.equal(automatic.plays(), 0);
  assert.deepEqual(automatic.events.map(event => event.event), ['prepared']);
  await automatic.elements.rtc.onclick();
  assert.equal(automatic.starts(), 1);
  assert.equal(automatic.resumes(), 1);
  assert.equal(automatic.plays(), 1);
  await automatic.sources[0].onended();
  assert.deepEqual(automatic.events.map(event => event.event), ['prepared', 'starting', 'ended']);
})().catch(error => { console.error(error); process.exitCode = 1; });
'''
        subprocess.run([shutil.which("node"), "-e", script,
                        str(Path(__file__).with_name("meeting_browser_speech_stimulus.html"))],
                       check=True, timeout=5, capture_output=True)


if __name__ == "__main__":
    unittest.main()
