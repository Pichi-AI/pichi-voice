#!/usr/bin/env python3
"""Offline Git/GitHub regressions for published app releases outside main."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "repos/altic-dev/FluidVoice/"
TAG = "v2.3.4-beta.1"


class PublishedUpstreamReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="pichi-published-release-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.upstream = self.root / "upstream"
        self.downstream = self.root / "downstream"
        self.env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1",
                        GIT_AUTHOR_NAME="Sync test", GIT_AUTHOR_EMAIL="sync@example.invalid",
                        GIT_COMMITTER_NAME="Sync test", GIT_COMMITTER_EMAIL="sync@example.invalid",
                        GH_HOST="must-not-select-this-host.example.invalid",
                        PICHI_VOICE_WORKTREE_ROOT=str(self.root / "worktrees"))
        self.upstream.mkdir()
        self.git(self.upstream, "init", "-q", "-b", "main")
        scripts = self.upstream / "scripts/dev"
        scripts.mkdir(parents=True)
        for name in ("prepare-upstream-sync.sh", "new-worktree.sh", "verify-published-upstream-release.py"):
            shutil.copyfile(ROOT / "scripts/dev" / name, scripts / name)
        (self.upstream / "baseline.txt").write_text("common baseline\n")
        self.commit(self.upstream, "baseline")
        self.git(self.root, "clone", "-q", "--bare", str(self.upstream), str(self.root / "origin.git"))
        self.git(self.root, "clone", "-q", str(self.root / "origin.git"), str(self.downstream))
        self.git(self.downstream, "remote", "add", "upstream", str(self.upstream))
        self.git(self.downstream, "config", "remote.upstream.pushurl", "DISABLED")
        (self.downstream / "downstream.txt").write_text("downstream feature\n")
        self.commit(self.downstream, "downstream")
        self.git(self.downstream, "push", "-q", "origin", "main")
        self.baseline = self.git(self.downstream, "rev-parse", "HEAD")
        self.git(self.upstream, "checkout", "-qb", "release-branch")
        (self.upstream / "release.txt").write_text("published branch feature\n")
        self.commit(self.upstream, "published branch release")
        self.expected = self.git(self.upstream, "rev-parse", "HEAD")
        self.git(self.upstream, "tag", TAG)
        self.git(self.upstream, "checkout", "-q", "main")
        (self.upstream / "unreleased.txt").write_text("main-only feature\n")
        self.commit(self.upstream, "unreleased main")
        self.main = self.git(self.upstream, "rev-parse", "HEAD")
        self.git(self.upstream, "tag", "v1.0.0")

        binary = self.root / "bin"
        binary.mkdir()
        fake_gh = binary / "gh"
        fake_gh.write_text("""#!/usr/bin/env python3
import json, os, pathlib, sys
with open(os.environ['FAKE_GH_CALLS'], 'a') as stream:
    stream.write(json.dumps(sys.argv[1:]) + '\\n')
if len(sys.argv) != 5 or sys.argv[1:4] != ['api', '--hostname', 'github.com']:
    sys.exit(90)
responses = json.loads(pathlib.Path(os.environ['FAKE_GH_RESPONSES']).read_text())
response = responses.get(sys.argv[4])
if response is None:
    sys.exit(91)
if response.get('exit', 0):
    sys.exit(response['exit'])
print(response['raw'] if 'raw' in response else json.dumps(response['json']))
""")
        fake_gh.chmod(0o755)
        self.calls_file = self.root / "gh-calls.jsonl"
        self.responses_file = self.root / "gh-responses.json"
        self.env.update(PATH=str(binary) + os.pathsep + self.env["PATH"],
                        FAKE_GH_CALLS=str(self.calls_file), FAKE_GH_RESPONSES=str(self.responses_file))
        self.configure()

    def git(self, directory, *args):
        result = subprocess.run(["git", "-C", str(directory), *args], env=self.env,
                                capture_output=True, text=True, check=True)
        return result.stdout.strip()

    def commit(self, directory, message):
        self.git(directory, "add", ".")
        self.git(directory, "commit", "-qm", message)

    def configure(self, tag=TAG):
        self.tag = tag
        self.release = {"tag_name": tag, "draft": False, "prerelease": "-beta." in tag,
                        "published_at": "2026-10-25T09:45:47Z", "target_commitish": "ignored-untrusted-value",
                        "assets": [{"name": f"Fluid-oss-{tag[1:]}.dmg", "state": "uploaded", "size": 123}]}
        self.ref = {"ref": f"refs/tags/{tag}", "object": {"type": "commit", "sha": self.expected,
                                                                       "url": "https://untrusted.example/ignored"}}
        self.responses = {REPOSITORY + f"releases/tags/{tag}": {"json": self.release},
                          REPOSITORY + f"git/ref/tags/{tag}": {"json": self.ref}}

    def sync(self, *refs):
        self.responses_file.write_text(json.dumps(self.responses))
        self.calls_file.write_text("")
        result = subprocess.run(["bash", "scripts/dev/prepare-upstream-sync.sh", *refs], cwd=self.downstream,
                                env=self.env, capture_output=True, text=True, timeout=30)
        self.output = result.stdout + result.stderr
        self.calls = [json.loads(line) for line in self.calls_file.read_text().splitlines()]
        self.assertEqual(self.git(self.downstream, "rev-parse", "main"), self.baseline)
        self.assertEqual(self.git(self.downstream, "ls-remote", "origin", "refs/heads/main").split()[0], self.baseline)
        for call in self.calls:
            self.assertEqual(call[:3], ["api", "--hostname", "github.com"])
            self.assertTrue(call[3].startswith(REPOSITORY))
        return result

    def worktree_count(self):
        return sum(line.startswith("worktree ") for line in self.git(self.downstream, "worktree", "list", "--porcelain").splitlines())

    def assert_rejected(self, ref=TAG, message="verification failed"):
        before = self.worktree_count()
        result = self.sync(ref)
        self.assertNotEqual(result.returncode, 0, self.output)
        self.assertIn(message, self.output)
        self.assertEqual(self.worktree_count(), before)

    def assert_release_merge(self, tag=TAG):
        result = self.sync(tag)
        self.assertEqual(result.returncode, 0, self.output)
        directory = next(line.removeprefix("Sync worktree: ") for line in self.output.splitlines()
                         if line.startswith("Sync worktree: "))
        self.assertEqual(self.git(directory, "rev-parse", "MERGE_HEAD"), self.expected)
        self.assertEqual(self.git(directory, "rev-parse", "HEAD"), self.baseline)
        self.assertTrue((Path(directory) / "release.txt").is_file())
        self.assertTrue((Path(directory) / "downstream.txt").is_file())
        self.assertFalse((Path(directory) / "unreleased.txt").exists())

    def test_published_stable_branch_release(self):
        tag = "v2.3.4"
        self.git(self.upstream, "tag", tag, self.expected)
        self.configure(tag)
        self.assert_release_merge(tag)
        self.assertEqual(len(self.calls), 2)

    def test_published_beta_nested_annotated_tags(self):
        self.git(self.upstream, "tag", "-am", "inner tag", "inner-tag", self.expected)
        self.git(self.upstream, "tag", "-fam", "outer tag", TAG, "inner-tag")
        sha = self.git(self.upstream, "rev-parse", f"refs/tags/{TAG}")
        self.ref["object"] = {"type": "tag", "sha": sha}
        while self.git(self.upstream, "cat-file", "-t", sha) == "tag":
            target = self.git(self.upstream, "cat-file", "-p", sha).splitlines()[0].split()[1]
            kind = self.git(self.upstream, "cat-file", "-t", target)
            self.responses[REPOSITORY + f"git/tags/{sha}"] = {"json": {"sha": sha, "object": {"type": kind, "sha": target}}}
            sha = target
        self.assert_release_merge()
        self.assertEqual(len(self.calls), 4)

    def test_inside_main_targets_have_no_github_dependency(self):
        self.responses = {}
        for refs in ((), ("v1.0.0",), (self.main,)):
            with self.subTest(refs=refs):
                result = self.sync(*refs)
                self.assertEqual(result.returncode, 0, self.output)
                self.assertEqual(self.calls, [])

    def test_noncanonical_selections_never_query_github(self):
        self.git(self.downstream, "fetch", "upstream", "main", "--tags")
        self.git(self.downstream, "branch", "release-branch", self.expected)
        self.git(self.downstream, "branch", TAG, self.baseline)
        for ref in (self.expected, "release-branch", f"refs/heads/{TAG}", f"refs/tags/{TAG}", f"{TAG}^{{commit}}"):
            with self.subTest(ref=ref):
                # Explicit branch selection points outside main even when it has a tag-like name.
                if ref.startswith("refs/heads/"):
                    self.git(self.downstream, "branch", "-f", TAG, self.expected)
                self.assert_rejected(ref)
                self.assertEqual(self.calls, [])

    def test_windows_runtime_and_other_tag_channels_are_denied(self):
        for tag in ("v2.3.4-windows", "v2.3.4-runtime", "v2.3.4-rc.1", "v02.3.4", "v2.3.4-beta.01"):
            with self.subTest(tag=tag):
                self.git(self.upstream, "tag", tag, self.expected)
                self.configure(tag)
                self.assert_rejected(tag)
                self.assertEqual(self.calls, [])

    def test_draft_unpublished_and_wrong_release_are_denied(self):
        for field, value in (("draft", True), ("draft", "false"), ("draft", 0), ("tag_name", "v2.3.3"),
                             ("published_at", None), ("published_at", ""), ("published_at", 123),
                             ("published_at", "not-a-date"), ("published_at", "2026-10-25T09:45:47")):
            with self.subTest(field=field, value=value):
                self.configure()
                self.release[field] = value
                self.assert_rejected()

    def test_missing_or_non_app_assets_are_denied(self):
        for assets in (None, [], [None], [{"name": f"Fluid-oss-{TAG[1:]}.zip", "state": "uploaded", "size": 123}],
                       [{"name": "FluidVoice-windows.exe", "state": "uploaded", "size": 123}],
                       [{"name": "runtime.dmg", "state": "uploaded", "size": 123}]):
            with self.subTest(assets=assets):
                self.configure()
                self.release["assets"] = assets
                self.assert_rejected()
        for field, value in (("state", "new"), ("size", 0), ("size", True), ("size", "123"),
                             ("name", "Fluid-oss-2.3.3.dmg")):
            with self.subTest(field=field, value=value):
                self.configure()
                self.release["assets"][0][field] = value
                self.assert_rejected()

    def test_api_failures_and_malformed_roots_are_denied(self):
        for endpoint in ("releases/tags/", "git/ref/tags/"):
            for response in ({"exit": 1}, {"raw": "not json"}, {"json": []}, {"json": None}):
                with self.subTest(endpoint=endpoint, response=response):
                    self.configure()
                    self.responses[REPOSITORY + endpoint + TAG] = response
                    self.assert_rejected()

    def test_wrong_exact_ref_and_unknown_git_objects_are_denied(self):
        variants = ({"ref": f"refs/tags/{TAG}-other"}, {"object": None}, {"object": {}},
                    {"object": {"type": "tree", "sha": self.expected}},
                    {"object": {"type": "blob", "sha": self.expected}},
                    {"object": {"type": "commit", "sha": "bad"}},
                    {"object": {"type": "commit", "sha": "f" * 40}})
        for replacement in variants:
            with self.subTest(replacement=replacement):
                self.configure()
                self.ref.update(replacement)
                self.assert_rejected()

    def test_annotated_tag_errors_are_denied(self):
        sha = "a" * 40
        for response in ({"exit": 1}, {"json": {"sha": "b" * 40, "object": {"type": "commit", "sha": self.expected}}},
                         {"json": {"sha": sha}}, {"json": {"sha": sha, "object": {"type": "tree", "sha": self.expected}}},
                         {"json": {"sha": sha, "object": {"type": "tag", "sha": sha}}}):
            with self.subTest(response=response):
                self.configure()
                self.ref["object"] = {"type": "tag", "sha": sha}
                self.responses[REPOSITORY + f"git/tags/{sha}"] = response
                self.assert_rejected()
                self.assertLessEqual(len(self.calls), 3)

    def test_annotated_tag_depth_is_bounded(self):
        self.ref["object"] = {"type": "tag", "sha": f"{1:040x}"}
        for index in range(1, 10):
            sha = f"{index:040x}"
            self.responses[REPOSITORY + f"git/tags/{sha}"] = {"json": {"sha": sha,
                "object": {"type": "tag", "sha": f"{index + 1:040x}"}}}
        self.assert_rejected(message="depth limit")
        self.assertEqual(len(self.calls), 10)

    def test_eight_annotated_tag_objects_can_resolve_to_a_commit(self):
        self.ref["object"] = {"type": "tag", "sha": f"{1:040x}"}
        for index in range(1, 9):
            sha = f"{index:040x}"
            target = {"type": "commit", "sha": self.expected} if index == 8 else \
                {"type": "tag", "sha": f"{index + 1:040x}"}
            self.responses[REPOSITORY + f"git/tags/{sha}"] = {"json": {"sha": sha, "object": target}}
        self.assert_release_merge()
        self.assertEqual(len(self.calls), 10)

    def test_local_exact_tag_must_match_selected_commit(self):
        self.responses_file.write_text(json.dumps(self.responses))
        self.calls_file.write_text("")
        self.git(self.downstream, "fetch", "upstream", "main", "--tags")
        result = subprocess.run(["python3", "-S", "scripts/dev/verify-published-upstream-release.py", TAG, self.main],
                                cwd=self.downstream, env=self.env, capture_output=True, text=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Exact local tag does not match", result.stderr)
        self.assertEqual(self.calls_file.read_text(), "")

    def test_published_orphan_history_is_still_denied(self):
        self.git(self.upstream, "checkout", "-q", "--orphan", "orphan")
        self.git(self.upstream, "rm", "-qrf", ".")
        (self.upstream / "orphan.txt").write_text("unrelated published history\n")
        self.commit(self.upstream, "orphan")
        self.expected = self.git(self.upstream, "rev-parse", "HEAD")
        self.git(self.upstream, "tag", "-f", TAG)
        self.git(self.upstream, "checkout", "-q", "main")
        self.configure()
        self.assert_rejected(message="no common ancestry")
        self.assertEqual(len(self.calls), 2)


if __name__ == "__main__":
    unittest.main()
