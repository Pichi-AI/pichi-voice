"""Offline PKG contracts, executed installer scripts, and native archive round trip.

All apps/accounts are synthetic. Never invokes installer, real sudo, launchctl,
open, signing identities, network services or a user's installed app.
"""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("macos_pkg", ROOT / "scripts/dev/package-macos-pkg.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
SIGNATURE = "Authority=Developer ID Application: Example\nTeamIdentifier=LU46F7HGJM\nTimestamp=now\nflags=runtime\n"
INSTALLER_ID = "Developer ID Installer: Example (LU46F7HGJM)"


class InstallerScriptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pichi-pkg-script-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.log = self.root / "commands.jsonl"
        # Stand-ins execute the full launchctl -> sudo -> open argument chain.
        # Any accidental command, option or unexpected target fails the test.
        self.stub = self.root / "command stub.py"
        self.stub.write_text("#!" + sys.executable + '''
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["COMMAND_LOG"], "a") as log:
    log.write(json.dumps([name, args]) + "\\n")
if name == "id":
    assert args in (["-u"], ["-u", "alex"]), args
    print(os.environ.get("EFFECTIVE_UID", "0") if len(args) == 1 else os.environ.get("CONSOLE_UID", "501"))
    sys.exit(int(os.environ.get("ID_STATUS", "0")))
if name == "pgrep":
    assert args == ["-x", "Pichi Voice"], args
    sys.exit(int(os.environ.get("PGREP_STATUS", "1")))
if name == "stat":
    assert args == ["-f", "%Su", "/dev/console"], args
    print(os.environ.get("CONSOLE_USER", "alex"))
    sys.exit(int(os.environ.get("STAT_STATUS", "0")))
if name == "launchctl":
    assert args[:2] == ["asuser", os.environ.get("CONSOLE_UID", "501")], args
    if os.environ.get("LAUNCH_FAIL"):
        sys.exit(1)
    os.execv(args[2], args[2:])
if name == "sudo":
    assert args[:5] == ["-H", "-u", "alex", "--", os.environ["OPEN_STUB"]], args
    os.execv(args[4], args[4:])
if name == "open":
    assert args == ["/Applications/Pichi Voice.app"], args
    sys.exit(int(os.environ.get("OPEN_STATUS", "0")))
raise AssertionError(name)
''')
        self.stub.chmod(0o755)
        self.commands = {}
        for name in ("id", "pgrep", "stat", "launchctl", "sudo", "open"):
            path = self.root / name
            path.symlink_to(self.stub)
            self.commands[name] = path
        for name, source in module.installer_scripts(self.commands).items():
            path = self.root / name
            path.write_text(source)
            path.chmod(0o755)

    def execute(self, script, target="/", **changes):
        self.log.unlink(missing_ok=True)
        env = {"PATH": "/usr/bin:/bin", "COMMAND_LOG": str(self.log),
               "OPEN_STUB": str(self.commands["open"]), **changes}
        result = subprocess.run(["/bin/sh", str(self.root / script), "package.pkg", "/Applications", target],
                                env=env, capture_output=True, text=True, timeout=10)
        self.calls = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        return result

    def test_preinstall_allows_stopped_app_on_startup_volume(self):
        self.assertEqual(self.execute("preinstall").returncode, 0)
        self.assertEqual([name for name, _ in self.calls], ["id", "pgrep"])

    def test_running_app_is_rejected_without_kill_or_launch(self):
        result = self.execute("preinstall", PGREP_STATUS="0")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Quit Pichi Voice", result.stderr)
        self.assertEqual([name for name, _ in self.calls], ["id", "pgrep"])

    def test_process_check_failure_is_closed(self):
        result = self.execute("preinstall", PGREP_STATUS="2")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Could not check", result.stderr)

    def test_nonroot_volume_and_missing_target_are_rejected_before_commands(self):
        for target in ("/Volumes/Other", "", "/Users/alex", "/Volumes/Other;touch unsafe"):
            with self.subTest(target=target):
                self.assertEqual(self.execute("preinstall", target).returncode, 1)
                self.assertEqual(self.calls, [])

    def test_preinstall_requires_administrator_execution(self):
        self.assertEqual(self.execute("preinstall", EFFECTIVE_UID="501").returncode, 1)
        self.assertEqual([name for name, _ in self.calls], ["id"])

    def test_postinstall_launches_exact_app_with_console_context_and_credentials(self):
        self.assertEqual(self.execute("postinstall").returncode, 0)
        self.assertEqual(self.calls, [
            ["stat", ["-f", "%Su", "/dev/console"]], ["id", ["-u", "alex"]],
            ["launchctl", ["asuser", "501", str(self.commands["sudo"]), "-H", "-u", "alex", "--",
                           str(self.commands["open"]), "/Applications/Pichi Voice.app"]],
            ["sudo", ["-H", "-u", "alex", "--", str(self.commands["open"]), "/Applications/Pichi Voice.app"]],
            ["open", ["/Applications/Pichi Voice.app"]],
        ])

    def test_absent_root_loginwindow_or_unsafe_console_user_never_launches(self):
        for user in ("", "root", "loginwindow", "_mbsetupuser", "_daemon", "-alex", "alex\nroot", "alex;touch unsafe"):
            with self.subTest(user=user):
                self.assertEqual(self.execute("postinstall", CONSOLE_USER=user).returncode, 0)
                self.assertEqual([name for name, _ in self.calls], ["stat"])

    def test_console_uid_is_resolved_for_the_actual_user(self):
        self.assertEqual(self.execute("postinstall", CONSOLE_UID="502").returncode, 0)
        launch = next(args for name, args in self.calls if name == "launchctl")
        self.assertEqual(launch[:2], ["asuser", "502"])
        self.assertEqual(self.calls[-1], ["open", ["/Applications/Pichi Voice.app"]])

    def test_unresolved_console_and_invalid_or_system_uid_never_launch(self):
        for changes in ({"STAT_STATUS": "1"}, {"ID_STATUS": "1"}, {"CONSOLE_UID": "0"},
                        {"CONSOLE_UID": "500"}, {"CONSOLE_UID": ""}, {"CONSOLE_UID": "oops"},
                        {"CONSOLE_UID": "501;touch unsafe"}):
            with self.subTest(changes=changes):
                self.assertEqual(self.execute("postinstall", **changes).returncode, 0)
                self.assertFalse({name for name, _ in self.calls} & {"launchctl", "sudo", "open"})

    def test_postinstall_skips_other_volumes(self):
        self.assertEqual(self.execute("postinstall", "/Volumes/Other").returncode, 0)
        self.assertEqual(self.calls, [])

    def test_failed_launch_is_nonfatal(self):
        for changes in ({"OPEN_STATUS": "1"}, {"LAUNCH_FAIL": "1"}):
            with self.subTest(changes=changes):
                result = self.execute("postinstall", **changes)
                self.assertEqual(result.returncode, 0)
                self.assertIn("Open it from Applications", result.stderr)
                self.assertIn("launchctl", [name for name, _ in self.calls])

    def test_production_scripts_parse_and_have_fixed_command_paths(self):
        for name, source in module.installer_scripts().items():
            path = self.root / (name + "-production")
            path.write_text(source)
            subprocess.run(["/bin/sh", "-n", path], check=True)
        with self.assertRaises(ValueError):
            module.installer_scripts({"kill": "/fake"})


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pichi-pkg-build-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / "Frozen.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        self.info = {"CFBundleIdentifier": "ai.pichi.voice", "CFBundleShortVersionString": "0.1.0",
                     "CFBundleVersion": "66", "CFBundleExecutable": "Pichi Voice", "LSMinimumSystemVersion": "15.0",
                     "CFBundlePackageType": "APPL"}
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(self.info))
        binary = self.app / "Contents/MacOS/Pichi Voice"
        binary.write_text("#!/bin/sh\nexit 0\n")
        binary.chmod(0o755)
        (self.app / "Contents/current").symlink_to("MacOS/Pichi Voice")
        (self.app / "Contents/.synthetic-resource").write_text("approved synthetic hidden bundle resource\n")
        self.output = self.root / "Preview.pkg"
        self.commands = []
        self.work = None

    def trust(self, command, **kwargs):
        return subprocess.CompletedProcess(command, 0, "", SIGNATURE)

    def packaging_command(self, command):
        command = [str(arg) for arg in command]
        self.commands.append(command)
        tool = Path(command[0]).name
        if tool == "lipo":
            return subprocess.CompletedProcess(command, 0, "arm64\n", "")
        if tool == "ditto":
            shutil.copytree(command[1], command[2], symlinks=True)
        elif tool == "pkgbuild" and "--analyze" in command:
            Path(command[-1]).write_bytes(plistlib.dumps([{"RootRelativeBundlePath": "Pichi Voice.app",
                "ChildBundles": [{"RootRelativeBundlePath": "Pichi Voice.app/Contents/Frameworks/Example.framework"}]}]))
        elif tool == "pkgbuild":
            root = Path(command[command.index("--root") + 1])
            self.work = root.parent
            self.assertEqual([p.name for p in root.iterdir()], ["Pichi Voice.app"])
            self.assertEqual((root / "Pichi Voice.app/Contents/MacOS/Pichi Voice").read_bytes(),
                             (self.app / "Contents/MacOS/Pichi Voice").read_bytes())
            self.assertEqual(os.readlink(root / "Pichi Voice.app/Contents/current"), "MacOS/Pichi Voice")
            components = plistlib.loads((self.work / "components.plist").read_bytes())
            for c in (components[0], components[0]["ChildBundles"][0]):
                self.assertFalse(c["BundleIsRelocatable"])
                self.assertTrue(c["BundleIsVersionChecked"])
                self.assertTrue(c["BundleHasStrictIdentifier"])
                self.assertEqual(c["BundleOverwriteAction"], "upgrade")
            self.assertEqual(command[command.index("--install-location") + 1], "/Applications")
            self.assertEqual(command[command.index("--ownership") + 1], "recommended")
            for name, source in module.installer_scripts().items():
                self.assertEqual((self.work / "scripts" / name).read_text(), source)
                self.assertEqual((self.work / "scripts" / name).stat().st_mode & 0o777, 0o755)
            Path(command[-1]).write_bytes(b"component")
        elif tool == "productbuild":
            dist = ET.parse(command[command.index("--distribution") + 1]).getroot()
            self.check_distribution(dist)
            self.assertTrue((self.work / "Resources/background.png").is_file())
            Path(command[-1]).write_bytes(b"synthetic product")
        elif tool != "pkgutil":
            self.fail(f"Unexpected command: {command}")
        return subprocess.CompletedProcess(command, 0, "", "")

    def check_distribution(self, dist):
        self.assertEqual(dist.tag, "installer-gui-script")
        self.assertEqual(dist.find("domains").attrib, {"enable_localSystem": "true", "enable_currentUserHome": "false",
                                                     "enable_anywhere": "false"})
        self.assertEqual(dist.find("options").get("customize"), "never")
        self.assertEqual(dist.find("options").get("require-scripts"), "true")
        self.assertEqual(dist.find("options").get("rootVolumeOnly"), "true")
        self.assertEqual(dist.find("options").get("hostArchitectures"), "arm64")
        self.assertEqual(dist.find("volume-check/allowed-os-versions/os-version").get("min"), "15.0")
        refs = [ref for ref in dist.findall("pkg-ref") if (ref.text or "").strip()]
        # productbuild embeds references with '#' and adds bundle-version metadata.
        self.assertEqual([(ref.get("id"), ref.get("version"), ref.text.strip().removeprefix("#")) for ref in refs],
                         [(module.IDENTIFIER, "66", module.COMPONENT)])
        for name in ("welcome", "conclusion"):
            self.assertEqual(dist.find(name).get("file"), f"{name}.html")

    def test_build_composes_trusted_app_scripts_localization_and_private_preview(self):
        original = (self.app / "Contents/Info.plist").read_bytes()
        with patch.object(module.dmg.subprocess, "run", side_effect=self.trust) as trust, \
                patch.object(module, "run", side_effect=self.packaging_command):
            self.assertEqual(module.build(self.app, self.output, unsigned_preview=True), self.info)
        self.assertEqual([c.args[0][0] for c in trust.call_args_list], ["codesign", "xcrun", "spctl", "codesign"])
        self.assertNotIn("--sign", self.commands[-1])
        self.assertEqual(self.output.read_bytes(), b"synthetic product")
        self.assertEqual((self.app / "Contents/Info.plist").read_bytes(), original)
        self.assertFalse(self.work.exists())

    def test_production_uses_installer_identity_and_timestamp_then_checks_signature(self):
        with patch.object(module.dmg.subprocess, "run", side_effect=self.trust), \
                patch.object(module, "run", side_effect=self.packaging_command):
            module.build(self.app, self.output, sign=INSTALLER_ID)
        product = next(c for c in self.commands if Path(c[0]).name == "productbuild")
        self.assertEqual(product[product.index("--sign") + 1], INSTALLER_ID)
        self.assertIn("--timestamp", product)
        self.assertEqual(self.commands[-1], ["/usr/sbin/pkgutil", "--check-signature", str(self.output.resolve())])

    def test_no_implicit_unsigned_build_or_application_certificate(self):
        for sign, preview in ((None, False), ("Developer ID Application: Example (LU46F7HGJM)", False),
                              ("Developer ID Installer: Example (WRONG)", False), (INSTALLER_ID, True)):
            with self.subTest(sign=sign, preview=preview), patch.object(module, "run") as run:
                with self.assertRaises(ValueError):
                    module.build(self.app, self.output, sign=sign, unsigned_preview=preview)
                run.assert_not_called()

    def test_pkg_validation_rejects_wrong_suffix_existing_output_nested_output_or_alias(self):
        self.output.write_bytes(b"preserve")
        alias = self.root / "Alias.app"
        alias.symlink_to(self.app)
        for app, output in ((self.app, self.output), (self.app, self.root / "bad.dmg"),
                            (self.app, self.app / "nested.pkg"), (alias, self.root / "new.pkg")):
            with self.subTest(app=app, output=output), self.assertRaises(ValueError):
                module.build(app, output, unsigned_preview=True)
        self.assertEqual(self.output.read_bytes(), b"preserve")

    def test_failed_trust_checks_do_not_start_packaging(self):
        for command in ("codesign", "xcrun", "spctl"):
            def reject(args, **kwargs):
                if args[0] == command:
                    raise subprocess.CalledProcessError(1, args)
                return self.trust(args, **kwargs)
            with self.subTest(command=command), patch.object(module.dmg.subprocess, "run", side_effect=reject), \
                    patch.object(module, "run") as run, self.assertRaises(subprocess.CalledProcessError):
                module.build(self.app, self.output, unsigned_preview=True)
            run.assert_not_called()
        with patch.object(module.dmg.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", SIGNATURE.replace("LU46F7HGJM", "OTHER"))), \
                self.assertRaises(ValueError):
            module.build(self.app, self.output, unsigned_preview=True)

    def test_invalid_version_minimum_os_and_executable_are_rejected(self):
        for key, value in (("CFBundleVersion", "66;bad"), ("LSMinimumSystemVersion", ""),
                           ("CFBundleExecutable", "Other")):
            bad_info = {**self.info, key: value}
            with self.subTest(key=key), patch.object(module.dmg, "validate_input", return_value=(self.app, self.output, bad_info)), \
                    patch.object(module, "run") as run, self.assertRaises(ValueError):
                module.build(self.app, self.output, unsigned_preview=True)
            run.assert_not_called()

    def test_unsupported_architecture_is_rejected_before_staging(self):
        with patch.object(module.dmg.subprocess, "run", side_effect=self.trust), \
                patch.object(module, "run", return_value=subprocess.CompletedProcess([], 0, "i386", "")) as run, \
                self.assertRaises(ValueError):
            module.build(self.app, self.output, unsigned_preview=True)
        self.assertEqual(run.call_count, 1)

    def test_partial_output_and_staging_are_removed_on_failure(self):
        def fail(command):
            result = self.packaging_command(command)
            if Path(command[0]).name == "productbuild":
                raise subprocess.CalledProcessError(1, command)
            return result
        with patch.object(module.dmg.subprocess, "run", side_effect=self.trust), \
                patch.object(module, "run", side_effect=fail), self.assertRaises(subprocess.CalledProcessError):
            module.build(self.app, self.output, unsigned_preview=True)
        self.assertFalse(self.output.exists())
        self.assertFalse(self.work.exists())
        self.assertTrue(self.app.exists())

    def test_resources_use_real_icon_and_localized_accessible_text(self):
        from PIL import Image

        for preview in (False, True):
            resources = self.root / str(preview)
            module.prepare_resources(resources, preview)
            with Image.open(resources / "background.png") as background:
                self.assertEqual(background.size, (1240, 836))
                self.assertEqual(background.getpixel((0, 0)), (255, 249, 239))
                self.assertEqual(background.getpixel((0, 835)), (103, 73, 193))
                self.assertEqual(background.getpixel((1239, 0)), (255, 249, 239))
                # The rail contains the supplied genuine icon, not generated lettering.
                with Image.open(module.ICON) as icon:
                    mark = icon.convert("RGBA")
                    mark.thumbnail((184, 184), Image.Resampling.LANCZOS)
                    expected = Image.new("RGBA", mark.size, "#fff9ef")
                    expected.alpha_composite(mark)
                    x, y = (320 - mark.width) // 2, 608 + (184 - mark.height) // 2
                    self.assertEqual(background.crop((x, y, x + mark.width, y + mark.height)).tobytes(),
                                     expected.convert("RGB").tobytes())
            with Image.open(resources / "background-darkAqua.png") as background:
                self.assertEqual(background.getpixel((0, 0)), (33, 27, 46))
                self.assertEqual(background.getpixel((0, 835)), (103, 73, 193))
            for language in ("en", "ru"):
                for name in ("welcome", "conclusion"):
                    html = (resources / f"{language}.lproj/{name}.html").read_text()
                    self.assertIn(f'lang="{language}"', html)
                    self.assertIn("<h1>", html)
                    self.assertIn("Applications", html)
                    self.assertNotIn("<!-- PREVIEW -->", html)
                    self.assertNotIn("http", html)
                    self.assertEqual("PRIVATE PREVIEW" in html or "ЧАСТНЫЙ ПРЕДПРОСМОТР" in html, preview)
            self.assertEqual((resources / "welcome.html").read_bytes(), (resources / "en.lproj/welcome.html").read_bytes())

    @unittest.skipUnless(sys.platform == "darwin" and Path("/usr/bin/pkgbuild").exists(), "Requires Apple packaging tools")
    def test_native_unsigned_synthetic_archive_round_trip_without_installation(self):
        real_run = module.run
        def native(command):
            if Path(command[0]).name == "lipo":
                return subprocess.CompletedProcess(command, 0, "arm64", "")
            return real_run(command)
        with patch.object(module.dmg, "validate_input", return_value=(self.app, self.output, self.info)), \
                patch.object(module, "run", side_effect=native):
            module.build(self.app, self.output, unsigned_preview=True)
        expanded = self.root / "expanded"
        subprocess.run(["/usr/sbin/pkgutil", "--expand-full", self.output, expanded], check=True, capture_output=True)
        self.check_distribution(ET.parse(expanded / "Distribution").getroot())
        self.assertIn("PRIVATE PREVIEW", (expanded / "Distribution").read_text())
        package = expanded / module.COMPONENT
        package_info = ET.parse(package / "PackageInfo").getroot()
        self.assertEqual(package_info.get("install-location"), "/Applications")
        self.assertEqual(package_info.get("auth"), "root")
        payload = package / "Payload"
        self.assertEqual([p.name for p in payload.iterdir()], ["Pichi Voice.app"])
        actual = payload / "Pichi Voice.app"
        expected_files = sorted(str(p.relative_to(self.app)) for p in self.app.rglob("*"))
        self.assertEqual(sorted(str(p.relative_to(actual)) for p in actual.rglob("*")), expected_files)
        for source in self.app.rglob("*"):
            target = actual / source.relative_to(self.app)
            if source.is_symlink():
                self.assertEqual(os.readlink(target), os.readlink(source))
            elif source.is_file():
                self.assertEqual(target.read_bytes(), source.read_bytes())
                self.assertEqual(target.stat().st_mode & 0o777, source.stat().st_mode & 0o777)
        for name, source in module.installer_scripts().items():
            self.assertEqual((package / "Scripts" / name).read_text(), source)
        for language in ("en", "ru"):
            self.assertTrue((expanded / f"Resources/{language}.lproj/welcome.html").exists())
            self.assertTrue((expanded / f"Resources/{language}.lproj/conclusion.html").exists())


if __name__ == "__main__":
    unittest.main()
