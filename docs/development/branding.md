# Pichi branding and white-label builds

The app retains FluidVoice's target, Swift type and resource names so upstream updates remain practical. User-visible app, meeting and AI feature names are provided by `AppBrand`; third-party model names and authors remain accurate.

## Appearance profiles

Settings > General includes System, Light and Dark appearance, preset accents and a Brand accent with separate light/dark values. Pichi uses the existing `pichi` repository's purple palette and vector mark, exported to a separate asset catalog. Layout, typography and native controls remain inherited from FluidVoice.

Import a visual profile with **Import JSON**. Start from `Sources/Fluid/Branding/pichi-brand.json`; all eight fields are required. Names and tagline accept 1 to 120 printable characters, accents use `#RRGGBB`, and website/support links require HTTPS without URL credentials. Profiles are limited to 32 KB. Invalid profiles leave the current profile intact.

**Import logo** accepts a local PNG/JPEG up to 4 MB and 4096 pixels per side. The app stores its own copy in the isolated preference domain. It updates app marks and the running Dock icon. Reset restores the packaged profile and icon. Restart refreshes window titles and menus. The Finder icon and macOS permission prompts use the packaged installation identity.

Profiles only change appearance. They cannot alter a bundle ID, credential namespace, model-feed trust, updater, analytics destination or feedback upload endpoint.

## Separately installed distributions

`Configuration/PichiBrand.xcconfig` defines `PICHI_PRODUCT_NAME`, `PICHI_BUNDLE_IDENTIFIER` and `PICHI_APP_ICON`. Override them in a distribution-specific xcconfig passed to Xcode with `-xcconfig`; include PichiBrand.xcconfig first. Also replace the packaged JSON profile and add the distribution's own icon asset in its source branch. Use a unique reverse-DNS bundle identifier and signing team. Debug adds `.debug`, preserving isolation from the release installation.

The bundle ID determines UserDefaults, Application Support and provider Keychain namespaces. No existing FluidVoice preferences, credentials, dictionaries or meeting data are copied. App-managed Parakeet/EOU, Whisper, Nemotron and external CoreML caches also use these isolated roots. The optional FluidAudio CTC vocabulary helper retains the dependency-owned public weights cache because its rescorer hardcodes the tokenizer directory; Pichi does not delete that shared helper cache. Keep personal profiles and artwork outside Git unless explicitly approved for distribution.

App updates are disabled until Pichi has a reviewed signed release feed and signing policy. Release notes and issue links point at `Pichi-AI/pichi-voice`. Runtime profiles cannot enable app updates. The inherited third-party speech model feed and its trust keys stay intact.

Upstream PostHog ingestion, support form POSTs and transcription-example uploads are disabled. Support links open the profile's support page without sending the drafted message or transcript. A future Pichi telemetry/support integration requires a separate explicit implementation.

The application remains a downstream of FluidVoice under GPL-3.0. Preserve source copyright notices and third-party model attribution in every distribution.

## Verification

Run `bash Tests/run_brand_profile_tests.sh` for profile validation and identity-policy tests, `bash scripts/dev/check.sh` for portable checks, and `bash scripts/dev/macos.sh build` for a native unsigned build. Verify the resulting bundle's CFBundleIdentifier, display name, icon and resource profile before launching it. Interactive permission, theme and accessibility behavior require a Mac UI check.
