"""Portable wiring guards for the physical-only, test-runner observation loop.

These guards ensure real XCTest queries remain behind the observation schedule
and retain final gates.
No app, device, microphone, model, native capture or Xcode build is started.
"""
import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Tests/MobileUITests/MobileNavigationUITests.swift").read_text()
SCHEDULE = (ROOT / "Tests/MobileUITests/PhysicalProductionObservationSchedule.swift").read_text()


class PhysicalUISmokeObservationTests(unittest.TestCase):
    def test_every_recording_query_is_behind_the_schedule(self):
        loop = SOURCE.split("while ProcessInfo.processInfo.systemUptime < speechDeadline {", 1)[1]
        loop = loop.split('mark("recording_observation_ended")', 1)[0]
        admission, queries = loop.split("let state = app.state", 1)
        self.assertIn("try Task.checkCancellation()", admission)
        self.assertIn("guard observationSchedule.beginUIHealthCheck", admission)
        self.assertIn("try await Task.sleep", admission)
        self.assertIn("continue", admission)
        for forbidden in ("app.", "recordingVisible()", "presentationDone.exists", "capture("):
            self.assertNotIn(forbidden, admission)
        self.assertIn("recordingVisible()", queries)
        # Periodic health sampling never probes presentation controls. The final
        # foreground acceptance below owns export/presentation verification.
        self.assertNotIn("presentationDone.exists", queries)
        self.assertIn("passedRecordingUIHealthChecks += 1", queries)
        self.assertIn("sleepAfterUIHealthCheckNanoseconds", queries)
        self.assertLess(queries.index("switch state"), queries.index("let healthCheckFinishedAt"))
        self.assertNotIn("Task.sleep(nanoseconds: 1_000_000_000)", loop)

    def test_only_admitted_hour_gets_sparse_observation(self):
        self.assertIn("longSmoke && observationSeconds == 3600 ? 30 : 1", SCHEDULE)
        self.assertIn("([45, 180].contains(observationSeconds) || (longSmoke && observationSeconds == 3600))", SOURCE)
        self.assertIn("!backgroundSmoke || observationSeconds == 180", SOURCE)
        self.assertNotIn("environment", SCHEDULE)
        self.assertIn("uptime < deadline", SCHEDULE)
        self.assertIn("nextUIHealthCheckAt = uptime + uiHealthCheckIntervalSeconds", SCHEDULE)
        self.assertIn("max(0, min(1, remaining))", SCHEDULE)
        self.assertIn("uiHealthCheckIntervalSeconds == 1 ? 1_000_000_000", SCHEDULE)

    def test_schedule_is_compiled_only_into_the_ui_test_target(self):
        project = (ROOT / "Fluid.xcodeproj/project.pbxproj").read_text()
        reference = re.search(r'(\w+) /\* Mobile test file Tests/MobileUITests/PhysicalProductionObservationSchedule.swift \*/', project)
        self.assertIsNotNone(reference)
        build = re.search(r'(\w+) /\* Mobile test build Tests/MobileUITests/PhysicalProductionObservationSchedule.swift \*/ = \{[^\n]*fileRef = ' + reference[1], project)
        self.assertIsNotNone(build)
        phases = re.findall(r'/\* ([^*]+) \*/ = \{ isa = PBXSourcesBuildPhase;([^\n]+)', project)
        owners = [name for name, body in phases if build[1] in body]
        self.assertEqual(owners, ["Mobile test Sources"])

    def test_report_discloses_sampling_and_retains_final_acceptance_gates(self):
        for field in ("recordingUIHealthCheckIntervalSeconds", "recordingUIHealthCheckCount",
                      "passedRecordingUIHealthCheckCount", "recordingUIHealthChecks",
                      "recordingUIObservationScope"):
            self.assertIn('"' + field + '":', SOURCE)
        self.assertIn("not continuously between checks", SOURCE)
        self.assertIn("independently captures native USB frames at 1 Hz", SOURCE)
        ending = SOURCE.split('mark("recording_observation_ended")', 1)[1].split("outcome = \"completed\"", 1)[0]
        for final_gate in ("try require(recordingVisible()", "stopDeadline", "waitForCompletion",
                           "paragraphs.firstMatch.waitForExistence", "transcript.exportProtected",
                           "activityList.waitForExistence", "native_activity_cancelled"):
            self.assertIn(final_gate, ending)
        self.assertIn("addTeardownBlock", SOURCE)
        self.assertIn("cleanup_requires_parent_inspection", SOURCE)


if __name__ == "__main__":
    unittest.main()
