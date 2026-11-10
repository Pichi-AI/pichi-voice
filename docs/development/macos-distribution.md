# macOS distribution

The primary Mac download is a standard drag-install DMG. Open the image, drag
Pichi Voice to Applications, and open the app. The Finder layout uses a quiet
light background, Pichi colors, the genuine app icon and the standard
Applications icon. There is no separate Installer wizard or installation script.
macOS controls access to the destination folder; do not promise that every
machine can write to Applications without authorization.

The app's existing onboarding owns permissions, local model setup and
configuration. Packaging never resets onboarding or settings, writes user data,
downloads models, or adds credentials to the payload. Existing installations can
replay setup through Help > Replay onboarding without deleting their data or
resetting macOS permissions. Keep a verified backup before reinstall acceptance.

A signed PKG remains an optional distribution format. It requires administrator
authorization and uses the native Installer steps. Its resources and scripts
remain maintained below for that separate use case.

## Create an optional PKG

Start with the frozen Developer ID Application-signed, notarized and stapled
app. Do not rebuild, re-sign or modify it merely to change the download
container. The tool reuses the DMG validator for bundle identity, team,
timestamp, hardened runtime, strict deep signature, stapled ticket and
Gatekeeper assessment. Apple `pkgbuild`, `productbuild`, `lipo` and `ditto` are
required on macOS; resource generation also requires Pillow.

```sh
# Use an existing environment with Pillow, or prepare one separately.
python3 scripts/dev/package-macos-pkg.py \
  --app '/absolute/path/Pichi Voice.app' \
  --output '/absolute/path/Pichi-Voice-macos-arm64.pkg' \
  --sign 'Developer ID Installer: Organization (LU46F7HGJM)'
python3 -m unittest discover -s Tests -p 'test_macos_*_packaging.py' -v
```

Production requires a **Developer ID Installer** identity for the distribution
team. A Developer ID Application certificate cannot sign a PKG. The outer
product archive is signed with a timestamp and checked with `pkgutil`; the
component package needs no separate signature. Signing may contact Apple's
timestamp service. Submit the signed outer PKG to Apple's notary service,
staple its ticket and validate that ticket before publication. The app's existing
notarization does not establish notarization of the outer PKG.

For private review when an Installer identity is unavailable:

```sh
python3 scripts/dev/package-macos-pkg.py \
  --app '/absolute/path/Pichi Voice.app' \
  --output "$PWD/.build/Pichi-Voice-Installer-preview.pkg" \
  --unsigned-preview
```

The explicit preview mode labels the native title and localized pages as a
private unsigned preview. It retains all app trust checks. It must never be
published or presented as a signed/notarized installer. The helper refuses an
existing output and removes partial output and its temporary staging root on
failure. It never runs Installer, installs the payload or launches an app while
building.

### Installation contract

Only the startup volume's system domain is enabled; home and alternate-volume
installation and component customization are disabled. The app's minimum macOS
version and binary architectures drive the Distribution requirements. A fresh
payload root contains only the frozen app under its canonical name. Bundle
analysis disables relocation, requires matching bundle identifiers and version
checking, and uses atomic bundle replacement. Existing preferences, recordings,
model files and completed onboarding outside the bundle stay in place.

The preinstall script rejects a non-root target volume, non-administrator
execution, a running `Pichi Voice` process, or a failed process check. It asks the
user to quit the app and never kills it. There is no launch agent or persistent
helper. After installation, postinstall resolves `/dev/console` and a valid
interactive UID (501 or higher), then runs:

```sh
/bin/launchctl asuser "$console_uid" /usr/bin/sudo -H -u "$console_user" -- \
  /usr/bin/open '/Applications/Pichi Voice.app'
```

`launchctl asuser` supplies the GUI bootstrap context; `sudo -u` supplies user
credentials. The app is never opened as root. Loginwindow, root, setup/system
accounts, missing/invalid users and alternate volumes are skipped. A failed
launch is nonfatal; the conclusion explains how to open the app manually.

### Offline verification and native acceptance

The focused Python suite executes the actual generated shell scripts using
deterministic command substitutions at generation time. It covers active-app
rejection, target-volume restrictions, console-user skips, the full launch
argument chain and nonfatal launch failure. Production scripts always use
absolute command paths and ignore environment command overrides. Build tests
cover trust admission, signing policy, component configuration, localized
resources, source preservation and cleanup. On macOS, a synthetic app is also
packaged and expanded with Apple's real tools, without installation or launch.

Expand a candidate into a new, task-owned scratch directory with
`pkgutil --expand-full`. Inspect Distribution, PackageInfo, scripts and EN/RU
resources. Compare every payload path, file hash, executable mode and symlink
against the frozen input, including hidden paths. The only payload root entry
must be `Pichi Voice.app`, installed at `/Applications`; no home directories,
private keys, passwords, models or user data may accompany it. Remove expanded
scratch after preserving the verification result.

Inspect welcome and conclusion in the actual Installer in English/Russian and
light/dark appearance, with keyboard and VoiceOver access. Do not click Install
on a user's existing installation for packaging verification. Authorized native
installation and first-run acceptance in an isolated environment, plus outer
PKG signing/notarization, remain separate release checks. Archive inspection and
offline script tests do not establish those outcomes.

## Create the primary disk image

Start with the frozen Developer ID-signed, notarized and stapled app. Do not
rebuild or re-sign it merely to change the download container.

```sh
python3 -m venv .build/dmg-tool
.build/dmg-tool/bin/python -m pip install dmgbuild==1.6.7 Pillow==12.2.0
.build/dmg-tool/bin/python scripts/dev/package-macos-dmg.py \
  --app '/absolute/path/Pichi Voice.app' \
  --output '/absolute/path/Pichi-Voice-macos-arm64.dmg'
python3 -m unittest discover -s Tests -p test_macos_dmg_packaging.py
```

The helper verifies bundle ID, Developer ID team, timestamp, hardened runtime,
deep signature, stapled ticket and Gatekeeper assessment before packaging. It
refuses an existing output, generates a bilingual Retina background, and checks
the finished image with `hdiutil`. It uses
[dmgbuild](https://github.com/dmgbuild/dmgbuild) to configure the Finder layout
without scripting Finder. Dependencies and generated images stay outside Git.

The signed app's file data and metadata must remain unchanged. Do not set
`hide_extensions` for the app: dmgbuild writes FinderInfo onto the bundle,
causing strict signature verification to reject it. Store the window arrangement
in the disk image's own `.DS_Store` instead.

### Verify the optional DMG

Mount the image read-only, confirm the Applications link targets `/Applications`,
and compare every app file, executable mode and symlink with the frozen input.
Copy the app into an isolated verification directory and repeat deep signature,
stapler and Gatekeeper checks on mounted and copied bundles. Do not replace or
launch the user's existing installation for packaging verification.

Inspect the actual Finder window, including background and icon positions.
Unmount task-owned images, then verify the published download's digest. Keep
exact corresponding source and license notices beside the download. Describe
the contained app as notarized; do not imply that the outer image was separately
notarized when only the app was submitted.

Release copy shows the available macOS download and `Coming Soon` for unavailable
platforms. Internal submission and testing status belongs to release records.

## Apple tool references

Read the local `pkgbuild(1)`, `productbuild(1)`, `pkgutil(1)`, `launchctl(1)` and
`sudo(8)` manuals for packaging, expansion and execution contracts. Distribution
XML uses Apple's [Distribution Definition XML Reference](https://developer.apple.com/library/archive/documentation/DeveloperTools/Reference/DistributionDefinitionRef/Chapters/Distribution_XML.html).
Keep exact corresponding source and GPL/license notices with any public download.
