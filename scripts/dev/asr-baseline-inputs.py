#!/usr/bin/env python3
"""Declare and copy only the fixture files authorized for the isolated ASR host."""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import stat
import sys
import tempfile


MAX_FILES = 100_000
MAX_DIRECTORIES = 100_000
MAX_FILE_BYTES = 16 * 1024**3
MAX_TOTAL_BYTES = 64 * 1024**3
OUTPUT_ROOT = "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/ASRBaselineInputs"
STAMP = ".staging-contract.json"


def safe_path(value):
    if not isinstance(value, str) or not value or len(value.encode()) > 1024:
        raise ValueError("invalid fixture path")
    if any(character in value for character in '\\$\r\n"'):
        raise ValueError("fixture paths cannot contain filelist or build-setting syntax")
    path = PurePosixPath(value)
    if path.is_absolute() or any(part in ("", ".", "..") for part in value.split("/")):
        raise ValueError("fixture paths must be normalized relative paths")
    if path.parts[0].startswith("~") or path.parts[0] == STAMP:
        raise ValueError("reserved fixture path")
    return value


def validate_manifest(manifest):
    if not isinstance(manifest, dict) or manifest.get("version") != 1:
        raise ValueError("unsupported staging manifest")
    files = manifest.get("files")
    if not isinstance(files, list) or not files or len(files) > MAX_FILES:
        raise ValueError("fixture file count is outside staging bounds")
    names = []
    total = 0
    for item in files:
        if not isinstance(item, dict):
            raise ValueError("invalid fixture entry")
        names.append(safe_path(item.get("path")))
        size = item.get("size")
        if type(size) is not int or not 0 <= size <= MAX_FILE_BYTES:
            raise ValueError("fixture size is outside staging bounds")
        total += size
    if names != sorted(set(names)) or total > MAX_TOTAL_BYTES:
        raise ValueError("fixture paths must be unique and sorted within total size bounds")
    directories = {str(parent) for name in names for parent in PurePosixPath(name).parents if str(parent) != "."}
    if len(directories) > MAX_DIRECTORIES or directories.intersection(names):
        raise ValueError("invalid fixture directory set")
    return files, sorted(directories, key=lambda name: (name.count("/"), name))


def prepare(input_directory, declaration_directory):
    supplied = Path(input_directory)
    if not supplied.is_absolute() or supplied.is_symlink():
        raise ValueError("fixture directory must be an absolute, non-symlink path")
    root = supplied.resolve(strict=True)
    if not root.is_dir() or any(character in str(root) for character in '\\$\r\n"'):
        raise ValueError("invalid fixture directory")
    files = []
    directories = []
    pending = [root]
    total = 0
    while pending:
        directory = pending.pop()
        with os.scandir(directory) as entries:
            for entry in entries:
                relative = safe_path(str(Path(entry.path).relative_to(root)))
                metadata = entry.stat(follow_symlinks=False)
                if stat.S_ISDIR(metadata.st_mode):
                    directories.append(relative)
                    if len(directories) > MAX_DIRECTORIES:
                        raise ValueError("too many fixture directories")
                    pending.append(Path(entry.path))
                elif stat.S_ISREG(metadata.st_mode):
                    files.append({"path": relative, "size": metadata.st_size})
                    total += metadata.st_size
                    if len(files) > MAX_FILES or metadata.st_size > MAX_FILE_BYTES or total > MAX_TOTAL_BYTES:
                        raise ValueError("fixture set is outside staging bounds")
                else:
                    raise ValueError("fixture symlinks and special files are forbidden")
    manifest = {"version": 1, "input_root": str(root), "files": sorted(files, key=lambda item: item["path"])}
    files, directories = validate_manifest(manifest)
    declarations = Path(declaration_directory)
    declarations.mkdir(parents=True, exist_ok=True, mode=0o700)
    # Each preparation gets a new contract, so concurrent preparations cannot replace it.
    generated = Path(tempfile.mkdtemp(prefix="inputs-", dir=declarations))
    inputs = [str(root)] + [str(root / name) for name in directories] + [str(root / item["path"]) for item in files]
    outputs = [OUTPUT_ROOT] + [f"{OUTPUT_ROOT}/{name}" for name in directories]
    outputs += [f"{OUTPUT_ROOT}/{item['path']}" for item in files] + [f"{OUTPUT_ROOT}/{STAMP}"]
    content = {
        "manifest.json": json.dumps(manifest, sort_keys=True, indent=2) + "\n",
        "inputs.xcfilelist": "\n".join(inputs) + "\n",
        "outputs.xcfilelist": "\n".join(outputs) + "\n",
        "inputs.xcconfig": "".join(f"{key} = {value}\n" for key, value in (
            ("FLUID_ASR_BASELINE_INPUTS", root),
            ("FLUID_ASR_BASELINE_INPUT_LIST", generated / "inputs.xcfilelist"),
            ("FLUID_ASR_BASELINE_OUTPUT_LIST", generated / "outputs.xcfilelist"),
            ("FLUID_ASR_BASELINE_STAGING_MANIFEST", generated / "manifest.json"),
        )),
    }
    for name, data in content.items():
        destination = generated / name
        destination.write_text(data)
        destination.chmod(0o600)
    return generated / "inputs.xcconfig"


def open_directory(root_fd, relative):
    descriptor = os.dup(root_fd)
    try:
        for component in PurePosixPath(relative).parts:
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def open_parent(root_fd, relative):
    return open_directory(root_fd, str(PurePosixPath(relative).parent))


def validate_output(output_fd, files, directories, stamped):
    paths = [item["path"] for item in files] + directories + [STAMP]
    allowed = {"": set()}
    for path in paths:
        parent, _, name = path.rpartition("/")
        allowed.setdefault(parent, set()).add(name)
    directory_set = set(directories)
    pending = [""]
    while pending:
        relative = pending.pop()
        descriptor = open_directory(output_fd, relative)
        try:
            entries = set(os.listdir(descriptor))
            children = {f"{relative}/{name}" if relative else name for name in entries}
            # Xcode can precreate the declared output directories. Only empty declared
            # directories are safe before ownership exists; any old file requires clean.
            if (not stamped and not children.issubset(directory_set)) or not entries.issubset(allowed.get(relative, set())):
                raise ValueError("unowned or unexpected fixture resources; clean baseline build products before staging")
            for name in sorted(entries):
                child_path = f"{relative}/{name}" if relative else name
                if child_path in directory_set:
                    pending.append(child_path)
        finally:
            os.close(descriptor)


def stage(input_directory, output_directory, manifest_path):
    manifest = json.loads(Path(manifest_path).read_text())
    files, directories = validate_manifest(manifest)
    root = Path(input_directory)
    if not root.is_absolute() or root.is_symlink():
        raise ValueError("fixture directory must be an absolute, non-symlink path")
    root = root.resolve(strict=True)
    pinned = manifest.get("input_root")
    if pinned is None:
        public_root = Path(__file__).resolve().parents[2] / "Tests/FluidASRBaselineHost/Inputs"
        if root != public_root:
            raise ValueError("custom fixtures require prepared file declarations")
    elif str(root) != pinned:
        raise ValueError("fixture directory does not match the prepared declarations")
    output = Path(output_directory)
    if not output.is_absolute() or output.is_symlink():
        raise ValueError("staging output must be an absolute, non-symlink directory")
    contract = hashlib.sha256(json.dumps([str(root), [item["path"] for item in files]]).encode()).hexdigest()
    output.mkdir(parents=True, exist_ok=True)
    with_parent = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    root_fd = os.open(root, with_parent)
    output_fd = None
    try:
        output_fd = os.open(output, with_parent)
        stamped = False
        try:
            stamp_fd = os.open(STAMP, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=output_fd)
        except FileNotFoundError:
            pass
        else:
            with os.fdopen(stamp_fd, "r") as stream:
                if stream.read(128) != contract:
                    raise ValueError("fixture set changed; clean baseline build products before staging")
            stamped = True
        validate_output(output_fd, files, directories, stamped)
        # Record ownership before copying, including an interrupted first attempt.
        stamp_fd = os.open(STAMP, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600, dir_fd=output_fd)
        with os.fdopen(stamp_fd, "w") as stream:
            stream.write(contract)
        for directory in directories:
            parent_fd = open_parent(output_fd, directory)
            try:
                try:
                    os.mkdir(PurePosixPath(directory).name, dir_fd=parent_fd)
                except FileExistsError:
                    descriptor = os.open(PurePosixPath(directory).name, with_parent, dir_fd=parent_fd)
                    os.close(descriptor)
            finally:
                os.close(parent_fd)
        for item in files:
            source_parent = open_parent(root_fd, item["path"])
            destination_parent = None
            try:
                destination_parent = open_parent(output_fd, item["path"])
                source_fd = os.open(PurePosixPath(item["path"]).name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=source_parent)
                with os.fdopen(source_fd, "rb") as source:
                    before = os.fstat(source.fileno())
                    if not stat.S_ISREG(before.st_mode) or before.st_size != item["size"]:
                        raise ValueError("fixture changed since declaration; prepare file declarations again")
                    destination_fd = os.open(PurePosixPath(item["path"]).name, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600, dir_fd=destination_parent)
                    with os.fdopen(destination_fd, "wb") as destination:
                        remaining = item["size"]
                        while remaining:
                            data = source.read(min(remaining, 1024 * 1024))
                            if not data:
                                raise ValueError("fixture changed while staging")
                            destination.write(data)
                            remaining -= len(data)
                    after = os.fstat(source.fileno())
                    if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
                        raise ValueError("fixture changed while staging")
            finally:
                os.close(source_parent)
                if destination_parent is not None:
                    os.close(destination_parent)
    finally:
        os.close(root_fd)
        if output_fd is not None:
            os.close(output_fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="action", required=True)
    preparation = subparsers.add_parser("prepare")
    preparation.add_argument("input_directory")
    subparsers.add_parser("stage")
    arguments = parser.parse_args()
    try:
        if arguments.action == "prepare":
            root = Path(__file__).resolve().parents[2]
            print(prepare(arguments.input_directory, root / ".build/asr-baseline-inputs"))
        else:
            stage(os.environ["FLUID_ASR_BASELINE_INPUTS"],
                  Path(os.environ["TARGET_BUILD_DIR"]) / os.environ["UNLOCALIZED_RESOURCES_FOLDER_PATH"] / "ASRBaselineInputs",
                  os.environ["FLUID_ASR_BASELINE_STAGING_MANIFEST"])
    except (KeyError, OSError, ValueError) as error:
        print(f"error: ASR baseline staging: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
