# macOS disk-image distribution

The public Mac download uses a standard drag-install DMG. Opening the image
shows Pichi Voice beside an Applications shortcut. The user drags the app into
Applications and opens it there. The existing first-open onboarding owns
permissions, local model setup and configuration. Packaging must not reset
onboarding or settings on an existing installation.

## Create a disk image

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

## Verify before publication

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
