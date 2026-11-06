# Mobile TestFlight packaging

Use an isolated worktree, a pinned source revision and private build directories. The archive and export must use the tracked distribution resource; a local SSO test resource is not a remote distribution configuration. Preserve the privacy opt-in policy.

## Version and archive

`Sources/Mobile/Version.xcconfig` supplies shared app and Live Activity extension defaults. Override `CURRENT_PROJECT_VERSION` once on the archive command so both bundles receive the same unique build number. Verify the latest number in App Store Connect first. Supply `PICHI_MOBILE_BUNDLE_IDENTIFIER`, rather than globally overriding `PRODUCT_BUNDLE_IDENTIFIER`, because the extension has its own identifier.

The default mobile application identity is `ai.pichi.voice`, shared with the native macOS release through `Configuration/PichiBrand.xcconfig`. Live Activity extends that identity as `ai.pichi.voice.activity`. The signed mobile account configuration must match the application identifier; callback URLs and Keychain access groups derive from the actual installed bundle.

The earlier `ai.pichi.voice.mobile` TestFlight record and its builds retain their original identity. Apple does not allow changing a record's bundle ID after a build upload, so the unified identity needs its own suitable app record. Preserve the old installation and its local data. The new bundle is a separate installation with a separate sandbox and Keychain namespace, requiring fresh setup/login. Existing audio/transcript share operations can export content from the old app; copying encrypted profile directories alone does not migrate their device-only keys or restore complete history. A shared bundle ID across macOS and iOS does not itself synchronize user data. See [Apple app information](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/) and [adding platforms](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-platforms/).

Keep DerivedData and SourcePackages inside the current worktree. Set `PICHI_SOURCE_REVISION` to the pinned full SHA. Select an existing authorized signing identity and team; do not change entitlements or reset permissions. Run the regular Xcode archive operation before preparing an export copy.

## Prepare the ONNX metadata in an owned archive copy

The pinned ONNX 1.24.2 package supplies a static framework. Xcode 27 embeds a generated dynamic placeholder with a newer Mach-O minimum OS while retaining the package's older `MinimumOSVersion`. Apple processing rejects that mismatch with error 90208. An additional build phase that declares the same framework executable as an output conflicts with Xcode's automatic embed operation. Keep user script sandboxing enabled and prepare a separate archive copy after the archive completes.

Preserve the original archive. Copy it into a new task-owned `.xcarchive` path before changing metadata. The commands below run on that copy only. Set these values from the actual archive, existing identity and build evidence:

```bash
set -eu
# Set pichi_raw_archive, pichi_prepared_archive and pichi_signing_identity first.
# The destination must not exist. Both archives must belong to this task.
test ! -e "$pichi_prepared_archive"
cp -cR "$pichi_raw_archive" "$pichi_prepared_archive"
pichi_app_relative="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:ApplicationPath' "$pichi_prepared_archive/Info.plist")"
pichi_app="$pichi_prepared_archive/Products/$pichi_app_relative"

# Verify the copied archive signature and metadata before changing it.
codesign --verify --deep --strict "$pichi_app"
# The archive's app Info.plist, not a guessed device OS, supplies this minimum.
pichi_minimum_os="$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$pichi_app/Info.plist")"
TARGET_BUILD_DIR="$pichi_prepared_archive/Products" \
FRAMEWORKS_FOLDER_PATH="$pichi_app_relative/Frameworks" \
IPHONEOS_DEPLOYMENT_TARGET="$pichi_minimum_os" \
CODE_SIGNING_ALLOWED=YES \
EXPANDED_CODE_SIGN_IDENTITY="$pichi_signing_identity" \
python3 -B -S scripts/dev/mobile-framework-metadata.py normalize-onnx \
    "$pichi_app/Frameworks/onnxruntime.framework"

# The changed child invalidates its containing app's seal. Restore that seal
# with the same identity and all existing signing metadata before export.
codesign --force --sign "$pichi_signing_identity" \
    --preserve-metadata=identifier,entitlements,requirements,flags,runtime \
    --generate-entitlement-der "$pichi_app"
codesign --verify --deep --strict "$pichi_app"
python3 -B -S scripts/dev/mobile-framework-metadata.py check "$pichi_app"
```

The normalizer reads every Mach-O architecture, changes only the copied ONNX plist when its declared minimum is too low and signs the modified framework with the supplied existing identity. It rejects a runtime requiring a newer OS than the app. It never changes the binary's deployment target, model weights, SPM checkout, app entitlements or a running installation. A failed signing step is a failed preparation, including on retry.

Before export, independently verify the original archive is unchanged, every non-signature executable payload is unchanged, app and extension bundle IDs/versions/source revision match the pinned candidate, and their effective entitlements and team match the original. Preserve the original and prepared file hashes, commands and results outside any disposable worktree. A signature check alone does not prove payload equivalence.

A license-resource-only update may use a separate derived copy of a verified archive when all compiled source and native inputs are unchanged. Record the original archive, new source revision and exact allowed file delta. Compile any changed String Catalog with Xcode's `xcstringstool` and verify that existing localized values are unchanged. Update the app, extension and archive version metadata together, sign the extension before the app with the same valid identity and entitlements, and verify every unsigned Mach-O payload against the original. Treat this as resource-only packaging, not a fresh Xcode compilation. Validate the changed legal pages on the resulting frozen app before publication; any code, native input or build-setting change that affects compiled output requires a fresh build.

Use the normal App Store Connect export workflow on the prepared archive. Verify the exported app and extension signatures, equal version/build numbers, distribution profiles and framework metadata again. A successful export or upload is not Apple processing acceptance. Confirm a usable build in the live TestFlight page and tester access separately. Final readiness also requires simulator and physical acceptance of the combined application and a successful installation/rehearsal on the recipient's iPad.

Related upstream report: [Microsoft ONNX Runtime issue 27396](https://github.com/microsoft/onnxruntime/issues/27396).
