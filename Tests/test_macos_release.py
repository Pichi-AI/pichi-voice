"""Offline release contracts. Native/GitHub commands are deterministic substitutes.

Synthetic temporary Git repositories exercise real source/archive behavior. No
signing, app builds, mounts, network access or public mutation occurs here.
"""
import argparse
import copy
import datetime as dt
import gzip
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("macos_release", ROOT / "scripts/dev/macos-release.py")
m = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m)


def git(root, *args):
    return subprocess.run(["git", *args], cwd=root, check=True, capture_output=True).stdout


class Boundaries(m.Commands):
    def __init__(self, app, revision):
        self.app, self.revision = app, revision
        self.calls, self.mounts = [], set()
        self.native_failure = None
        self.detach_failure = False
        self.architecture = b"arm64\n"
        self.signature_transform = lambda value: value
        self.attach_failure = None
        self.mutate_payload = None
        self.repo_public = True
        self.tag_sha = None
        self.release = None
        self.latest_release = None
        self.lock_sha = None
        self.asset_data = {}
        self.uncertain = set()
        self.before_write_failure = set()
        self.download_corrupt = False
        self.raw_response = None
        self.downloads = []

    def result(self, args, data=b"", code=0, text=False, stderr=b""):
        if text:
            data, stderr = data.decode(), stderr.decode()
        return subprocess.CompletedProcess(args, code, data, stderr)

    def run(self, args, **kwargs):
        self.calls.append(args)
        command = args[0]
        if command == "git":
            if args[1] == "fetch":
                return self.result(args)
            return super().run(args, **kwargs)
        if command in ("codesign", "xcrun", "spctl", "lipo", "hdiutil"):
            if self.native_failure and self.native_failure(args):
                raise m.ReleaseError("Injected native failure")
            if command == "codesign":
                return self.result(args, text=kwargs.get("text", False), stderr=self.signature_transform((
                    b"Identifier=ai.pichi.voice\nAuthority=Developer ID Application: Synthetic\n"
                    b"TeamIdentifier=LU46F7HGJM\nTimestamp=now\nflags=runtime\n")))
            if command == "lipo":
                return self.result(args, self.architecture)
            if args[:2] == ["hdiutil", "attach"]:
                mount = Path(args[args.index("-mountpoint") + 1])
                self.mounts.add(mount)
                shutil.copytree(self.app, mount / "Pichi Voice.app", symlinks=True)
                (mount / "Applications").symlink_to("/Applications")
                if self.mutate_payload:
                    self.mutate_payload(mount)
                if self.attach_failure == "cancel":
                    raise KeyboardInterrupt
                if self.attach_failure == "error":
                    raise m.ReleaseError("Uncertain attach")
                if self.attach_failure == "malformed":
                    return self.result(args, b"bad plist")
                return self.result(args, plistlib.dumps({"system-entities": [{"mount-point": str(mount.resolve())}]}))
            if args[:2] == ["hdiutil", "detach"]:
                if self.detach_failure:
                    return self.result(args, code=1)
                self.mounts.discard(Path(args[2]))
            if args[:2] == ["hdiutil", "info"]:
                return self.result(args, plistlib.dumps({"images": [{"system-entities": [{"mount-point": str(p)} for p in self.mounts]}]}))
            return self.result(args)
        if command == m.sys.executable and Path(args[1]).name == "package-macos-dmg.py":
            Path(args[args.index("--output") + 1]).write_bytes(b"synthetic dmg payload")
            return self.result(args)
        if command == "gh":
            if args[1:3] == ["release", "upload"]:
                name = Path(args[4]).name
                if name in self.before_write_failure:
                    raise m.ReleaseError("Upload rejected")
                self.asset_data[name] = Path(args[4]).read_bytes()
                if "upload" in self.uncertain:
                    raise subprocess.TimeoutExpired(args, 300)
                return self.result(args)
            if self.raw_response is not None:
                return self.result(args, self.raw_response)
            method = args[args.index("--method") + 1]
            endpoint = args[args.index("--method") + 2]
            if endpoint == "repos/" + m.REPO + "/":
                return self.result(args, b'HTTP/2.0 404 Not Found\n\n{}', code=1)
            if endpoint == "repos/" + m.REPO:
                endpoint = ""
            endpoint = endpoint.removeprefix("repos/" + m.REPO + "/")
            body = json.loads(kwargs["input"]) if kwargs.get("input") else None
            value, code = self.api(endpoint, method, body)
            if method != "GET" and method in self.uncertain:
                raise subprocess.TimeoutExpired(args, 300)
            data = b"" if code == 204 else json.dumps(value).encode()
            return self.result(args, f"HTTP/2.0 {code} Synthetic\r\nContent-Type: application/json\r\n\r\n".encode() + data, code=0 if code < 400 else 1)
        raise AssertionError("Unexpected external command: " + repr(args))

    def api(self, endpoint, method, body):
        endpoint = endpoint.split("?")[0]
        if method in self.before_write_failure:
            return {"message": "rejected"}, 503
        if endpoint == "":
            return {"full_name": m.REPO, "private": not self.repo_public, "visibility": "public" if self.repo_public else "private"}, 200
        if endpoint == "git/tags" and method == "POST":
            return {"sha": hashlib.sha256(json.dumps(body).encode()).hexdigest()[:40]}, 201
        if endpoint == "git/ref/tags/" + m.PUBLICATION_LOCK:
            if self.lock_sha is None:
                return {"message": "Not Found"}, 404
            return {"ref": "refs/tags/" + m.PUBLICATION_LOCK, "object": {"type": "tag", "sha": self.lock_sha}}, 200
        if endpoint == "git/refs/tags/" + m.PUBLICATION_LOCK and method == "DELETE":
            self.lock_sha = None
            return None, 204
        if endpoint.startswith("git/ref/tags/"):
            if self.tag_sha is None:
                return {"message": "Not Found"}, 404
            return {"ref": "refs/tags/" + self.tag, "object": {"type": "commit", "sha": self.tag_sha}}, 200
        if endpoint == "git/refs":
            if body["ref"] == "refs/tags/" + m.PUBLICATION_LOCK:
                if self.lock_sha is not None:
                    return {"message": "Reference already exists"}, 422
                self.lock_sha = body["sha"]
                return {}, 201
            self.tag_sha = body["sha"]
            return {}, 201
        if endpoint == "releases" and method == "GET":
            return [copy.deepcopy(self.release)] if self.release else [], 200
        if endpoint == "releases" and method == "POST":
            self.release = {**body, "id": 11, "published_at": None}
            return copy.deepcopy(self.release), 201
        if endpoint == "releases/11/assets":
            return [{"id": index, "name": name, "state": "uploaded", "size": len(data),
                     "digest": "sha256:" + hashlib.sha256(data).hexdigest()}
                    for index, (name, data) in enumerate(self.asset_data.items(), 1)], 200
        if endpoint == "releases/11" and method == "PATCH":
            self.release["draft"] = body["draft"]
            self.release["published_at"] = "2026-11-12T00:00:00Z"
            return copy.deepcopy(self.release), 200
        if endpoint == "releases/latest":
            latest = self.latest_release or (self.release if self.release and not self.release["draft"] else None)
            return copy.deepcopy(latest) if latest else {"message": "Not Found"}, 200 if latest else 404
        raise AssertionError((endpoint, method, body))

    def download(self, endpoint, output):
        self.downloads.append(endpoint)
        identifier = int(endpoint.rsplit("/", 1)[1])
        data = list(self.asset_data.values())[identifier - 1]
        Path(output).write_bytes(data + (b"wrong" if self.download_corrupt else b""))


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pichi-release-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        git(self.repo, "init", "-q")
        git(self.repo, "config", "user.name", "Synthetic")
        git(self.repo, "config", "user.email", "synthetic@example.invalid")
        git(self.repo, "config", "core.autocrlf", "false")
        git(self.repo, "remote", "add", "origin", "https://github.com/" + m.REPO + ".git")
        (self.repo / "LICENSE").write_text("Synthetic license fixture\n")
        (self.repo / "program").write_bytes(b"#!/bin/sh\nexit 0\n")
        (self.repo / "program").chmod(0o755)
        (self.repo / "link").symlink_to("program")
        (self.repo / "русский.txt").write_text("Synthetic Cyrillic path\n")
        # git archive would alter or omit these. The release helper must not.
        (self.repo / ".gitattributes").write_text("LICENSE export-ignore\nprogram export-subst\n")
        (self.repo / ".gitignore").write_text("private/\n")
        git(self.repo, "add", ".")
        git(self.repo, "commit", "-qm", "Synthetic source")
        self.revision = git(self.repo, "rev-parse", "HEAD").decode().strip()
        git(self.repo, "update-ref", "refs/remotes/origin/main", self.revision)
        (self.repo / "private").mkdir()
        (self.repo / "private/token").write_text("synthetic ignored sentinel")
        self.app = self.root / "Pichi Voice.app"
        (self.app / "Contents/Resources").mkdir(parents=True)
        (self.app / "Contents/MacOS").mkdir()
        (self.app / "Contents/MacOS/Pichi Voice").write_bytes(b"synthetic executable")
        (self.app / "Contents/MacOS/Pichi Voice").chmod(0o755)
        (self.app / "Contents/Resources/link").symlink_to("../MacOS/Pichi Voice")
        self.info = {"CFBundleIdentifier": m.BUNDLE, "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "71",
                     "AppSourceRevision": self.revision, "AppReleaseTag": "v0.1.0", "CFBundleExecutable": "Pichi Voice"}
        self.config = {"formatVersion": 1, "updatesEnabled": True, "expectedSigningTeam": m.TEAM,
                       "repository": "https://github.com/" + m.REPO}
        self.save_info()
        self.image = self.root / "frozen.dmg"
        self.image.write_bytes(b"synthetic dmg payload")
        self.args = argparse.Namespace(source=self.revision, version="0.1.0", build="71", tag=None, repo=str(self.repo),
                                       app=str(self.app), dmg=str(self.image), output=str(self.root / "output"), evidence=None)
        self.boundaries = Boundaries(self.app, self.revision)
        self.release = m.Release(self.args, self.boundaries)
        self.boundaries.tag = self.release.tag
        self.github = m.GitHub(self.release)
        self.output = Path(self.args.output)

    def save_info(self):
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(self.info))
        (self.app / "Contents/Resources/brand-distribution.json").write_bytes(json.dumps(self.config).encode())

    def prepared(self):
        self.release.prepare()
        return self.release.local(self.output)

    def evidence(self):
        self.args.evidence = str(self.root / "evidence.json")
        self.evidence_value = {"sourceRevision": self.revision, "manifestSHA256": m.digest(self.output / m.MANIFEST),
                               "verifiedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
                               "independentReview": "synthetic review", "tests": "synthetic tests",
                               "nativeAcceptance": "synthetic evidence; never native proof"}
        Path(self.args.evidence).write_text(json.dumps(self.evidence_value))

    def public(self, url, output, expected):
        if "/latest/download/" in url:
            name = m.ALIAS
        else:
            name = url.rsplit("/", 1)[1]
        data = self.boundaries.asset_data[name]
        self.assertEqual(expected, {"size": len(data), "sha256": hashlib.sha256(data).hexdigest()})
        if output:
            Path(output).write_bytes(data)

    def test_prepare_exact_source_alias_and_sanitized_manifest(self):
        expected = self.prepared()
        self.assertEqual(len(expected), 4)
        self.assertEqual([name for name in expected if name.endswith(".dmg")], ["Pichi-Voice.dmg"])
        self.assertEqual((self.output / m.ALIAS).read_bytes(), self.image.read_bytes())
        manifest = (self.output / m.MANIFEST).read_text()
        self.assertNotIn(str(self.root), manifest)
        self.assertNotIn("example.invalid", manifest)
        self.assertEqual(json.loads(manifest)["sourceRevision"], self.revision)
        with tarfile.open(self.output / self.release.source_name) as archive:
            self.assertEqual(archive.extractfile(self.release.prefix + "/LICENSE").read(), b"Synthetic license fixture\n")
            self.assertFalse(any("private/token" in entry.name for entry in archive))
            self.assertEqual(archive.getmember(self.release.prefix + "/program").mode, 0o755)
            self.assertTrue(archive.getmember(self.release.prefix + "/link").issym())
        second = self.root / "same.tar.gz"
        self.release.source.archive(second, self.release.prefix)
        self.assertEqual(second.read_bytes(), (self.output / self.release.source_name).read_bytes())
        self.assertFalse(self.boundaries.mounts)
        self.assertFalse(any("--clobber" in c for c in self.boundaries.calls))

    def test_no_overwrite_and_no_output_inside_app(self):
        self.prepared()
        before = (self.output / m.MANIFEST).read_bytes()
        with self.assertRaises(m.ReleaseError): self.release.prepare()
        self.assertEqual(before, (self.output / m.MANIFEST).read_bytes())
        self.args.output = str(self.app / "new")
        with self.assertRaises(m.ReleaseError): self.release.prepare()
        self.assertFalse((self.app / "new").exists())

    def test_output_parent_symlink_cannot_write_into_frozen_app(self):
        alias = self.root / "app-parent-alias"
        alias.symlink_to(self.app)
        self.args.output = str(alias / "new")
        with self.assertRaises(m.ReleaseError): self.release.prepare()
        self.assertFalse((self.app / "new").exists())

    def test_main_prepare_packages_via_existing_tool_and_dispatches_draft(self):
        base = ["--repo", str(self.repo), "--source", self.revision, "--version", "0.1.0", "--build", "71", "--app", str(self.app)]
        with patch.object(m, "Commands", return_value=self.boundaries), patch("builtins.print"):
            m.main(["prepare", *base, "--output", str(self.output)])
            m.main(["draft", *base, "--artifacts", str(self.output)])
            self.evidence()
            with patch.object(m, "public_download", side_effect=self.public):
                m.main(["publish", *base, "--artifacts", str(self.output), "--evidence", self.args.evidence])
                m.main(["verify", *base, "--artifacts", str(self.output)])
        self.assertTrue(any(Path(c[1]).name == "package-macos-dmg.py" for c in self.boundaries.calls if len(c) > 1))
        self.assertFalse(self.boundaries.release["draft"])

    def test_source_fail_closed_before_native_or_output(self):
        for field, value in (("source", "HEAD"), ("version", "0.1.0;touch /tmp/no"), ("build", "071"), ("tag", "v0.1.0+70-public.1")):
            with self.subTest(field=field):
                args = copy.copy(self.args)
                setattr(args, field, value)
                with self.assertRaises(m.ReleaseError): m.Release(args, self.boundaries)
        (self.repo / "untracked").write_text("keep")
        with self.assertRaises(m.ReleaseError): self.release.prepare()
        self.assertFalse(self.output.exists())
        (self.repo / "untracked").unlink()
        git(self.repo, "remote", "set-url", "origin", "https://github.com/altic-dev/FluidVoice.git")
        with self.assertRaises(m.ReleaseError): self.release.prepare()
        git(self.repo, "remote", "set-url", "origin", "https://github.com/" + m.REPO + ".git")
        git(self.repo, "update-ref", "-d", "refs/remotes/origin/main")
        with self.assertRaises(m.ReleaseError): self.release.prepare()
        self.assertFalse(self.output.exists())

    def test_wrong_frozen_identity_and_updater_policy_rejected(self):
        for field in ("CFBundleIdentifier", "CFBundleVersion", "CFBundleShortVersionString", "AppSourceRevision", "AppReleaseTag"):
            old = self.info[field]
            self.info[field] = "wrong"
            self.save_info()
            with self.subTest(field=field), self.assertRaises((m.ReleaseError, ValueError)):
                self.release.app(self.app)
            self.info[field] = old
        for field, bad in (("updatesEnabled", False), ("updatesEnabled", 1), ("expectedSigningTeam", "OTHER"), ("repository", "https://github.com/altic-dev/FluidVoice"), ("formatVersion", True)):
            old = self.config[field]
            self.config[field] = bad
            self.save_info()
            with self.subTest(field=field, bad=bad), self.assertRaises(m.ReleaseError): self.release.app(self.app)
            self.config[field] = old
        self.save_info()
        self.boundaries.native_failure = lambda args: args[:2] == ["xcrun", "stapler"]
        with self.assertRaises(m.ReleaseError): self.release.app(self.app)

    def test_mount_detaches_on_identity_hash_mode_symlink_and_root_mismatch(self):
        mutations = [lambda mount: (mount / "Pichi Voice.app/Contents/MacOS/Pichi Voice").write_bytes(b"changed"),
                     lambda mount: (mount / "Pichi Voice.app/Contents/MacOS/Pichi Voice").chmod(0o644),
                     lambda mount: (mount / "Pichi Voice.app/Contents/Resources/link").unlink(),
                     lambda mount: (mount / "private-log").write_text("private"),
                     lambda mount: (mount / "Applications").unlink()]
        for mutation in mutations:
            self.boundaries.mutate_payload = mutation
            with self.assertRaises(m.ReleaseError): self.release.verify_dmg(self.image, m.inventory(self.app))
            self.assertFalse(self.boundaries.mounts)
        for failure in ("error", "cancel", "malformed"):
            self.boundaries.mutate_payload = None
            self.boundaries.attach_failure = failure
            with self.assertRaises((m.ReleaseError, KeyboardInterrupt, plistlib.InvalidFileException)):
                self.release.verify_dmg(self.image, m.inventory(self.app))
            self.assertFalse(self.boundaries.mounts)
            mounts = [Path(c[c.index("-mountpoint") + 1]) for c in self.boundaries.calls if c[:2] == ["hdiutil", "attach"]]
            self.assertTrue(all(not p.parent.exists() for p in mounts))

    def test_container_metadata_cannot_hide_private_files_or_symlinks(self):
        def private_background(mount):
            (mount / ".background").mkdir()
            (mount / ".background/signing.log").write_text("private sentinel")
        def linked_background(mount):
            (mount / ".background").symlink_to(self.root)
        def private_trash(mount):
            (mount / ".Trashes").mkdir()
            (mount / ".Trashes/private").write_text("private sentinel")
        for mutate in (private_background, linked_background, private_trash):
            self.boundaries.mutate_payload = mutate
            with self.assertRaises(m.ReleaseError): self.release.verify_dmg(self.image, m.inventory(self.app))
            self.assertFalse(self.boundaries.mounts)
        def valid_metadata(mount):
            (mount / ".background.tiff").write_bytes(b"synthetic image")
            (mount / ".DS_Store").write_bytes(b"synthetic Finder metadata")
        self.boundaries.mutate_payload = valid_metadata
        self.release.verify_dmg(self.image, m.inventory(self.app))

    def test_detach_failure_preserves_owned_scratch_and_reports_mount(self):
        self.boundaries.detach_failure = True
        try:
            with self.assertRaisesRegex(m.ReleaseError, "Owned image detach failed at"):
                self.release.verify_dmg(self.image, m.inventory(self.app))
            self.assertEqual(len(self.boundaries.mounts), 1)
            mount = next(iter(self.boundaries.mounts))
            self.assertTrue(mount.exists())
        finally:
            # Fake mount only. Clean the deliberately retained synthetic resource.
            for mount in self.boundaries.mounts:
                shutil.rmtree(mount.parent)
            self.boundaries.mounts.clear()

    def test_symlinked_temp_parent_uses_canonical_owned_mount_identity(self):
        actual = self.root / "actual-temp"
        actual.mkdir()
        alias = self.root / "temp-alias"
        alias.symlink_to(actual, target_is_directory=True)
        scratch = actual / "owned-scratch"
        scratch.mkdir()
        make_temp = tempfile.mkdtemp
        def make_scratch(*args, **kwargs):
            if kwargs.get("prefix") == "pichi-release-mount-":
                return str(alias / scratch.name)
            return make_temp(*args, **kwargs)
        with patch.object(m.tempfile, "mkdtemp", side_effect=make_scratch):
            self.release.verify_dmg(self.image, m.inventory(self.app))
        attach = next(c for c in self.boundaries.calls if c[:2] == ["hdiutil", "attach"])
        self.assertEqual(attach[attach.index("-mountpoint") + 1], str(scratch.resolve() / "image"))
        self.assertFalse(self.boundaries.mounts)
        self.assertFalse(scratch.exists())

    def test_terminal_cancellation_during_detach_is_deferred_until_cleanup(self):
        previous = signal.getsignal(signal.SIGINT)
        def interrupt(args):
            if args[:2] == ["hdiutil", "detach"]:
                signal.raise_signal(signal.SIGINT)
            return False
        self.boundaries.native_failure = interrupt
        with self.assertRaises(KeyboardInterrupt):
            self.release.verify_dmg(self.image, m.inventory(self.app))
        self.assertFalse(self.boundaries.mounts)
        self.assertIs(signal.getsignal(signal.SIGINT), previous)
        attempts = [Path(c[c.index("-mountpoint") + 1]) for c in self.boundaries.calls if c[:2] == ["hdiutil", "attach"]]
        self.assertTrue(all(not mount.parent.exists() for mount in attempts))

    def test_detach_failure_after_no_mount_is_confirmed_and_cleaned(self):
        self.boundaries.detach_failure = True
        self.boundaries.native_failure = lambda args: args[:2] == ["hdiutil", "attach"]
        with self.assertRaises(m.ReleaseError): self.release.verify_dmg(self.image, m.inventory(self.app))
        attempts = [Path(c[c.index("-mountpoint") + 1]) for c in self.boundaries.calls if c[:2] == ["hdiutil", "attach"]]
        self.assertTrue(all(not mount.parent.exists() for mount in attempts))

    def test_signature_identity_team_runtime_and_architecture_fail_closed(self):
        for old, new in ((b"ai.pichi.voice", b"other.bundle"), (b"LU46F7HGJM", b"OTHERTEAM0"),
                         (b"Developer ID Application:", b"Apple Development:"), (b"Timestamp=", b"NoTime="),
                         (b"runtime", b"none")):
            self.boundaries.signature_transform = lambda value: value.replace(old, new)
            with self.subTest(old=old), self.assertRaises((m.ReleaseError, ValueError)): self.release.app(self.app)
        self.boundaries.signature_transform = lambda value: value
        self.boundaries.architecture = b"x86_64 arm64\n"
        with self.assertRaises(m.ReleaseError): self.release.app(self.app)

    def test_dmg_verify_failure_never_attaches(self):
        self.boundaries.native_failure = lambda args: args[:2] == ["hdiutil", "verify"]
        with self.assertRaises(m.ReleaseError): self.release.verify_dmg(self.image, m.inventory(self.app))
        self.assertFalse(any(c[:2] == ["hdiutil", "attach"] for c in self.boundaries.calls))

    def test_local_rejects_tampered_alias_manifest_checksum_extra_and_symlink(self):
        self.prepared()
        for name in (m.ALIAS, m.MANIFEST, m.CHECKSUMS):
            path = self.output / name
            original = path.read_bytes()
            path.write_bytes(original + b"changed")
            with self.subTest(name=name), self.assertRaises(m.ReleaseError): self.release.local(self.output)
            path.write_bytes(original)
        (self.output / "private.log").write_text("private")
        with self.assertRaises(m.ReleaseError): self.release.local(self.output)
        (self.output / "private.log").unlink()
        (self.output / m.ALIAS).unlink()
        (self.output / m.ALIAS).symlink_to(self.image)
        with self.assertRaises(m.ReleaseError): self.release.local(self.output)

    def rewrite_archive(self, transform):
        path = self.output / self.release.source_name
        with tarfile.open(path) as archive:
            entries = [(copy.copy(member), archive.extractfile(member).read() if member.isfile() else None) for member in archive]
        entries = transform(entries)
        with tarfile.open(path, "w:gz") as archive:
            for member, data in entries:
                if data is not None:
                    member.size = len(data)
                archive.addfile(member, io.BytesIO(data) if data is not None else None)
        with self.assertRaises(m.ReleaseError): self.release.source.verify_archive(path, self.release.prefix)

    def test_source_archive_rejects_blob_mode_path_missing_duplicate_and_metadata_mismatch(self):
        self.prepared()
        archive = self.output / self.release.source_name
        original = archive.read_bytes()
        def changed_field(field, value):
            def change(entries):
                setattr(entries[0][0], field, value)
                return entries
            return change
        changes = [lambda entries: entries + [entries[0]], lambda entries: entries[1:],
                   lambda entries: [(entries[0][0], b"changed"), *entries[1:]],
                   changed_field("name", "../../private"), changed_field("mode", 0o777),
                   changed_field("uid", 501), changed_field("uname", "private email"),
                   changed_field("mtime", 0)]
        for change in changes:
            archive.write_bytes(original)
            self.rewrite_archive(change)

    def test_full_draft_retry_publish_and_anonymous_verify_contract(self):
        expected = self.prepared()
        self.boundaries.uncertain = {"POST", "upload", "PATCH"}
        self.github.draft(self.output, expected)
        writes = len([c for c in self.boundaries.calls if c[:3] == ["gh", "release", "upload"]])
        self.github.draft(self.output, expected)
        self.assertEqual(writes, len([c for c in self.boundaries.calls if c[:3] == ["gh", "release", "upload"]]))
        self.assertEqual(writes, 4)
        self.evidence()
        self.boundaries.uncertain.discard("POST")
        with patch.object(m, "public_download", side_effect=self.public) as public:
            self.github.publish(self.output, expected)
            self.assertEqual(public.call_count, 5)  # Four assets plus the website latest URL.
            urls = [call.args[0] for call in public.call_args_list]
            self.assertTrue(any("/releases/download/" in url and url.endswith("/Pichi-Voice.dmg") for url in urls))
            self.assertIn("https://github.com/Pichi-AI/pichi-voice/releases/latest/download/Pichi-Voice.dmg", urls)
        self.assertFalse(self.boundaries.release["draft"])
        for operation in (lambda: self.github.draft(self.output, expected), lambda: self.github.publish(self.output, expected)):
            before = len(self.boundaries.calls)
            with self.assertRaises(m.ReleaseError): operation()
            self.assertFalse(any("--method" in c and c[c.index("--method") + 1] in ("POST", "PATCH")
                                 or c[:3] == ["gh", "release", "upload"] for c in self.boundaries.calls[before:]))
        self.assertEqual(self.boundaries.tag_sha, self.revision)

    def test_publication_lock_prevents_another_owner_and_is_released_after_failure(self):
        with self.github.publication_lock():
            owner = self.boundaries.lock_sha
            self.assertIsNotNone(owner)
            with self.assertRaises(m.ReleaseError):
                with self.github.publication_lock():
                    self.fail("A second publisher acquired an active lock")
            self.assertEqual(self.boundaries.lock_sha, owner)
        self.assertIsNone(self.boundaries.lock_sha)
        with self.assertRaisesRegex(RuntimeError, "failure"):
            with self.github.publication_lock():
                raise RuntimeError("failure")
        self.assertIsNone(self.boundaries.lock_sha)

    def test_publication_lock_blocks_a_publisher_after_final_latest_check(self):
        expected = self.prepared()
        self.github.draft(self.output, expected)
        self.evidence()
        original = self.github.require_newer_stable_release
        checks = []
        def check_then_attempt_concurrent_publish():
            original()
            checks.append(True)
            if len(checks) == 2:
                with self.assertRaises(m.ReleaseError):
                    with self.github.publication_lock():
                        self.fail("The competing release must wait for this publication")
        with patch.object(self.github, "require_newer_stable_release", side_effect=check_then_attempt_concurrent_publish), patch.object(m, "public_download", side_effect=self.public):
            self.github.publish(self.output, expected)
        self.assertFalse(self.boundaries.release["draft"])
        self.assertIsNone(self.boundaries.lock_sha)

    def test_wrong_tag_and_private_repository_never_mutated(self):
        expected = self.prepared()
        self.boundaries.tag_sha = "a" * 40
        with self.assertRaises(m.ReleaseError): self.github.draft(self.output, expected)
        self.assertIsNone(self.boundaries.release)
        self.boundaries.tag_sha = None
        self.boundaries.repo_public = False
        with self.assertRaises(m.ReleaseError): self.github.draft(self.output, expected)
        self.assertIsNone(self.boundaries.tag_sha)

    def test_publication_refuses_equal_older_or_unrecognized_latest_identity(self):
        expected = self.prepared()
        self.github.draft(self.output, expected)
        self.evidence()
        for tag in (self.release.tag, "v0.1.0+72-public.1", "v0.2.0+1-public.1", "runtime-assets"):
            self.boundaries.latest_release = {"draft": False, "prerelease": False, "tag_name": tag}
            before = len(self.boundaries.calls)
            with self.subTest(tag=tag), self.assertRaises(m.ReleaseError):
                self.github.publish(self.output, expected)
            self.assertTrue(self.boundaries.release["draft"])
            self.assertFalse(any("PATCH" in call for call in self.boundaries.calls[before:]))

    def test_latest_release_is_rechecked_immediately_before_publication(self):
        expected = self.prepared()
        self.github.draft(self.output, expected)
        self.evidence()
        original = self.github.assets
        def verification_with_concurrent_release(*args, **kwargs):
            result = original(*args, **kwargs)
            self.boundaries.latest_release = {"draft": False, "prerelease": False, "tag_name": "v0.1.0+72-public.1"}
            return result
        with patch.object(self.github, "assets", side_effect=verification_with_concurrent_release), self.assertRaises(m.ReleaseError):
            self.github.publish(self.output, expected)
        self.assertTrue(self.boundaries.release["draft"])

    def test_publication_advances_an_existing_older_stable_release(self):
        self.boundaries.latest_release = {"draft": False, "prerelease": False, "tag_name": "v0.0.9+999-public.1"}
        self.github.require_newer_stable_release()

    def test_public_version_tags_and_one_explicit_legacy_bridge(self):
        self.assertEqual(self.release.tag, "v0.1.0")
        args = copy.copy(self.args)
        args.tag = "v0.1.0+71-public.1"
        self.assertEqual(m.Release(args, self.boundaries).tag, args.tag)
        for previous in ["v0.1.0", "v0.1.0+69-public.1", "v0.1.1", "v0.2.0"]:
            self.boundaries.latest_release = {"draft": False, "prerelease": False, "tag_name": previous}
            with self.subTest(previous=previous), self.assertRaises(m.ReleaseError):
                self.github.require_newer_stable_release()
        self.boundaries.latest_release = {"draft": False, "prerelease": False, "tag_name": "v0.0.9"}
        self.github.require_newer_stable_release()

    def test_release_title_uses_only_the_public_version(self):
        expected = self.prepared()
        self.github.draft(self.output, expected)
        self.assertEqual(self.boundaries.release["name"], "Pichi Voice 0.1.0")

    def test_normal_tags_require_signed_tag_metadata_and_legacy_bundles_remain_verifiable(self):
        self.info.pop("AppReleaseTag")
        self.save_info()
        with self.assertRaises(m.ReleaseError): self.release.app(self.app)
        args = copy.copy(self.args)
        args.tag = "v0.1.0+71-public.1"
        legacy = m.Release(args, self.boundaries)
        legacy.app(self.app)
        self.info["AppReleaseTag"] = args.tag
        self.save_info()
        legacy.app(self.app)
        self.info["AppReleaseTag"] = "v0.1.1"
        self.save_info()
        with self.assertRaises(m.ReleaseError): legacy.app(self.app)

    def test_uncertain_failed_write_reread_without_blind_retry(self):
        expected = self.prepared()
        self.boundaries.before_write_failure = {"POST"}
        with self.assertRaises(m.ReleaseError): self.github.draft(self.output, expected)
        mutations = [c for c in self.boundaries.calls if "--method" in c and c[c.index("--method") + 1] == "POST"]
        self.assertEqual(len(mutations), 1)
        self.assertIsNone(self.boundaries.release)
        self.assertIsNone(self.boundaries.tag_sha)

    def test_cancelled_write_is_reconciled_then_stops(self):
        state = []
        def mutation():
            state.append("write")
            raise KeyboardInterrupt
        def read():
            state.append("read")
            return True
        with self.assertRaises(KeyboardInterrupt): self.github.reconcile(mutation, read, bool)
        self.assertEqual(state, ["write", "read"])

    def test_wrong_asset_status_digest_or_release_schema_never_admitted(self):
        expected = self.prepared()
        self.github.draft(self.output, expected)
        original = self.boundaries.api
        for field, bad in (("state", "starter"), ("digest", None), ("digest", "sha256:bad"),
                           ("size", True), ("id", "1"), ("name", "private.log")):
            def changed(endpoint, method, body):
                value, code = original(endpoint, method, body)
                if endpoint.startswith("releases/11/assets"):
                    value[0][field] = bad
                return value, code
            with self.subTest(field=field), patch.object(self.boundaries, "api", side_effect=changed), self.assertRaises(m.ReleaseError):
                self.github.assets(self.boundaries.release, expected, complete=True)
        for field, bad in (("draft", None), ("prerelease", True), ("id", True), ("target_commitish", "main")):
            old = self.boundaries.release[field]
            self.boundaries.release[field] = bad
            with self.subTest(field=field), self.assertRaises(m.ReleaseError): self.github.find()
            self.boundaries.release[field] = old

    def test_existing_wrong_asset_is_never_clobbered(self):
        expected = self.prepared()
        self.github.draft(self.output, expected)
        self.boundaries.asset_data[m.ALIAS] += b"changed"
        with self.assertRaises(m.ReleaseError): self.github.draft(self.output, expected)
        self.assertFalse(any("--clobber" in c for c in self.boundaries.calls))
        self.evidence()
        with self.assertRaises(m.ReleaseError): self.github.publish(self.output, expected)
        self.assertTrue(self.boundaries.release["draft"])

    def test_downloaded_draft_bytes_must_match_before_publish(self):
        expected = self.prepared()
        self.github.draft(self.output, expected)
        self.evidence()
        self.boundaries.download_corrupt = True
        with self.assertRaises(m.ReleaseError): self.github.publish(self.output, expected)
        self.assertTrue(self.boundaries.release["draft"])

    def test_missing_asset_retry_uploads_only_missing_verified_asset(self):
        expected = self.prepared()
        self.boundaries.before_write_failure = {m.ALIAS}
        with self.assertRaises(m.ReleaseError): self.github.draft(self.output, expected)
        self.assertEqual(set(self.boundaries.asset_data), set())
        self.boundaries.before_write_failure = set()
        self.github.draft(self.output, expected)
        self.assertEqual(set(self.boundaries.asset_data), set(expected))

    def test_annotated_tag_peels_exactly_and_cycles_are_rejected(self):
        original = self.boundaries.api
        tag_sha = "a" * 40
        def annotated(endpoint, method, body):
            if endpoint.startswith("git/ref/tags/"):
                return {"ref": "refs/tags/" + self.release.tag, "object": {"type": "tag", "sha": tag_sha}}, 200
            if endpoint == "git/tags/" + tag_sha:
                return {"sha": tag_sha, "object": {"type": "commit", "sha": self.revision}}, 200
            return original(endpoint, method, body)
        with patch.object(self.boundaries, "api", side_effect=annotated):
            self.assertTrue(self.github.tag())
        def cyclic(endpoint, method, body):
            value, status = annotated(endpoint, method, body)
            if endpoint == "git/tags/" + tag_sha:
                value["object"] = {"type": "tag", "sha": tag_sha}
            return value, status
        with patch.object(self.boundaries, "api", side_effect=cyclic), self.assertRaises(m.ReleaseError): self.github.tag()

    def test_paginated_lists_are_complete_and_duplicate_assets_fail_closed(self):
        expected = self.prepared()
        self.github.draft(self.output, expected)
        with patch.object(self.github, "api", side_effect=[list(range(100)), [100]]) as api:
            self.assertEqual(len(list(self.github.pages("releases"))), 101)
            self.assertIn("page=2", api.call_args_list[1].args[0])
        actual, _ = self.boundaries.api("releases/11/assets", "GET", None)
        with patch.object(self.github, "pages", return_value=iter([actual[0], actual[0]])), self.assertRaises(m.ReleaseError):
            self.github.assets(self.boundaries.release, expected, complete=False)

    def test_malformed_http_and_json_never_interpreted_as_missing_release(self):
        for raw in (b"{}", b"HTTP/2.0 200 OK\n\n{", b'HTTP/2.0 200 OK\n\n{"x":1,"x":2}',
                    b'HTTP/2.0 403 Forbidden\n\n{}', b'HTTP/2.0 200 OK\n\n{"x":NaN}'):
            self.boundaries.raw_response = raw
            with self.subTest(raw=raw), self.assertRaises(m.ReleaseError): self.github.repository()

    def test_evidence_binds_candidate_and_requires_current_context(self):
        self.prepared()
        self.evidence()
        m.validate_evidence(self.args.evidence, self.revision, m.digest(self.output / m.MANIFEST))
        for field, bad in (("sourceRevision", "a" * 40), ("manifestSHA256", "b" * 64),
                           ("verifiedAt", "2000-01-01T00:00:00Z"), ("verifiedAt", "2099-01-01T00:00:00Z"),
                           ("verifiedAt", "2026-11-11"), ("independentReview", ""), ("tests", None), ("nativeAcceptance", " ")):
            value = {**self.evidence_value, field: bad}
            Path(self.args.evidence).write_text(json.dumps(value))
            with self.subTest(field=field, bad=bad), self.assertRaises(m.ReleaseError):
                m.validate_evidence(self.args.evidence, self.revision, m.digest(self.output / m.MANIFEST))

    def test_source_archive_trailing_bytes_and_gzip_metadata_rejected(self):
        self.prepared()
        archive = self.output / self.release.source_name
        original = archive.read_bytes()
        for data in (original + b"private trailing log", original[:4] + b"\x01\x00\x00\x00" + original[8:]):
            archive.write_bytes(data)
            with self.assertRaises(m.ReleaseError): self.release.source.verify_archive(archive, self.release.prefix)

    def test_unmerged_source_and_missing_license_or_submodule_rejected(self):
        before = self.revision
        (self.repo / "new-source").write_text("new source")
        git(self.repo, "add", ".")
        git(self.repo, "commit", "-qm", "Not on origin main")
        new = git(self.repo, "rev-parse", "HEAD").decode().strip()
        self.release.source.revision = new
        with self.assertRaises(m.ReleaseError): self.release.source.validate()
        self.release.source.revision = before
        with self.assertRaises(m.ReleaseError): self.release.source.validate()  # HEAD mismatch
        (self.repo / "LICENSE").unlink()
        git(self.repo, "add", "-u")
        git(self.repo, "commit", "-qm", "Missing license")
        self.release.source.revision = git(self.repo, "rev-parse", "HEAD").decode().strip()
        with self.assertRaises(m.ReleaseError): self.release.source.entries()
        git(self.repo, "update-index", "--add", "--cacheinfo", "160000," + before + ",nested")
        git(self.repo, "commit", "-qm", "Unvendored submodule")
        self.release.source.revision = git(self.repo, "rev-parse", "HEAD").decode().strip()
        with self.assertRaises(m.ReleaseError): self.release.source.entries()

    def test_plan_and_help_are_real_safe_invocations(self):
        script = str(ROOT / "scripts/dev/macos-release.py")
        for arguments in (["--help"], ["plan", "--source", self.revision, "--version", "0.1.0", "--build", "71"]):
            result = subprocess.run(["python3", "-B", "-S", script, *arguments], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["tag"], self.release.tag)
        self.assertFalse(self.output.exists())


class PublicDownloadTests(unittest.TestCase):
    def test_https_redirect_scope(self):
        for url in ("http://github.com/file", "https://evil.example/file", "https://github.com.evil.example/file",
                    "https://user:secret@github.com/file", "https://github.com:444/file"):
            with self.subTest(url=url), self.assertRaises(m.ReleaseError): m.validate_download_url(url)
        m.validate_download_url("https://release-assets.githubusercontent.com/path?signature=ephemeral")

    def test_entire_anonymous_body_status_size_and_digest(self):
        data = b"complete public payload"
        expected = {"size": len(data), "sha256": hashlib.sha256(data).hexdigest()}
        class Response(io.BytesIO):
            status = 200
            def geturl(self): return "https://release-assets.githubusercontent.com/asset"
        class Opener:
            def open(self, request, **kwargs):
                self.request = request
                return Response(data)
        opener = Opener()
        with patch.object(m, "build_opener", return_value=opener):
            m.public_download("https://github.com/public", None, expected)
            self.assertNotIn("Authorization", opener.request.headers)
            for bad in ({**expected, "size": len(data) - 1}, {**expected, "sha256": "a" * 64}):
                with self.assertRaises(m.ReleaseError): m.public_download("https://github.com/public", None, bad)
            Response.status = 206
            with self.assertRaises(m.ReleaseError): m.public_download("https://github.com/public", None, expected)


if __name__ == "__main__":
    unittest.main()
