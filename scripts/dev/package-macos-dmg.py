#!/usr/bin/env python3
"""Package an already notarized app as a standard drag-install disk image.

Requires dmgbuild==1.6.7 and Pillow==12.2.0 on macOS. Does not install,
launch, re-sign or modify the input application.
"""

import argparse
from pathlib import Path
import plistlib
import subprocess
import tempfile


def validate_input(app, output, team, output_suffix=".dmg"):
    app, output = Path(app).absolute(), Path(output).resolve()
    if app.is_symlink() or not app.is_dir() or app.suffix != ".app":
        raise ValueError("Input must be a real .app directory")
    if output.exists() or output.is_symlink():
        raise ValueError("Output already exists")
    if output.suffix != output_suffix or output.is_relative_to(app.resolve()):
        raise ValueError(f"Output must be a new {output_suffix} outside the input app")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "ai.pichi.voice":
        raise ValueError("Expected the Pichi Voice distribution identity")
    for command in [
        ["codesign", "--verify", "--deep", "--strict", str(app)],
        ["xcrun", "stapler", "validate", str(app)],
        ["spctl", "--assess", "--type", "execute", str(app)],
    ]:
        subprocess.run(command, check=True, capture_output=True)
    result = subprocess.run(
        ["codesign", "-dvvv", str(app)], check=True, capture_output=True, text=True
    ).stderr
    if (f"TeamIdentifier={team}\n" not in result or
            "Authority=Developer ID Application:" not in result or
            "Timestamp=" not in result or "runtime" not in result):
        raise ValueError("Expected a timestamped hardened Developer ID app")
    return app, output, info


def image_settings(app, background):
    return {
        "format": "UDZO", "filesystem": "HFS+",
        "files": [str(app)], "symlinks": {"Applications": "/Applications"},
        "background": str(background),
        "icon_locations": {app.name: (160, 205), "Applications": (480, 205)},
        # Hiding the app extension writes FinderInfo onto the signed bundle.
        # Keep bundle metadata unchanged so strict signature verification passes.
        "hide_extensions": [], "window_rect": ((150, 150), (640, 420)),
        "default_view": "icon-view", "icon_size": 96, "text_size": 13,
        "show_status_bar": False, "show_tab_view": False,
        "show_toolbar": False, "show_pathbar": False, "show_sidebar": False,
    }


def draw_background(path):
    from PIL import Image, ImageDraw, ImageFont

    scale = 2
    image = Image.new("RGB", (640 * scale, 420 * scale), "#f8f6fc")
    draw = ImageDraw.Draw(image)
    font_root = Path("/System/Library/Fonts/Supplemental")

    def text(y, value, size, color, bold=False):
        font = ImageFont.truetype(str(font_root / ("Arial Bold.ttf" if bold else "Arial.ttf")), size * scale)
        draw.text((320 * scale, y * scale), value, font=font, fill=color, anchor="mt")

    text(30, "Pichi Voice", 29, "#6749c1", True)
    text(79, "Drag to Applications to install", 18, "#201a2f")
    text(106, "Перетащите приложение в Applications", 14, "#766d83")
    draw.line([(280 * scale, 205 * scale), (360 * scale, 205 * scale)], fill="#6749c1", width=5 * scale)
    draw.line([(345 * scale, 191 * scale), (360 * scale, 205 * scale), (345 * scale, 219 * scale)], fill="#6749c1", width=5 * scale)
    text(307, "Then open Pichi Voice from Applications", 15, "#201a2f")
    text(335, "Откройте приложение и пройдите первоначальную настройку", 13, "#766d83")
    text(389, "pichi.ai/voice", 12, "#6749c1")
    image.resize((640, 420), Image.Resampling.LANCZOS).save(path)
    image.save(path.with_name(path.stem + "@2x.png"))


def build(app, output, team="LU46F7HGJM", builder=None):
    app, output, info = validate_input(app, output, team)
    if builder is None:
        import dmgbuild
        builder = dmgbuild.build_dmg
    with tempfile.TemporaryDirectory(prefix="pichi-voice-dmg-") as directory:
        background = Path(directory) / "background.png"
        draw_background(background)
        try:
            builder(str(output), "Pichi Voice", settings=image_settings(app, background))
            subprocess.run(["hdiutil", "verify", str(output)], check=True, capture_output=True)
        except BaseException:
            output.unlink(missing_ok=True)
            raise
    return info


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    info = build(args.app, args.output)
    print(f"Created disk image for {info['CFBundleShortVersionString']} ({info['CFBundleVersion']})")


if __name__ == "__main__":
    main()
