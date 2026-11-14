"""Portable regressions for quarantine expiry and the skip registry."""
from datetime import date
import importlib.util
from pathlib import Path
import sys
import unittest
from unittest import mock

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("check_test_policy", ROOT / "scripts/dev/check-test-policy.py")
POLICY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(POLICY)
TODAY = date(2026, 11, 5)


def entry(**changes):
    value = {"test": "FluidDictationIntegrationTests/SearchIndexTests/testExample", "owner": "maintainer",
             "reason": "Fails on the upstream image", "expires": "2026-11-05"}
    value.update(changes)
    return value


def quarantine(*entries):
    return {"version": 1, "entries": list(entries)}


class StrictJsonTests(unittest.TestCase):
    def test_duplicate_keys_are_refused(self):
        self.assertEqual(POLICY.strict_json('{"a": 1, "b": {"c": 2}}'), {"a": 1, "b": {"c": 2}})
        with self.assertRaisesRegex(ValueError, "duplicate keys: x"):
            POLICY.strict_json('{"tests": {"x": 1, "y": 2, "x": 3}}')


class QuarantineTests(unittest.TestCase):
    def test_entry_is_valid_through_its_last_day(self):
        self.assertEqual(POLICY.quarantine_problems(quarantine(entry()), TODAY), [])

    def test_expired_entry_fails(self):
        problems = POLICY.quarantine_problems(quarantine(entry(expires="2026-11-04")), TODAY)
        self.assertIn("expired", problems[0])

    def test_every_field_is_required(self):
        for field in ("owner", "reason", "expires"):
            value = entry()
            del value[field]
            self.assertTrue(POLICY.quarantine_problems(quarantine(value), TODAY), field)

    def test_blank_and_malformed_values_fail(self):
        self.assertTrue(POLICY.quarantine_problems(quarantine(entry(owner="  ")), TODAY))
        self.assertTrue(POLICY.quarantine_problems(quarantine(entry(expires="soon")), TODAY))
        self.assertTrue(POLICY.quarantine_problems(quarantine(entry(test="whole-suite")), TODAY))

    def test_duplicates_and_shape_fail(self):
        self.assertTrue(POLICY.quarantine_problems(quarantine(entry(), entry()), TODAY))
        self.assertTrue(POLICY.quarantine_problems({"entries": []}, TODAY))

    def test_scope_can_only_name_the_ci_runner(self):
        self.assertEqual(POLICY.quarantine_problems(quarantine(entry(test="probe:ui_contrast", scope="ci")), TODAY), [])
        for value in ("local", "", None, True):
            self.assertIn("scope", POLICY.quarantine_problems(quarantine(entry(scope=value)), TODAY)[0], value)

    def test_expiry_cannot_be_far_away(self):
        self.assertEqual(POLICY.quarantine_problems(quarantine(entry(expires="2027-02-03")), TODAY), [])
        self.assertIn("90 days", POLICY.quarantine_problems(quarantine(entry(expires="2027-02-04")), TODAY)[0])

    def test_probe_ids_are_accepted(self):
        for test in ("probe:ui_contrast", "probe:test-memory-audio-archive"):
            self.assertEqual(POLICY.quarantine_problems(quarantine(entry(test=test)), TODAY), [])


class SkipRegistryTests(unittest.TestCase):
    test = "FluidDictationIntegrationTests/SearchIndexTests/testExample()"

    def registry(self, **value):
        return {"version": 1, "tests": {self.test: {"layer": "L3-real-model", "reason": "Needs a model", **value}}}

    def test_valid_entry(self):
        self.assertEqual(POLICY.registry_problems(self.registry()), [])

    def test_unknown_layer_or_blank_reason_fails(self):
        self.assertTrue(POLICY.registry_problems(self.registry(layer="someday")))
        self.assertTrue(POLICY.registry_problems(self.registry(reason=" ")))

    def test_new_skip_is_reported(self):
        other = "FluidDictationIntegrationTests/SearchIndexTests/testOther()"
        problems = POLICY.result_problems({self.test: "Skipped", other: "Skipped"}, self.registry())
        self.assertEqual(len(problems), 1)
        self.assertIn(other, problems[0])

    def test_a_registered_test_may_pass(self):
        self.assertEqual(POLICY.result_problems({self.test: "Passed"}, self.registry()), [])

    def test_a_deleted_test_is_reported_for_a_complete_bundle(self):
        other = "FluidDictationIntegrationTests/SearchIndexTests/testOther()"
        problems = POLICY.result_problems({other: "Passed"}, self.registry(), complete=True)
        self.assertIn("no such test", problems[0])

    def test_a_focused_run_does_not_report_missing_tests(self):
        other = "FluidDictationIntegrationTests/SearchIndexTests/testOther()"
        self.assertEqual(POLICY.result_problems({other: "Passed"}, self.registry()), [])

    def test_a_bundle_that_did_not_run_says_nothing(self):
        results = {"PichiVoiceMobileIntegrationTests/AClass/testOne()": "Passed"}
        self.assertEqual(POLICY.result_problems(results, self.registry(), complete=True), [])

    def test_ids_match_with_or_without_parentheses(self):
        bare = self.test.removesuffix("()")
        self.assertEqual(POLICY.result_problems({bare: "Skipped"}, self.registry()), [])
        self.assertEqual(POLICY.result_problems({self.test: "Skipped"}, {"version": 1, "tests": {bare: {}}}), [])
        self.assertEqual(POLICY.result_problems({bare: "Passed"}, self.registry(), complete=True), [])

    def test_registry_keys_that_differ_only_by_parentheses_fail(self):
        bare = self.test.removesuffix("()")
        value = self.registry()
        value["tests"][bare] = dict(value["tests"][self.test])
        problems = POLICY.registry_problems(value)
        self.assertEqual(len(problems), 1)
        self.assertIn("duplicate", problems[0])

    def test_unknown_status_fails_closed(self):
        problems = POLICY.result_problems({self.test: "skipped", "A/B/testC": "Passed"}, self.registry())
        self.assertEqual(len(problems), 1)
        self.assertIn(self.test, problems[0])
        self.assertIn("'skipped'", problems[0])

    def test_known_statuses_are_accepted(self):
        results = {f"A/B/test{index}": status
                   for index, status in enumerate(("Passed", "Failed", "Expected Failure"))}
        self.assertEqual(POLICY.result_problems(results, self.registry()), [])


class CommandLineTests(unittest.TestCase):
    def run_main(self, *arguments, results=None):
        import contextlib
        import io
        import json
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            command = ["check-test-policy.py", *arguments]
            if results is not None:
                path = Path(directory) / "results.json"
                path.write_text(json.dumps(results))
                command += ["--results", str(path)]
            errors = io.StringIO()
            with mock.patch.object(sys, "argv", command), contextlib.redirect_stderr(errors), \
                    contextlib.redirect_stdout(io.StringIO()):
                try:
                    code = POLICY.main()
                except SystemExit as exit:
                    code = exit.code
        return code, errors.getvalue()

    def test_complete_needs_results(self):
        code, errors = self.run_main("--complete")
        self.assertEqual(code, 2)
        self.assertIn("--complete needs --results", errors)

    def test_complete_reports_missing_registered_tests_only_when_asked(self):
        import json
        registry = json.loads(POLICY.SKIPS.read_text())["tests"]
        if not registry:
            self.skipTest("no registered skips")
        test = next(iter(registry))
        results = {test.split("/", 1)[0] + "/Other/testNone": "Passed"}
        self.assertEqual(self.run_main(results=results)[0], 0)
        code, errors = self.run_main("--complete", results=results)
        self.assertEqual(code, 1)
        self.assertIn("no such test", errors)

    def test_repository_policy_files_are_valid(self):
        import json
        registry = json.loads(POLICY.SKIPS.read_text())
        self.assertEqual(POLICY.registry_problems(registry), [])
        self.assertEqual(POLICY.quarantine_problems(json.loads(POLICY.QUARANTINE.read_text()), date.today()), [])


if __name__ == "__main__":
    unittest.main()
