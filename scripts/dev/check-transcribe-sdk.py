#!/usr/bin/env python3
"""Verify the checked-in native SDK without downloading or loading a model."""
from pathlib import Path
import hashlib
import json
import plistlib
import zipfile


root = Path(__file__).resolve().parents[2]
package = root / "Vendor/TranscribeCpp"
directory = package / "Artifacts"
manifest = json.loads((directory / "manifest.json").read_text())
archive = directory / manifest["artifact"]
assert archive.parent == directory and archive.suffix == ".zip"
assert archive.stat().st_size <= 32 * 1024 * 1024
assert hashlib.sha256(archive.read_bytes()).hexdigest() == manifest["artifact_sha256"], "SDK checksum mismatch"
patch = package / "Patches/encoder-features-v1.patch"
assert hashlib.sha256(patch.read_bytes()).hexdigest() == manifest["patch_sha256"], "SDK source patch changed; rebuild the artifact"
assert 'path: "Artifacts/TranscribeCpp.xcframework.zip"' in (package / "Package.swift").read_text()

prefix = "TranscribeCpp.xcframework/"
with zipfile.ZipFile(archive) as bundle:
    assert len(bundle.infolist()) <= 256
    assert sum(item.file_size for item in bundle.infolist()) <= 128 * 1024 * 1024
    for item in bundle.infolist():
        assert item.filename.startswith(prefix)
        assert ".." not in Path(item.filename).parts
    metadata = plistlib.loads(bundle.read(prefix + "Info.plist"))
    slices = {item["LibraryIdentifier"]: item for item in metadata["AvailableLibraries"]}
    assert set(slices) == {"macos-arm64_x86_64", "ios-arm64", "ios-arm64_x86_64-simulator"}
    mac = bundle.read(prefix + "macos-arm64_x86_64/CTranscribe.framework/Versions/A/CTranscribe")
    assert hashlib.sha256(mac).hexdigest() == manifest["macos_framework_sha256"]
    for symbol in manifest["new_exports"]:
        assert ("_" + symbol).encode() + b"\0" in mac, symbol
    for files in manifest["legacy_ios_files"].values():
        for name, digest in files.items():
            assert hashlib.sha256(bundle.read(prefix + name)).hexdigest() == digest, name
    for name in manifest["license_files"]:
        assert len(bundle.read(prefix + name)) > 100, name

print("Native SDK checksum, patch provenance, platform slices, encoder exports and licenses passed.")
