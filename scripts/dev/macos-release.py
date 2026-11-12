#!/usr/bin/env python3
"""Manually prepare, draft, publish and verify a frozen macOS DMG release.

No builds, signing, installation or automatic publication. Python standard library;
prepare without --dmg also needs the existing dmgbuild/Pillow packaging environment.
"""
import argparse
from contextlib import contextmanager
import datetime as dt
import gzip
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import uuid
from urllib.parse import quote, urlsplit
from urllib.request import HTTPSHandler, HTTPRedirectHandler, Request, build_opener

REPO = "Pichi-AI/pichi-voice"
TEAM = "LU46F7HGJM"
BUNDLE = "ai.pichi.voice"
ALIAS = "Pichi-Voice.dmg"
MANIFEST = "release-manifest.json"
CHECKSUMS = "SHA256SUMS"
PUBLICATION_LOCK = "pichi-macos-publication-lock"
SHA = re.compile(r"[0-9a-f]{40}")


class ReleaseError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise ReleaseError(message)


def json_bytes(value):
    return (json.dumps(value, sort_keys=True, indent=2, ensure_ascii=True) + "\n").encode()


def parse_json(data):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, "Duplicate JSON key")
            result[key] = value
        return result
    try:
        return json.loads(data, object_pairs_hook=unique,
                          parse_constant=lambda _: (_ for _ in ()).throw(ReleaseError("Invalid JSON constant")))
    except (ValueError, UnicodeError) as error:
        raise ReleaseError("Malformed JSON") from error


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def regular(path):
    require(Path(path).is_file() and not Path(path).is_symlink(), "Expected a regular artifact file")


class Commands:
    def run(self, args, *, cwd=None, input=None, check=True, capture_output=True, text=False):
        result = subprocess.run(args, cwd=cwd, input=input, capture_output=capture_output, text=text,
                                timeout=300, start_new_session=True)
        if check:
            require(result.returncode == 0, f"Command failed: {args[0]} {args[1]} (details remain private)")
        return result

    def download(self, endpoint, output):
        with Path(output).open("xb") as stream:
            result = subprocess.run(["gh", "api", "--hostname", "github.com", endpoint,
                                     "-H", "Accept: application/octet-stream"],
                                    stdout=stream, stderr=subprocess.PIPE, timeout=600)
        require(result.returncode == 0, "Authenticated asset download failed")


@contextmanager
def defer_cancellation():
    """Finish owned cleanup before observing terminal cancellation."""
    pending = []
    previous = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM)}
    for sig in previous:
        signal.signal(sig, lambda number, _frame: pending.append(number))
    try:
        yield
    finally:
        active_error = sys.exc_info()[0] is not None
        for sig, handler in previous.items():
            signal.signal(sig, handler)
        if pending and not active_error:
            raise KeyboardInterrupt


class Source:
    def __init__(self, root, revision, commands):
        self.root, self.revision, self.commands = Path(root).resolve(), revision, commands

    def git(self, *args):
        return self.commands.run(["git", *args], cwd=self.root).stdout

    def clean(self):
        require(SHA.fullmatch(self.revision), "Source must be a full lowercase commit SHA")
        remote = self.git("remote", "get-url", "origin").decode().strip()
        require(remote in (f"https://github.com/{REPO}", f"https://github.com/{REPO}.git",
                           f"git@github.com:{REPO}.git"), "Wrong origin repository")
        require(not self.git("status", "--porcelain=v1", "--untracked-files=all"), "Source tree must be clean")
        require(self.git("rev-parse", "HEAD").decode().strip() == self.revision, "HEAD differs from pinned source")

    def validate(self):
        self.clean()
        self.git("fetch", "--no-tags", "origin", "refs/heads/main:refs/remotes/origin/main")
        self.git("merge-base", "--is-ancestor", self.revision, "refs/remotes/origin/main")

    def entries(self):
        entries = {}
        for record in self.git("ls-tree", "-rz", "--full-tree", self.revision).split(b"\0"):
            if not record:
                continue
            header, raw_path = record.split(b"\t", 1)
            mode, kind, oid = header.decode("ascii").split()
            path = raw_path.decode("utf-8")
            parts = PurePosixPath(path).parts
            require(parts and not path.startswith("/") and ".." not in parts and
                    "\\" not in path and not any(ord(c) < 32 for c in path), "Unsafe tracked source path")
            require(kind == "blob" and mode in ("100644", "100755", "120000"),
                    "Only tracked blobs are supported; vendor submodules before release")
            entries[path] = (mode, oid)
        require("LICENSE" in entries, "Corresponding source must retain LICENSE")
        return entries

    @contextmanager
    def blobs(self):
        # One request at a time bounds memory to one tracked file and avoids pipe deadlock.
        process = subprocess.Popen(["git", "cat-file", "--batch"], cwd=self.root,
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        def read(oid):
            process.stdin.write((oid + "\n").encode())
            process.stdin.flush()
            header = process.stdout.readline().decode().strip().split()
            require(len(header) == 3 and header[:2] == [oid, "blob"], "Invalid Git blob response")
            size = int(header[2])
            data = process.stdout.read(size)
            require(len(data) == size and process.stdout.read(1) == b"\n", "Truncated Git blob")
            return data
        try:
            yield read
        finally:
            process.stdin.close()
            process.stdout.close()
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=10)

    def archive(self, output, prefix):
        timestamp = int(self.git("show", "-s", "--format=%ct", self.revision))
        with Path(output).open("xb") as raw, gzip.GzipFile(fileobj=raw, filename="", mode="wb", mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w|", format=tarfile.PAX_FORMAT) as archive, self.blobs() as blob:
                for path, (mode, oid) in sorted(self.entries().items()):
                    data = blob(oid)
                    member = tarfile.TarInfo(prefix + "/" + path)
                    member.mtime = timestamp
                    member.mode = {"100644": 0o644, "100755": 0o755, "120000": 0o777}[mode]
                    if mode == "120000":
                        member.type, member.linkname = tarfile.SYMTYPE, data.decode("utf-8")
                        archive.addfile(member)
                    else:
                        member.size = len(data)
                        archive.addfile(member, io.BytesIO(data))

    def verify_archive(self, path, prefix):
        expected = self.entries()
        seen = set()
        timestamp = int(self.git("show", "-s", "--format=%ct", self.revision))
        with tarfile.open(path, "r|gz") as archive:
            for member in archive:
                require(member.name.startswith(prefix + "/"), "Wrong source archive prefix")
                name = member.name[len(prefix) + 1:]
                require(name in expected and name not in seen, "Extra, duplicate or missing source blob")
                seen.add(name)
                mode, oid = expected[name]
                require(member.uid == member.gid == 0 and not member.uname and not member.gname and
                        member.mtime == timestamp and set(member.pax_headers) <= {"path", "linkpath"},
                        "Source archive contains unexpected metadata")
                require(member.mode == {"100644": 0o644, "100755": 0o755, "120000": 0o777}[mode],
                        "Source archive mode mismatch")
                if mode == "120000":
                    require(member.issym() and member.size == 0, "Source symlink mismatch")
                    data = member.linkname.encode("utf-8")
                    actual = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
                else:
                    require(member.isfile() and not member.linkname, "Source blob type mismatch")
                    actual_hash = hashlib.sha1(b"blob " + str(member.size).encode() + b"\0")
                    with archive.extractfile(member) as stream:
                        while chunk := stream.read(1024 * 1024):
                            actual_hash.update(chunk)
                    actual = actual_hash.hexdigest()
                require(actual == oid, "Source archive blob digest mismatch")
        require(seen == set(expected), "Missing source archive entries")
        # Reject trailing members/data, gzip comments and metadata that tar readers
        # otherwise ignore. Public source bytes must be exactly our canonical form.
        with tempfile.TemporaryDirectory(prefix="pichi-release-source-") as directory:
            canonical = Path(directory) / "source.tar.gz"
            self.archive(canonical, prefix)
            require(Path(path).stat().st_size == canonical.stat().st_size and digest(path) == digest(canonical),
                    "Source archive is not the exact canonical tracked-blob archive")


def inventory(app):
    result = {}
    def visit(path, name):
        mode = path.lstat().st_mode
        entry = {"mode": stat.S_IMODE(mode)}
        if stat.S_ISLNK(mode):
            entry.update(type="symlink", target=os.readlink(path))
        elif stat.S_ISDIR(mode):
            entry.update(type="directory")
            for child in sorted(path.iterdir()):
                visit(child, name + "/" + child.name if name else child.name)
        else:
            require(stat.S_ISREG(mode), "Unsupported file in application payload")
            entry.update(type="file", size=path.stat().st_size, sha256=digest(path))
        result[name] = entry
    visit(Path(app), "")
    return result


class Release:
    def __init__(self, args, commands=None):
        self.args, self.commands = args, commands or Commands()
        require(SHA.fullmatch(args.source), "Source must be a full lowercase SHA")
        require(re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", args.version), "Invalid version")
        require(re.fullmatch(r"[1-9][0-9]*", args.build), "Invalid build")
        self.tag = args.tag or f"v{args.version}+{args.build}-public.1"
        require(re.fullmatch(re.escape(f"v{args.version}+{args.build}-public.") + r"[1-9][0-9]*", self.tag), "Tag identity mismatch")
        self.source = Source(args.repo, args.source, self.commands)
        self.prefix = f"Pichi-Voice-{args.version}-{args.build}-source"
        self.dmg_name = ALIAS
        self.source_name = self.prefix + ".tar.gz"
        self.names = [self.dmg_name, self.source_name]

    def app(self, app):
        spec = importlib.util.spec_from_file_location("pichi_dmg_packaging", Path(__file__).with_name("package-macos-dmg.py"))
        packager = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(packager)
        # Reuse the owning trust validator with the same deterministic command seam.
        packager.subprocess = self.commands
        with tempfile.TemporaryDirectory(prefix="pichi-release-validation-") as directory:
            _, _, info = packager.validate_input(app, Path(directory) / "unused.dmg", TEAM)
        require(info.get("CFBundleIdentifier") == BUNDLE and
                info.get("CFBundleShortVersionString") == self.args.version and
                info.get("CFBundleVersion") == self.args.build and
                info.get("AppSourceRevision") == self.args.source, "Frozen app identity/version/build/source mismatch")
        signature = self.commands.run(["codesign", "-dvvv", str(app)], text=True).stderr
        require(f"Identifier={BUNDLE}\n" in signature, "Code signing identifier mismatch")
        config = parse_json((app / "Contents/Resources/brand-distribution.json").read_bytes())
        require(isinstance(config, dict) and type(config.get("formatVersion")) is int and config["formatVersion"] == 1 and
                config.get("updatesEnabled") is True and config.get("expectedSigningTeam") == TEAM and
                config.get("repository") == f"https://github.com/{REPO}", "Signed updater configuration mismatch")
        executable = info.get("CFBundleExecutable")
        require(isinstance(executable, str) and executable and "/" not in executable and executable not in (".", ".."), "Invalid executable")
        archs = self.commands.run(["lipo", "-archs", str(app / "Contents/MacOS" / executable)]).stdout.decode().split()
        require(archs == ["arm64"], "Expected arm64-only app")
        return inventory(app)

    @contextmanager
    def mounted(self, image):
        # macOS reports canonical /private/var paths even when TMPDIR uses /var.
        # Use that same identity for attach, verification and cleanup.
        root = Path(tempfile.mkdtemp(prefix="pichi-release-mount-")).resolve()
        mount = root / "image"
        mount.mkdir()
        attempted = False
        try:
            attempted = True
            result = self.commands.run(["hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen",
                                        "-mountpoint", str(mount), "-plist", str(image)])
            value = plistlib.loads(result.stdout)
            require(any(e.get("mount-point") == str(mount) for e in value.get("system-entities", [])), "Missing owned mount")
            yield mount
        finally:
            # Detach our unique mountpoint even if attach failed after mounting or
            # returned malformed output. A failed detach is safe only when native
            # state independently confirms that this mountpoint is absent.
            with defer_cancellation():
                if attempted:
                    result = self.commands.run(["hdiutil", "detach", str(mount)], check=False)
                    if result.returncode:
                        info = plistlib.loads(self.commands.run(["hdiutil", "info", "-plist"]).stdout)
                        require(isinstance(info, dict) and isinstance(info.get("images"), list),
                                f"Cannot determine owned mount state at {mount}; preserve scratch")
                        require(not any(e.get("mount-point") == str(mount) for image_info in info["images"]
                                        for e in image_info.get("system-entities", [])),
                                f"Owned image detach failed at {mount}; preserve scratch and detach manually")
                shutil.rmtree(root)

    def verify_dmg(self, image, frozen):
        regular(image)
        self.commands.run(["hdiutil", "verify", str(image)])
        with self.mounted(image) as mount:
            require((mount / "Applications").is_symlink() and os.readlink(mount / "Applications") == "/Applications", "Invalid Applications link")
            require(set(p.name for p in mount.iterdir()) <= {
                "Pichi Voice.app", "Applications", ".DS_Store", ".background.png", ".background.tiff", ".VolumeIcon.icns", ".fseventsd", ".Trashes"}, "Unexpected DMG root payload")
            # Container metadata has a narrow shape too: a reused DMG must not
            # smuggle extra files beneath Finder's hidden metadata directories.
            for name in (".DS_Store", ".VolumeIcon.icns", ".background.png", ".background.tiff"):
                if (mount / name).exists() or (mount / name).is_symlink():
                    regular(mount / name)
            for name, allowed in ((".fseventsd", {"no_log", "fseventsd-uuid"}), (".Trashes", set())):
                directory = mount / name
                if directory.exists() or directory.is_symlink():
                    require(directory.is_dir() and not directory.is_symlink(), "Unexpected DMG metadata link")
                    for child in directory.iterdir():
                        require(child.name in allowed, "Unexpected file beneath DMG metadata")
                        regular(child)
            require(self.app(mount / "Pichi Voice.app") == frozen, "Mounted app differs from frozen payload")

    def metadata(self, directory, frozen):
        return {"schemaVersion": 1, "repository": REPO, "tag": self.tag,
                "sourceRevision": self.args.source, "version": self.args.version, "build": self.args.build,
                "bundleIdentifier": BUNDLE, "signingTeam": TEAM, "architecture": "arm64",
                "appPayloadSHA256": hashlib.sha256(json_bytes(frozen)).hexdigest(),
                "files": {name: {"size": (directory / name).stat().st_size, "sha256": digest(directory / name)}
                          for name in self.names}}

    def checksums(self, directory):
        return "".join(f"{digest(directory / name)}  {name}\n" for name in sorted([*self.names, MANIFEST])).encode()

    def prepare(self):
        self.source.validate()
        app = Path(self.args.app).absolute()
        frozen = self.app(app)
        output = Path(self.args.output).absolute()
        require(not output.exists() and not output.is_symlink() and not output.resolve().is_relative_to(app.resolve()), "Output must be new and outside app")
        output.mkdir()  # A failed attempt is retained for inspection; never overwritten or uploaded.
        image = output / self.dmg_name
        if self.args.dmg:
            regular(self.args.dmg)
            with Path(self.args.dmg).open("rb") as src, image.open("xb") as dest:
                shutil.copyfileobj(src, dest)
        else:
            self.commands.run([sys.executable, str(Path(__file__).with_name("package-macos-dmg.py")),
                               "--app", str(app), "--output", str(image)])
        self.verify_dmg(image, frozen)
        require(self.app(app) == frozen, "Frozen input changed during packaging")
        self.source.archive(output / self.source_name, self.prefix)
        self.source.verify_archive(output / self.source_name, self.prefix)
        self.source.clean()
        with (output / MANIFEST).open("xb") as stream:
            stream.write(json_bytes(self.metadata(output, frozen)))
        with (output / CHECKSUMS).open("xb") as stream:
            stream.write(self.checksums(output))

    def local(self, directory):
        directory = Path(directory)
        require(not directory.is_symlink() and directory.is_dir(), "Expected artifact directory")
        require(set(p.name for p in directory.iterdir()) == set([*self.names, MANIFEST, CHECKSUMS]), "Artifact set mismatch")
        for name in [*self.names, MANIFEST, CHECKSUMS]:
            regular(directory / name)
        frozen = self.app(Path(self.args.app).absolute())
        self.verify_dmg(directory / self.dmg_name, frozen)
        self.source.verify_archive(directory / self.source_name, self.prefix)
        expected = self.metadata(directory, frozen)
        require((directory / MANIFEST).read_bytes() == json_bytes(expected), "Manifest identity/digest/schema mismatch")
        require((directory / CHECKSUMS).read_bytes() == self.checksums(directory), "Checksum mismatch")
        return {name: {"size": (directory / name).stat().st_size, "sha256": digest(directory / name)}
                for name in [*self.names, MANIFEST, CHECKSUMS]}


class GitHub:
    def __init__(self, release):
        self.release, self.commands = release, release.commands
        self.base = f"repos/{REPO}/"

    def api(self, endpoint, *, method="GET", body=None, missing=False):
        # GitHub's repository endpoint rejects a trailing slash with HTTP 404.
        target = self.base + endpoint if endpoint else self.base.rstrip("/")
        command = ["gh", "api", "--hostname", "github.com", "--include", "--method", method, target]
        if body is not None:
            command += ["--input", "-"]
        result = self.commands.run(command, input=json_bytes(body) if body is not None else None, check=False)
        raw = result.stdout.replace(b"\r\n", b"\n")
        header, separator, data = raw.partition(b"\n\n")
        status = re.match(rb"HTTP/[0-9.]+ ([0-9]{3})(?: |\n|$)", header)
        require(separator and status, "Missing GitHub HTTP status")
        code = int(status[1])
        if missing and code == 404:
            return None
        require(result.returncode == 0 and 200 <= code < 300, "GitHub request failed; reconcile before retry")
        if code == 204:
            require(method == "DELETE" and not data.strip(), "Unexpected empty GitHub response")
            return None
        return parse_json(data)

    def pages(self, endpoint):
        for page in range(1, 101):
            values = self.api(f"{endpoint}?per_page=100&page={page}")
            require(isinstance(values, list), "Invalid GitHub list")
            yield from values
            if len(values) < 100:
                return
        raise ReleaseError("GitHub pagination limit reached")

    def repository(self):
        value = self.api("")
        require(isinstance(value, dict) and value.get("full_name") == REPO and
                value.get("private") is False and value.get("visibility") == "public", "Release repository must be public")

    def tag(self, allow_missing=False):
        tag = self.release.tag
        ref = self.api("git/ref/tags/" + quote(tag, safe=""), missing=allow_missing)
        if ref is None:
            return False
        require(isinstance(ref, dict) and ref.get("ref") == "refs/tags/" + tag, "Wrong tag ref")
        obj = ref.get("object")
        seen = set()
        for _ in range(9):
            require(isinstance(obj, dict) and isinstance(obj.get("sha"), str) and SHA.fullmatch(obj["sha"]), "Invalid tag object")
            if obj.get("type") == "commit":
                require(obj["sha"] == self.release.args.source, "Existing tag is immutable and points elsewhere")
                return True
            require(obj.get("type") == "tag" and obj["sha"] not in seen, "Invalid tag chain")
            seen.add(obj["sha"])
            value = self.api("git/tags/" + obj["sha"])
            require(isinstance(value, dict) and value.get("sha") == obj["sha"], "Annotated tag identity mismatch")
            obj = value.get("object")
        raise ReleaseError("Tag chain too deep")

    def find(self):
        matches = []
        for value in self.pages("releases"):
            require(isinstance(value, dict), "Invalid release object")
            if value.get("tag_name") == self.release.tag:
                matches.append(value)
        require(len(matches) <= 1, "Duplicate releases for tag")
        if not matches:
            return None
        value = matches[0]
        require(type(value.get("id")) is int and value["id"] > 0 and type(value.get("draft")) is bool and
                value.get("prerelease") is False and value.get("target_commitish") == self.release.args.source,
                "Release status/source mismatch")
        return value

    def reconcile(self, mutate, read, acceptable):
        cancelled = False
        try:
            mutate()
        except KeyboardInterrupt:
            cancelled = True
        except (ReleaseError, OSError, subprocess.TimeoutExpired):
            # A timed-out request may have succeeded. Always reread, never repeat writes.
            pass
        result = read()
        require(acceptable(result), "Mutation not confirmed; inspect remote state before another explicit invocation")
        if cancelled:
            raise KeyboardInterrupt
        return result

    def assets(self, value, expected, *, complete, anonymous=False):
        found = {}
        for asset in self.pages(f"releases/{value['id']}/assets"):
            require(isinstance(asset, dict), "Invalid asset")
            name = asset.get("name")
            require(isinstance(name, str) and name in expected and name not in found, "Unexpected or duplicate release asset")
            item = expected[name]
            require(type(asset.get("id")) is int and asset["id"] > 0 and asset.get("state") == "uploaded" and
                    type(asset.get("size")) is int and asset["size"] == item["size"] and
                    asset.get("digest") == "sha256:" + item["sha256"], "Asset state/size/digest mismatch; never clobber")
            with tempfile.TemporaryDirectory(prefix="pichi-release-download-") as directory:
                path = Path(directory) / "asset"
                if anonymous:
                    public_download(f"https://github.com/{REPO}/releases/download/{quote(self.release.tag, safe='')}/{name}", path, item)
                else:
                    self.commands.download(self.base + f"releases/assets/{asset['id']}", path)
                require(path.stat().st_size == item["size"] and digest(path) == item["sha256"], "Downloaded asset mismatch")
            found[name] = asset
        require(not complete or set(found) == set(expected), "Incomplete release assets")
        return found

    def draft(self, directory, expected):
        self.repository()
        value = self.find()
        require(value is None or value["draft"] is True, "Existing public release is immutable")
        if not self.tag(allow_missing=True):
            self.reconcile(lambda: self.api("git/refs", method="POST", body={"ref": "refs/tags/" + self.release.tag, "sha": self.release.args.source}),
                           self.tag, bool)
        if value is None:
            value = self.reconcile(lambda: self.api("releases", method="POST", body={
                "tag_name": self.release.tag, "target_commitish": self.release.args.source, "draft": True,
                "prerelease": False, "name": f"Pichi Voice {self.release.args.version} ({self.release.args.build})",
                "body": "Developer ID signed, notarized macOS app in a drag-install DMG. "
                        "Corresponding source and license notices are included. See SHA256SUMS and release-manifest.json."}),
                self.find, lambda result: result is not None and result["draft"] is True)
        found = self.assets(value, expected, complete=False)
        for name in expected:
            if name in found:
                continue
            # Recheck identity/status immediately before each write.
            self.tag()
            current = self.find()
            require(current and current["id"] == value["id"] and current["draft"], "Draft changed during upload")
            path = str(Path(directory).absolute() / name)
            require("#" not in path, "gh upload paths cannot contain #")
            self.reconcile(lambda: self.commands.run(["gh", "release", "upload", self.release.tag, path,
                                                       "--repo", "github.com/" + REPO]),
                           lambda: self.assets(value, expected, complete=False), lambda result: name in result)
        self.tag()
        current = self.find()
        require(current and current["id"] == value["id"] and current["draft"], "Draft changed before verification")
        self.assets(current, expected, complete=True)

    def publish(self, directory, expected):
        validate_evidence(self.release.args.evidence, self.release.args.source, digest(Path(directory) / MANIFEST))
        self.repository()
        value = self.find()
        require(value is not None and value["draft"] is True, "Publish requires an existing draft; public releases are immutable")
        with self.publication_lock():
            self.publish_locked(directory, expected)

    @contextmanager
    def publication_lock(self):
        # GitHub creates refs atomically. A unique tag object distinguishes even
        # two operators releasing the same source commit without sharing a lock.
        obj = self.api("git/tags", method="POST", body={
            "tag": PUBLICATION_LOCK, "message": f"Pichi Voice publication {self.release.tag}\n{uuid.uuid4()}\n",
            "object": self.release.args.source, "type": "commit"})
        require(isinstance(obj, dict) and isinstance(obj.get("sha"), str) and SHA.fullmatch(obj["sha"]),
                "Publication lock object was not confirmed")
        owned_sha = obj["sha"]
        endpoint = "git/ref/tags/" + PUBLICATION_LOCK
        def read():
            value = self.api(endpoint, missing=True)
            if value is not None:
                require(isinstance(value, dict) and value.get("ref") == "refs/tags/" + PUBLICATION_LOCK,
                        "Publication lock identity is invalid")
                require(isinstance(value.get("object"), dict) and isinstance(value["object"].get("sha"), str)
                        and SHA.fullmatch(value["object"]["sha"]), "Publication lock object is invalid")
            return value
        def owned(value):
            return value is not None and value.get("object", {}).get("sha") == owned_sha
        try:
            self.reconcile(lambda: self.api("git/refs", method="POST", body={
                "ref": "refs/tags/" + PUBLICATION_LOCK, "sha": owned_sha}), read, owned)
            yield
        finally:
            with defer_cancellation():
                current = read()
                if owned(current):
                    self.reconcile(lambda: self.api("git/refs/tags/" + PUBLICATION_LOCK, method="DELETE"),
                                   read, lambda value: value is None)

    def publish_locked(self, directory, expected):
        self.tag()
        value = self.find()
        require(value is not None and value["draft"] is True, "Publish requires an existing draft; public releases are immutable")
        self.require_newer_stable_release()
        self.assets(value, expected, complete=True)
        self.tag()
        current = self.find()
        require(current and current["id"] == value["id"] and current["draft"], "Draft changed before publication")
        self.require_newer_stable_release()
        self.reconcile(lambda: self.api(f"releases/{value['id']}", method="PATCH", body={"draft": False, "make_latest": "true"}),
                       self.find, lambda result: result is not None and result["id"] == value["id"] and result["draft"] is False)
        self.verify(expected)

    def require_newer_stable_release(self):
        latest = self.api("releases/latest", missing=True)
        if latest is None:
            return
        require(isinstance(latest, dict) and latest.get("draft") is False and latest.get("prerelease") is False,
                "Invalid latest stable release")
        tag = latest.get("tag_name")
        match = re.fullmatch(r"v([0-9]+)\.([0-9]+)\.([0-9]+)\+([0-9]+)-public\.[0-9]+", tag) if isinstance(tag, str) else None
        require(match is not None, "Latest stable release identity is not recognized")
        previous = tuple(int(value) for value in match.groups())
        candidate = tuple(int(value) for value in self.release.args.version.split(".")) + (int(self.release.args.build),)
        require(candidate > previous, "A public release must advance the latest version/build; the website must not downgrade")

    def verify(self, expected):
        self.repository()
        self.tag()
        value = self.find()
        require(value is not None and value["draft"] is False and isinstance(value.get("published_at"), str)
                and value["published_at"], "Release is not published")
        self.assets(value, expected, complete=True, anonymous=True)
        public_download(f"https://github.com/{REPO}/releases/latest/download/{ALIAS}", None, expected[ALIAS])
        latest = self.api("releases/latest")
        require(isinstance(latest, dict) and latest.get("id") == value["id"] and latest.get("tag_name") == self.release.tag,
                "Stable site alias does not resolve to this release")
        self.tag()


class HTTPSRedirects(HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        validate_download_url(newurl)
        return super().redirect_request(request, fp, code, message, headers, newurl)


def validate_download_url(url):
    value = urlsplit(url)
    require(value.scheme == "https" and value.port in (None, 443) and not value.username and not value.password and
            (value.hostname == "github.com" or (value.hostname or "").endswith(".githubusercontent.com")), "Untrusted download redirect")


def public_download(url, output, expected):
    validate_download_url(url)
    hasher, size = hashlib.sha256(), 0
    # No gh authentication, cookies, netrc or browser context for public checks.
    opener = build_opener(HTTPSRedirects(), HTTPSHandler())
    with opener.open(Request(url, headers={"User-Agent": "Pichi-Voice-release-verifier"}), timeout=60) as response:
        require(response.status == 200, "Public download HTTP status mismatch")
        validate_download_url(response.geturl())
        with (Path(output).open("xb") if output is not None else open(os.devnull, "wb")) as stream:
            while chunk := response.read(1024 * 1024):
                size += len(chunk)
                require(size <= expected["size"], "Public download exceeds expected size")
                hasher.update(chunk)
                stream.write(chunk)
    require(size == expected["size"] and hasher.hexdigest() == expected["sha256"], "Public download digest mismatch")


def validate_evidence(path, source, manifest_sha, now=None):
    regular(path)
    require(Path(path).stat().st_size <= 65536, "Evidence file too large")
    value = parse_json(Path(path).read_bytes())
    require(isinstance(value, dict) and value.get("sourceRevision") == source and
            value.get("manifestSHA256") == manifest_sha, "Evidence does not bind this exact candidate")
    for field in ("independentReview", "tests", "nativeAcceptance"):
        require(isinstance(value.get(field), str) and 0 < len(value[field].strip()) <= 4096, "Missing review/test/native evidence context")
    try:
        timestamp = dt.datetime.fromisoformat(value["verifiedAt"].replace("Z", "+00:00"))
        current = now or dt.datetime.now(dt.timezone.utc)
        require(timestamp.tzinfo is not None and dt.timedelta(0) <= current - timestamp <= dt.timedelta(hours=24), "Evidence is stale or future-dated")
    except (KeyError, ValueError, TypeError, AttributeError) as error:
        raise ReleaseError("Invalid evidence verification timestamp") from error


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", choices=("plan", "prepare", "draft", "publish", "verify"))
    parser.add_argument("--repo", default=".", help="Clean checkout of the exact reviewed source on origin/main")
    parser.add_argument("--source", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--tag", help="Defaults to vVERSION+BUILD-public.1")
    parser.add_argument("--app", help="Exact frozen Developer ID signed, notarized, stapled app")
    parser.add_argument("--dmg", help="Reuse an existing image instead of packaging (prepare only)")
    parser.add_argument("--output", help="New artifact directory (prepare only)")
    parser.add_argument("--artifacts", help="Prepared artifact directory (draft/publish/verify)")
    parser.add_argument("--evidence", help="Private review/test/native acceptance context JSON (publish only)")
    args = parser.parse_args(argv)
    release = Release(args)
    if args.stage == "plan":
        print(json_bytes({"tag": release.tag, "sourceRevision": args.source,
                          "artifacts": [*release.names, MANIFEST, CHECKSUMS],
                          "siteURL": f"https://github.com/{REPO}/releases/latest/download/{ALIAS}",
                          "stages": ["prepare", "draft", "publish", "verify"]}).decode(), end="")
        return
    require(args.app, "--app is required")
    if args.stage == "prepare":
        require(args.output and not args.artifacts and not args.evidence, "prepare requires --output only")
        release.prepare()
    else:
        require(args.artifacts and not args.output and not args.dmg, "Stage requires --artifacts, not --output/--dmg")
        require(args.stage == "publish" or not args.evidence, "--evidence is publish-only")
        require(args.stage != "publish" or args.evidence, "publish requires --evidence")
        release.source.validate()
        expected = release.local(Path(args.artifacts))
        release.source.clean()
        github = GitHub(release)
        if args.stage == "verify":
            github.verify(expected)
        else:
            getattr(github, args.stage)(Path(args.artifacts), expected)
    print(f"{args.stage}: verified {release.tag} at {args.source}")


if __name__ == "__main__":
    def cancelled(_signum, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, cancelled)
    try:
        main()
    except (ReleaseError, ValueError, OSError, tarfile.TarError, plistlib.InvalidFileException,
            subprocess.SubprocessError, KeyboardInterrupt) as error:
        print(f"Release stopped: {type(error).__name__}. {error if isinstance(error, ReleaseError) else 'Inspect private local evidence; no blind retries.'}", file=sys.stderr)
        sys.exit(1)
