"""Portable regressions for quarantine expiry and the skip registry."""
from datetime import date
import importlib.util
from pathlib import Path
import sys
import unittest

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
        self.assertEqual(POLICY.unregistered_skips([self.test, other], self.registry()), [other])

    def test_repository_policy_files_are_valid(self):
        import json
        registry = json.loads(POLICY.SKIPS.read_text())
        self.assertEqual(POLICY.registry_problems(registry), [])
        self.assertEqual(POLICY.quarantine_problems(json.loads(POLICY.QUARANTINE.read_text()), date.today()), [])


if __name__ == "__main__":
    unittest.main()
