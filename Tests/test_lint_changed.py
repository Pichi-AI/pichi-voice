"""Portable regressions for the changed-line SwiftLint filter."""
import importlib.util
from pathlib import Path
import sys
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("lint_changed", ROOT / "scripts/dev/lint-changed.py")
LINT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LINT)


class ChangedLinesTests(unittest.TestCase):
    def test_hunks_map_to_added_lines_only(self):
        diff = "\n".join([
            "diff --git a/Sources/A.swift b/Sources/A.swift",
            "--- a/Sources/A.swift",
            "+++ b/Sources/A.swift",
            "@@ -3,0 +4,2 @@",
            "+one",
            "+two",
            "@@ -9 +11 @@",
            "-old",
            "+new",
            "@@ -20,2 +21,0 @@",
            "-removed",
            "-removed",
            "diff --git a/Sources/Deleted.swift b/Sources/Deleted.swift",
            "--- a/Sources/Deleted.swift",
            "+++ /dev/null",
            "@@ -1 +0,0 @@",
            "-gone",
        ])
        self.assertEqual(LINT.changed_lines(diff), {"Sources/A.swift": {4, 5, 11}})

    def test_body_text_cannot_pass_for_a_file_header(self):
        diff = "\n".join([
            "diff --git a/Sources/A.swift b/Sources/A.swift",
            "--- a/Sources/A.swift",
            "+++ b/Sources/A.swift",
            "@@ -1,0 +2,3 @@",
            "+++ b/Sources/Forged.swift",
            "+text\x0c@@ -1,0 +900 @@",
            "+last",
        ])
        self.assertEqual(LINT.changed_lines(diff), {"Sources/A.swift": {2, 3, 4}})

    def test_path_with_spaces_keeps_its_name(self):
        diff = "\n".join([
            "diff --git a/Sources/My File.swift b/Sources/My File.swift",
            "--- a/Sources/My File.swift\t",
            "+++ b/Sources/My File.swift\t",
            "@@ -1 +1 @@",
            "-old",
            "+new",
        ])
        self.assertEqual(LINT.changed_lines(diff), {"Sources/My File.swift": {1}})

    def test_unreadable_path_stops_instead_of_skipping_the_file(self):
        diff = "\n".join([
            'diff --git "a/Sources/A\\tB.swift" "b/Sources/A\\tB.swift"',
            '--- "a/Sources/A\\tB.swift"',
            '+++ "b/Sources/A\\tB.swift"',
            "@@ -1 +1 @@",
        ])
        with self.assertRaisesRegex(ValueError, "Unreadable path"):
            LINT.changed_lines(diff)

    def test_only_changed_lines_are_reported_in_stable_order(self):
        report = [
            {"file": "/repo/Sources/A.swift", "line": 11, "rule_id": "comma", "reason": "r"},
            {"file": "/repo/Sources/A.swift", "line": 4, "rule_id": "force_cast", "reason": "r"},
            {"file": "/repo/Sources/A.swift", "line": 5000, "rule_id": "force_cast", "reason": "baseline"},
        ]
        found = LINT.violations_on_changed_lines(report, {"Sources/A.swift": {4, 11}}, "/repo")
        self.assertEqual([item["line"] for item in found], [4, 11])
        self.assertEqual(found[0]["file"], "Sources/A.swift")

    def test_a_path_outside_the_diff_stops_instead_of_vanishing(self):
        report = [{"file": "/repo/Sources/Other.swift", "line": 4, "rule_id": "force_cast", "reason": "r"}]
        with self.assertRaisesRegex(ValueError, "outside the diff"):
            LINT.violations_on_changed_lines(report, {"Sources/A.swift": {4}}, "/repo")

    def test_the_same_name_in_another_unicode_form_still_matches(self):
        report = [{"file": "/repo/Sources/\u0424\u0430\u0438\u0306\u043b.swift", "line": 4, "rule_id": "force_cast", "reason": "r"}]
        found = LINT.violations_on_changed_lines(report, {"Sources/\u0424\u0430\u0439\u043b.swift": {4}}, "/repo")
        self.assertEqual([item["line"] for item in found], [4])

    def test_only_crash_prone_rules_in_production_code_block(self):
        self.assertTrue(LINT.blocks_change({"rule_id": "force_cast", "file": "Sources/A.swift"}))
        self.assertTrue(LINT.blocks_change({"rule_id": "force_unwrapping", "file": "Sources/A.swift"}))
        self.assertFalse(LINT.blocks_change({"rule_id": "force_cast", "file": "Tests/A.swift"}))
        self.assertFalse(LINT.blocks_change({"rule_id": "force_cast", "file": "Vendor/A.swift"}))
        self.assertFalse(LINT.blocks_change({"rule_id": "multiline_arguments", "file": "Sources/A.swift"}))


if __name__ == "__main__":
    unittest.main()
