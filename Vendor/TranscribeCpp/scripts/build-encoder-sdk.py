#!/usr/bin/env python3
"""Build the pinned Mac arm64 encoder SDK, preserving official legacy slices.

This builds an artifact only. It neither changes Package.swift nor publishes it.
The source and build directories are task-owned compiler scratch. The output is
retained delivery evidence and must be outside Git.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import zipfile

BASE_SHA = "33d5c383e43e6acbd572845866ea75b8c7959fa5"
OFFICIAL_SHA256 = "4092276cd295860ae9637a2913cf2d8747f39d454bb7fb3c79d6af9f858a4bb8"
SOURCE_URL = "https://github.com/handy-computer/transcribe.cpp.git"
EXPORTS = ["transcribe_encoder_features_api_version", "transcribe_encoder_features_supported",
           "transcribe_clear_encoder_features", "transcribe_get_encoder_features"]
PACKAGE = Path(__file__).resolve().parents[1]
PATCH = PACKAGE / "Patches/encoder-features-v1.patch"


def sha(path: Path) -> str:
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def command(args, *, cwd=None, env=None, log=None):
    args = [str(arg) for arg in args]
    if log is None:
        return subprocess.check_output(args, cwd=cwd, env=env, text=True).strip()
    with log.open("w") as stream:
        subprocess.run(args, cwd=cwd, env=env, stdout=stream, stderr=subprocess.STDOUT, check=True)
    return ""


def verify_source(source: Path):
    assert command(["git", "rev-parse", "HEAD"], cwd=source) == BASE_SHA
    # Compare against an independent temporary index, never the checkout's index.
    with tempfile.TemporaryDirectory(prefix="encoder-sdk-index-") as temp:
        index = Path(temp) / "index"
        env = dict(os.environ, GIT_INDEX_FILE=str(index))
        command(["git", "read-tree", BASE_SHA], cwd=source, env=env)
        command(["git", "apply", "--cached", PATCH], cwd=source, env=env)
        assert not command(["git", "ls-files", "--others", "--exclude-standard"], cwd=source, env=env), "Untracked native source"
        command(["git", "diff", "--exit-code", "--no-ext-diff"], cwd=source, env=env)


def dependencies(binary: Path, arch: str):
    lines = command(["otool", "-L", "-arch", arch, binary]).splitlines()[1:]
    return [line.strip().split(" (", 1)[0] for line in lines]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--official-archive", type=Path, required=True)
    parser.add_argument("--cmake", default="cmake")
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args()
    if sys.platform != "darwin" or command(["uname", "-m"]) != "arm64":
        parser.error("Build requires an Apple Silicon Mac with Xcode and Metal tools")
    if not 1 <= args.jobs <= 4:
        parser.error("--jobs must be between 1 and 4")
    archive = args.official_archive.resolve(strict=True)
    if sha(archive) != OFFICIAL_SHA256:
        parser.error("Official v0.1.2 archive checksum does not match")
    work = args.work_dir.resolve()
    output = args.output.resolve()
    if output.exists():
        parser.error("Output already exists; select a new artifact directory")
    if output == work or work in output.parents or output in work.parents:
        parser.error("Keep delivery artifacts outside compiler scratch")
    output.mkdir(parents=True)
    work.mkdir(parents=True, exist_ok=True)
    source = work / "native-sdk-source"
    build = work / "native-sdk-static"
    if not source.exists():
        command(["git", "clone", "--depth", "1", "--branch", "v0.1.2", SOURCE_URL, source], log=output / "clone.log")
    assert command(["git", "rev-parse", "HEAD"], cwd=source) == BASE_SHA
    if not command(["git", "diff", "--name-only"], cwd=source):
        command(["git", "apply", "--check", PATCH], cwd=source)
        command(["git", "apply", PATCH], cwd=source)
    verify_source(source)
    options = ["-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_OSX_SYSROOT=macosx",
               "-DCMAKE_OSX_ARCHITECTURES=arm64", "-DCMAKE_OSX_DEPLOYMENT_TARGET=13.0",
               "-DTRANSCRIBE_BUILD_SHARED=OFF", "-DTRANSCRIBE_BUILD_TESTS=ON",
               "-DTRANSCRIBE_BUILD_EXAMPLES=OFF", "-DTRANSCRIBE_BUILD_TOOLS=OFF",
               "-DTRANSCRIBE_INSTALL=OFF", "-DTRANSCRIBE_USE_OPENMP=OFF", "-DGGML_OPENMP=OFF",
               "-DGGML_NATIVE=OFF", "-DTRANSCRIBE_METAL=ON", "-DGGML_METAL=ON",
               "-DGGML_METAL_EMBED_LIBRARY=ON", "-DTRANSCRIBE_ENABLE_VALIDATION_HOOKS=OFF"]
    command([args.cmake, "-S", source, "-B", build, *options], log=output / "configure.log")
    command([args.cmake, "--build", build, "--target", "transcribe", "transcribe_api_smoke",
             "transcribe_encoder_features_unit", "--parallel", args.jobs], log=output / "build.log")
    command([str(Path(args.cmake).with_name("ctest")) if "/" in args.cmake else "ctest",
             "--test-dir", build, "-R", "^(transcribe_api_smoke|transcribe_encoder_features_unit)$",
             "--output-on-failure"], log=output / "native-tests.log")
    # Official CI force-loads each archive into one image, retaining Objective-C
    # metadata and embedded Metal shaders without external libggml dependencies.
    archives = sorted(p for p in build.rglob("*.a") if p.name == "libtranscribe.a" or p.name.startswith("libggml"))
    assert any(p.name == "libtranscribe.a" for p in archives)
    assert any(p.name == "libggml-metal.a" for p in archives)
    arm = output / "macos-arm64.dylib"
    command(["xcrun", "--sdk", "macosx", "clang++", "-dynamiclib", "-isysroot",
             command(["xcrun", "--sdk", "macosx", "--show-sdk-path"]), "-arch", "arm64",
             "-mmacosx-version-min=13.0", *[f"-Wl,-force_load,{p}" for p in archives],
             "-framework", "Foundation", "-framework", "Metal", "-framework", "MetalKit",
             "-framework", "Accelerate", "-install_name",
             "@rpath/CTranscribe.framework/Versions/Current/CTranscribe", "-o", arm], log=output / "link.log")
    exports = command(["nm", "-gU", arm])
    assert all("_" + name in exports for name in EXPORTS)
    deps = dependencies(arm, "arm64")
    assert all(dep.startswith(("/System/Library/", "/usr/lib/", "@rpath/CTranscribe.framework/")) for dep in deps), deps
    (output / "macos-arm64-dependencies.txt").write_text("\n".join(deps) + "\n")
    with tempfile.TemporaryDirectory(prefix="official-encoder-sdk-", dir=work) as temp:
        staging = Path(temp)
        with zipfile.ZipFile(archive) as z:
            for item in z.infolist():
                assert not Path(item.filename).is_absolute() and ".." not in Path(item.filename).parts
            z.extractall(staging)
        original = staging / "TranscribeCpp.xcframework"
        target = output / "TranscribeCpp.xcframework"
        shutil.copytree(original, target)
        mac = target / "macos-arm64_x86_64/CTranscribe.framework"
        original_mac = original / "macos-arm64_x86_64/CTranscribe.framework/Versions/A/CTranscribe"
        intel = output / "legacy-macos-x86_64.dylib"
        command(["lipo", original_mac, "-thin", "x86_64", "-output", intel])
        # Recreate versioned symlinks. Upstream's archive duplicated them as
        # directories, which is accepted by old builds but warns during embedding.
        shutil.rmtree(mac)
        version = mac / "Versions/A"
        (version / "Headers").mkdir(parents=True)
        (version / "Modules").mkdir()
        (version / "Resources").mkdir()
        for name, destination in [("Current", "A")]:
            (mac / "Versions" / name).symlink_to(destination)
        for name in ["Headers", "Modules", "Resources", "CTranscribe"]:
            (mac / name).symlink_to("Versions/Current/" + name)
        for header in [source / "include/transcribe.h", *sorted((source / "include/transcribe").glob("*.h"))]:
            (version / "Headers" / header.name).write_text(header.read_text().replace('#include "transcribe/', '#include "'))
        headers = sorted(p.name for p in (version / "Headers").glob("*.h"))
        module = 'framework module CTranscribe {\n' + "\n".join(f'    header "{h}"' for h in headers)
        module += '\n    link "c++"\n    link "z"\n    link framework "Accelerate"\n    link framework "Metal"\n    link framework "Foundation"\n    export *\n}\n'
        (version / "Modules/module.modulemap").write_text(module)
        info = plistlib.loads((original / "macos-arm64_x86_64/CTranscribe.framework/Versions/A/Resources/Info.plist").read_bytes())
        info["CFBundleVersion"] = "2"
        info["CFBundleShortVersionString"] = "0.1.2"
        (version / "Resources/Info.plist").write_bytes(plistlib.dumps(info))
        command(["lipo", "-create", arm, intel, "-output", version / "CTranscribe"])
        command(["codesign", "--force", "--sign", "-", "--timestamp=none", mac], log=output / "codesign.log")
        command(["codesign", "--verify", "--strict", mac])
        intel_check = output / "packaged-macos-x86_64.dylib"
        command(["lipo", version / "CTranscribe", "-thin", "x86_64", "-output", intel_check])
        # Signing updates the fat binary signature, including legacy slice's
        # signature. Compare unsigned load commands/code using codesign removal
        # on disposable thin copies, never the official input.
        original_intel = output / "original-intel-unsigned.dylib"
        packaged_intel = output / "packaged-intel-unsigned.dylib"
        shutil.copy2(intel, original_intel); shutil.copy2(intel_check, packaged_intel)
        for binary in [original_intel, packaged_intel]:
            command(["codesign", "--remove-signature", binary])
        assert sha(original_intel) == sha(packaged_intel)
        legacy = {}
        for entry in plistlib.loads((original / "Info.plist").read_bytes())["AvailableLibraries"]:
            name = entry["LibraryIdentifier"]
            if entry["SupportedPlatform"] != "ios":
                continue
            paths = sorted(p for p in (original / name).rglob("*") if p.is_file())
            hashes = {str(p.relative_to(original)): sha(p) for p in paths}
            assert all(sha(target / relative) == digest for relative, digest in hashes.items())
            legacy[name] = hashes
        assert sha(original / "Info.plist") == sha(target / "Info.plist")
    smoke = output / "encoder-sdk-smoke"
    command(["xcrun", "clang++", "-std=c++17", "-O2", PACKAGE / "scripts/encoder-sdk-smoke.cpp",
             "-F", target / "macos-arm64_x86_64", "-framework", "CTranscribe",
             "-Wl,-rpath," + str(target / "macos-arm64_x86_64"), "-o", smoke],
            log=output / "packaged-smoke-build.log")
    command([smoke], log=output / "packaged-smoke.json")
    for name, relative in [("LICENSE", "LICENSE"), ("LICENSE.ggml", "ggml/LICENSE"),
                           ("LICENSE.miniz", "src/third_party/miniz/LICENSE")]:
        shutil.copy2(source / relative, target / name)
    notice = ("Pichi encoder snapshot SDK v1, derived from transcribe.cpp v0.1.2.\n"
              "Mac arm64 CPU and Metal: rebuilt from pinned source plus encoder-features-v1.patch.\n"
              "Mac x86_64 and iOS/simulator: official v0.1.2 code, optional encoder API unavailable.\n"
              "No model weights or user data are included.\n")
    (target / "NOTICE.pichi-encoder-sdk.txt").write_text(notice)
    shutil.copy2(PATCH, output / "encoder-features-v1.patch")
    metadata = {"source_url": SOURCE_URL, "source_commit": BASE_SHA, "source_tag": "v0.1.2",
                "patch_sha256": sha(PATCH), "official_archive_sha256": sha(archive),
                "cmake_options": options, "cmake_version": command([args.cmake, "--version"]),
                "xcode_version": command(["xcodebuild", "-version"]),
                "clang_version": command(["xcrun", "clang++", "--version"]),
                "native_tests": "transcribe_api_smoke and transcribe_encoder_features_unit passed",
                "new_feature_platform": "macOS arm64; CPU and Metal compiled; embedded shaders",
                "legacy_platforms": "macOS x86_64 and original iOS/simulator code retained",
                "legacy_intel_unsigned_sha256": sha(original_intel), "legacy_ios_files": legacy,
                "macos_framework_sha256": sha(version / "CTranscribe"),
                "self_contained_dependencies": deps, "optional_encoder_api_version": 1,
                "new_exports": EXPORTS, "model_tests_run": False, "published": False}
    (output / "build-provenance.json").write_text(json.dumps(metadata, indent=2) + "\n")
    # -y stores versioned framework symlinks as links instead of duplicating
    # binaries. SwiftPM accepts the same top-level artifact name as upstream.
    zipped = output / "TranscribeCpp.xcframework.zip"
    command(["/usr/bin/zip", "-qryX", zipped.name, target.name], cwd=output, log=output / "zip.log")
    checksum = command(["swift", "package", "compute-checksum", zipped])
    assert checksum == sha(zipped)
    (output / "TranscribeCpp.xcframework.zip.sha256").write_text(checksum + "\n")
    print(json.dumps({"artifact": str(zipped), "sha256": checksum,
                      "framework": str(target), "provenance": str(output / "build-provenance.json")}, indent=2))


if __name__ == "__main__":
    main()
