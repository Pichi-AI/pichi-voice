#!/usr/bin/env python3
"""Validate embedded frameworks and repair the copied ONNX placeholder's OS metadata.

Xcode replaces ONNX's static archive with a small dynamic placeholder when embedding
it, but retains the upstream plist's older minimum. Only the copied product is fixed.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import struct
import subprocess
import sys


class MetadataError(ValueError):
    pass


def version(value):
    if not isinstance(value, str) or not value or any(not x.isdigit() for x in value.split(".")):
        raise MetadataError("Invalid minimum OS version")
    parts = tuple(int(x) for x in value.split("."))
    if not 1 <= len(parts) <= 3:
        raise MetadataError("Invalid minimum OS version")
    return (parts + (0, 0))[:3]


def version_string(value):
    parts = [str(value >> 16), str((value >> 8) & 255), str(value & 255)]
    return ".".join(parts if parts[-1] != "0" else parts[:2])


def macho_minimums(path):
    """Read only bounded Mach-O headers, including every universal-binary slice."""
    with path.open("rb") as stream:
        total = os.fstat(stream.fileno()).st_size

        def read(offset, size):
            if offset < 0 or size < 0 or offset + size > total:
                raise MetadataError("Truncated Mach-O")
            stream.seek(offset)
            data = stream.read(size)
            if len(data) != size:
                raise MetadataError("Truncated Mach-O")
            return data

        magic = read(0, 4)
        fat = {b"\xca\xfe\xba\xbe": (">", False), b"\xbe\xba\xfe\xca": ("<", False),
               b"\xca\xfe\xba\xbf": (">", True), b"\xbf\xba\xfe\xca": ("<", True)}
        slices = [(0, total)]
        if magic in fat:
            endian, wide = fat[magic]
            count = struct.unpack(endian + "I", read(4, 4))[0]
            if not 1 <= count <= 32:
                raise MetadataError("Invalid architecture count")
            fmt = endian + ("IIQQII" if wide else "IIIII")
            size = struct.calcsize(fmt)
            slices = []
            for index in range(count):
                fields = struct.unpack(fmt, read(8 + index * size, size))
                offset, length = fields[2:4]
                if offset < 8 + count * size or not length or offset + length > total:
                    raise MetadataError("Invalid Mach-O slice")
                slices.append((offset, length))
        result = []
        thin = {b"\xce\xfa\xed\xfe": ("<", 28), b"\xcf\xfa\xed\xfe": ("<", 32),
                b"\xfe\xed\xfa\xce": (">", 28), b"\xfe\xed\xfa\xcf": (">", 32)}
        for offset, length in slices:
            current = read(offset, 4)
            if current not in thin:
                raise MetadataError("Embedded executable is not a Mach-O binary")
            endian, header_size = thin[current]
            header = struct.unpack(endian + "IIIIIII", read(offset, 28))
            count, size = header[4:6]
            if count > 4096 or size > 1024 * 1024 or header_size + size > length:
                raise MetadataError("Invalid Mach-O load commands")
            cursor, end = offset + header_size, offset + header_size + size
            found = []
            for _ in range(count):
                if cursor + 8 > end:
                    raise MetadataError("Truncated Mach-O load command")
                command, command_size = struct.unpack(endian + "II", read(cursor, 8))
                if command_size < 8 or cursor + command_size > end:
                    raise MetadataError("Invalid Mach-O load command")
                if command == 0x32:  # LC_BUILD_VERSION
                    if command_size < 24:
                        raise MetadataError("Invalid LC_BUILD_VERSION")
                    platform, minimum = struct.unpack(endian + "II", read(cursor + 8, 8))
                    found.append((platform, version_string(minimum)))
                elif command in (0x24, 0x25, 0x2F, 0x30):
                    if command_size < 16:
                        raise MetadataError("Invalid legacy OS version command")
                    minimum = struct.unpack(endian + "I", read(cursor + 8, 4))[0]
                    found.append(({0x24: 1, 0x25: 2, 0x2F: 3, 0x30: 4}[command], version_string(minimum)))
                cursor += command_size
            if cursor != end or len(found) != 1:
                raise MetadataError("Missing or ambiguous Mach-O minimum OS")
            result.append(found[0])
        return result


def framework_metadata(framework):
    plist_path = framework / "Info.plist"
    info = plistlib.loads(plist_path.read_bytes())
    executable = info.get("CFBundleExecutable")
    if not isinstance(executable, str) or not executable or Path(executable).name != executable:
        raise MetadataError("Invalid framework executable name")
    binary = framework / executable
    minimums = macho_minimums(binary)
    if any(platform not in (2, 7) for platform, _ in minimums):
        raise MetadataError("Embedded mobile framework has an unexpected platform")
    return plist_path, info, binary, minimums


def check(root):
    app_info = plistlib.loads((root / "Info.plist").read_bytes())
    app_minimum = version(app_info.get("MinimumOSVersion"))
    frameworks = sorted(root.rglob("*.framework"))
    if not frameworks:
        raise MetadataError("No embedded frameworks found")
    for framework in frameworks:
        _, info, _, minimums = framework_metadata(framework)
        declared = version(info.get("MinimumOSVersion"))
        if any(declared < version(minimum) for _, minimum in minimums):
            raise MetadataError(str(framework.relative_to(root)) + ": plist minimum is below Mach-O minimum")
        if declared > app_minimum or any(version(minimum) > app_minimum for _, minimum in minimums):
            raise MetadataError(str(framework.relative_to(root)) + ": requires a newer OS than the containing app")
    return len(frameworks)


def normalize_onnx(framework, environment, run=subprocess.run):
    if framework.name != "onnxruntime.framework" or framework.is_symlink():
        raise MetadataError("Only the copied ONNX framework may be normalized")
    plist_path, info, binary, minimums = framework_metadata(framework)
    if plist_path.is_symlink() or binary.is_symlink():
        raise MetadataError("Copied ONNX metadata and executable must not be symlinks")
    if info.get("CFBundleIdentifier") != "com.microsoft.onnxruntime":
        raise MetadataError("Unexpected ONNX bundle identifier")
    values = {version(minimum) for _, minimum in minimums}
    if len(values) != 1:
        raise MetadataError("ONNX architectures have different minimum OS versions")
    actual = next(iter(values))
    if actual > version(environment["IPHONEOS_DEPLOYMENT_TARGET"]):
        raise MetadataError("ONNX requires a newer OS than the containing app")
    changed = version(info.get("MinimumOSVersion")) < actual
    signing = environment.get("CODE_SIGNING_ALLOWED", "YES") != "NO"
    identity = environment.get("EXPANDED_CODE_SIGN_IDENTITY", "")
    verify = ["/usr/bin/codesign", "--verify", "--strict", str(framework)]
    if not changed:
        if not signing:
            return False
        try:
            run(verify, check=True)
            return False
        except subprocess.CalledProcessError:
            # A previous attempt may have written the plist before signing failed.
            # Retrying must repair that signature instead of accepting stale signing.
            pass
    if signing and not identity:
        raise MetadataError("Signing identity is required before modifying a signed framework")
    if changed:
        info["MinimumOSVersion"] = next(minimum for _, minimum in minimums)
        original = plist_path.read_bytes()
        plist_path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY if original.startswith(b"bplist") else plistlib.FMT_XML))
    if signing:
        run(["/usr/bin/codesign", "--force", "--sign", identity,
             "--preserve-metadata=identifier,entitlements,requirements,flags,runtime",
             "--generate-entitlement-der", str(framework)], check=True)
        run(verify, check=True)
    return changed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("check", "normalize-onnx"))
    parser.add_argument("path", type=Path)
    args = parser.parse_args()
    try:
        if args.operation == "check":
            result = {"frameworksChecked": check(args.path), "status": "PASS"}
        else:
            expected = Path(os.environ["TARGET_BUILD_DIR"]) / os.environ["FRAMEWORKS_FOLDER_PATH"] / "onnxruntime.framework"
            if (args.path.resolve() != expected.resolve() or
                    not expected.resolve().is_relative_to(Path(os.environ["TARGET_BUILD_DIR"]).resolve())):
                raise MetadataError("ONNX normalization must target the current build product")
            result = {"normalized": normalize_onnx(args.path, os.environ), "status": "PASS"}
        print(json.dumps(result))
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print("Framework metadata: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
