#!/usr/bin/env python3
"""Build a native Pichi Voice Installer from a frozen notarized app.

Requires macOS packaging tools and Pillow. Never installs, launches, re-signs
or changes the input app. Production requires a Developer ID Installer identity;
--unsigned-preview creates a PRIVATE review artifact, never a release.
"""

import argparse
import importlib.util
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
RESOURCES = Path(__file__).with_name("macos-pkg-resources")
ICON = ROOT / "website/dist/voice/assets/pichi.png"
TEAM = "LU46F7HGJM"
IDENTIFIER = "ai.pichi.voice.installer"
APP_NAME = "Pichi Voice.app"
INSTALL_PATH = f"/Applications/{APP_NAME}"
COMPONENT = "PichiVoice.pkg"

spec = importlib.util.spec_from_file_location("pichi_dmg_packager", Path(__file__).with_name("package-macos-dmg.py"))
dmg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dmg)


def installer_scripts(commands=None):
    """Generate production scripts; command substitution is an offline-test seam.

    No environment/PATH overrides are consulted by the installed scripts.
    launchctl changes bootstrap context, sudo changes credentials: both matter.
    """
    paths = {"id": "/usr/bin/id", "pgrep": "/usr/bin/pgrep",
             "stat": "/usr/bin/stat", "launchctl": "/bin/launchctl",
             "sudo": "/usr/bin/sudo", "open": "/usr/bin/open"}
    if commands:
        if commands.keys() - paths.keys():
            raise ValueError("Unknown installer command substitution")
        paths.update(commands)
    c = {key: shlex.quote(str(value)) for key, value in paths.items()}
    preinstall = f'''#!/bin/sh
set -eu
# Installer argument 3 is the target volume, not the invoking user's home.
if [ "${{3:-}}" != / ]; then
    echo "Pichi Voice can only be installed on the startup volume (/)." >&2
    exit 1
fi
if [ "$({c['id']} -u)" != 0 ]; then
    echo "Pichi Voice must be installed by macOS Installer with administrator authorization." >&2
    exit 1
fi
status=0
{c['pgrep']} -x 'Pichi Voice' >/dev/null 2>&1 || status=$?
case "$status" in
    1) exit 0 ;;
    0) echo "Quit Pichi Voice and run the installer again. / Завершите Pichi Voice и повторите установку." >&2 ;;
    *) echo "Could not check whether Pichi Voice is running. Installation stopped." >&2 ;;
esac
# Never terminate an app or touch preferences, recordings, models or onboarding.
exit 1
'''
    postinstall = f'''#!/bin/sh
set -eu
# A failed or unavailable GUI launch must never turn a successful install into a failure.
[ "${{3:-}}" = / ] || exit 0
console_user=$({c['stat']} -f %Su /dev/console 2>/dev/null) || exit 0
case "$console_user" in
    ''|root|loginwindow|_*|-*|*[!a-zA-Z0-9._-]*) exit 0 ;;
esac
console_uid=$({c['id']} -u "$console_user" 2>/dev/null) || exit 0
case "$console_uid" in
    ''|*[!0-9]*) exit 0 ;;
esac
# Standard interactive accounts have UIDs >= 501; exclude system/service users.
[ "$console_uid" -ge 501 ] || exit 0
if ! {c['launchctl']} asuser "$console_uid" {c['sudo']} -H -u "$console_user" -- {c['open']} '{INSTALL_PATH}'; then
    echo "Pichi Voice is installed. Open it from Applications to continue setup." >&2
fi
exit 0
'''
    return {"preinstall": preinstall, "postinstall": postinstall}


def draw_background(output, icon=ICON, dark=False):
    """Decorative left rail only; all instructions remain accessible HTML/native UI."""
    from PIL import Image, ImageDraw

    scale = 2
    image = Image.new("RGBA", (620 * scale, 418 * scale), "#211b2e" if dark else "#fff9ef")
    draw = ImageDraw.Draw(image)
    # Leave the native step list unobstructed and readable in both appearances.
    draw.rectangle((0, 282 * scale, 160 * scale, 418 * scale), fill="#6749c1")
    draw.rounded_rectangle((24 * scale, 294 * scale, 136 * scale, 406 * scale),
                           radius=24 * scale, fill="#fff9ef")
    with Image.open(icon) as source:
        mark = source.convert("RGBA")
        mark.thumbnail((92 * scale, 92 * scale), Image.Resampling.LANCZOS)
        image.alpha_composite(mark, ((160 * scale - mark.width) // 2,
                                     304 * scale + (92 * scale - mark.height) // 2))
    # TIFF/PNG DPI lets Installer display a crisp 2x resource at its logical size.
    image.convert("RGB").save(output, dpi=(144, 144))


def prepare_resources(destination, unsigned_preview):
    shutil.copytree(RESOURCES, destination)
    draw_background(destination / "background.png")
    draw_background(destination / "background-darkAqua.png", dark=True)
    # English is also the fallback for languages without a translation.
    for name in ("welcome.html", "conclusion.html"):
        for language in ("en", "ru"):
            path = destination / f"{language}.lproj" / name
            notice = ("<p><strong>PRIVATE PREVIEW - unsigned, for review only.</strong></p>"
                      if language == "en" else
                      "<p><strong>ЧАСТНЫЙ ПРЕДПРОСМОТР - без подписи, только для проверки.</strong></p>")
            path.write_text(path.read_text().replace("<!-- PREVIEW -->", notice if unsigned_preview else ""))
        shutil.copyfile(destination / "en.lproj" / name, destination / name)


def distribution_xml(info, architectures, unsigned_preview=False):
    root = ET.Element("installer-gui-script", {"minSpecVersion": "2"})
    ET.SubElement(root, "title").text = "Pichi Voice" + (" - PRIVATE PREVIEW" if unsigned_preview else "")
    ET.SubElement(root, "options", {"customize": "never", "require-scripts": "true",
                                   "rootVolumeOnly": "true", "hostArchitectures": ",".join(architectures)})
    ET.SubElement(root, "domains", {"enable_localSystem": "true", "enable_currentUserHome": "false",
                                   "enable_anywhere": "false"})
    ET.SubElement(root, "volume-check").append(ET.Element("allowed-os-versions"))
    ET.SubElement(root.find("volume-check/allowed-os-versions"), "os-version",
                  {"min": info["LSMinimumSystemVersion"]})
    for tag, filename in (("background", "background.png"), ("background-darkAqua", "background-darkAqua.png")):
        ET.SubElement(root, tag, {"file": filename, "alignment": "bottomleft", "scaling": "none"})
    for tag in ("welcome", "conclusion"):
        ET.SubElement(root, tag, {"file": f"{tag}.html", "mime-type": "text/html"})
    outline = ET.SubElement(root, "choices-outline")
    ET.SubElement(outline, "line", {"choice": "pichi"})
    choice = ET.SubElement(root, "choice", {"id": "pichi", "visible": "false", "title": "Pichi Voice"})
    ET.SubElement(choice, "pkg-ref", {"id": IDENTIFIER})
    ET.SubElement(root, "pkg-ref", {"id": IDENTIFIER, "version": info["CFBundleVersion"],
                                   "onConclusion": "none"}).text = COMPONENT
    ET.indent(root)
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


def configure_components(components):
    """Preserve pkgbuild's bundle analysis while prohibiting relocation."""
    for component in components:
        component.update(BundleIsRelocatable=False, BundleIsVersionChecked=True,
                         BundleHasStrictIdentifier=True, BundleOverwriteAction="upgrade")
        configure_components(component.get("ChildBundles", []))


def run(command):
    return subprocess.run([str(value) for value in command], check=True, capture_output=True, text=True)


def build(app, output, *, sign=None, unsigned_preview=False):
    if unsigned_preview:
        if sign:
            raise ValueError("Choose signing or PRIVATE unsigned preview, not both")
    elif not sign or not sign.startswith("Developer ID Installer:") or not sign.endswith(f"({TEAM})"):
        raise ValueError(f"Production requires a Developer ID Installer identity for {TEAM}")
    app, output, info = dmg.validate_input(app, output, TEAM, output_suffix=".pkg")
    for key in ("CFBundleVersion", "LSMinimumSystemVersion"):
        if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", info.get(key, "")):
            raise ValueError(f"Invalid or missing {key}")
    if info.get("CFBundleExecutable") != "Pichi Voice":
        raise ValueError("Expected Pichi Voice executable for the running-app guard")
    architectures = run(["/usr/bin/lipo", "-archs", app / "Contents/MacOS/Pichi Voice"]).stdout.split()
    if not architectures or set(architectures) - {"arm64", "x86_64"}:
        raise ValueError("Expected an arm64 and/or x86_64 Mac app")
    # Keep the only payload in a fresh root. No home directories or working tree files.
    with tempfile.TemporaryDirectory(prefix="pichi-voice-pkg-") as directory:
        work = Path(directory)
        payload = work / "root"
        payload.mkdir()
        run(["/usr/bin/ditto", app, payload / APP_NAME])
        components_path = work / "components.plist"
        run(["/usr/bin/pkgbuild", "--analyze", "--root", payload, components_path])
        components = plistlib.loads(components_path.read_bytes())
        if not any(c.get("RootRelativeBundlePath") == APP_NAME for c in components):
            raise ValueError("pkgbuild did not recognize the app bundle")
        configure_components(components)
        components_path.write_bytes(plistlib.dumps(components))
        scripts = work / "scripts"
        scripts.mkdir()
        for name, source in installer_scripts().items():
            path = scripts / name
            path.write_text(source)
            path.chmod(0o755)
        resources = work / "Resources"
        prepare_resources(resources, unsigned_preview)
        distribution = work / "Distribution.xml"
        distribution.write_bytes(distribution_xml(info, architectures, unsigned_preview))
        try:
            run(["/usr/bin/pkgbuild", "--root", payload, "--component-plist", components_path,
                 "--scripts", scripts, "--identifier", IDENTIFIER, "--version", info["CFBundleVersion"],
                 "--install-location", "/Applications", "--ownership", "recommended", work / COMPONENT])
            command = ["/usr/bin/productbuild", "--distribution", distribution,
                       "--resources", resources, "--package-path", work]
            if sign:
                command += ["--sign", sign, "--timestamp"]
            run(command + [output])
            if sign:
                run(["/usr/sbin/pkgutil", "--check-signature", output])
        except BaseException:
            output.unlink(missing_ok=True)
            raise
    return info


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True)
    parser.add_argument("--output", required=True)
    signing = parser.add_mutually_exclusive_group(required=True)
    signing.add_argument("--sign", help="Developer ID Installer identity (never an Application certificate)")
    signing.add_argument("--unsigned-preview", action="store_true", help="PRIVATE review only; not distributable")
    args = parser.parse_args()
    info = build(args.app, args.output, sign=args.sign, unsigned_preview=args.unsigned_preview)
    label = "PRIVATE UNSIGNED PREVIEW" if args.unsigned_preview else "Signed installer (not yet notarized)"
    print(f"{label}: {info['CFBundleShortVersionString']} ({info['CFBundleVersion']}) at {args.output}")


if __name__ == "__main__":
    main()
