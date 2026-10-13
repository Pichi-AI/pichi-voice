# Portable branding and white-label distributions

The app preserves upstream target, module, type and directory names. User-visible product, meeting and assistant names, logos and shared appearance come from `AppBrand` and `AppTheme`.

## One portable file

**Import brand** in Settings > General accepts one versioned JSON file. **Export brand** produces the same self-contained format, including logos previously imported separately. The shipped Pichi package is `Sources/Fluid/Branding/brand-package.json`. It contains Pichi's existing mark, purple palette and product copy; those product defaults are not Swift constants.

Version 1 contains:

| Field | Contents |
| --- | --- |
| `formatVersion` | `1` |
| `profile` | Product, meeting and assistant names, tagline, light/dark accents, HTTPS website and support links |
| `logos` | Embedded primary PNG/JPEG plus optional light, dark and menu-bar variants |
| `theme` | Complete light/dark color-token maps for backgrounds, borders, text, warning, success and accent foreground |
| `style` | Default system/light/dark appearance, spacing and corner-radius scales, optional native body/title font designs |
| `links` | Optional public repository link |

Start with an exported package and replace its product copy, artwork, palettes and links for Pichi, a bank or another organization. `Configuration/BrandExamples/sber-demo.json` and `alfa-demo.json` demonstrate green/red appearances with bank marks downloaded from official resources and embedded as transparent PNGs. [Logo provenance and conversion](../../Configuration/BrandExamples/LogoSources/README.md) records the original SVGs, URLs and checksums. These are appearance demonstrations with invented product names, not bank products, partnerships or certified distributions. Their public links open the banks' websites. No external image request is made. A package cannot contain credentials, scripts, remote assets or archive paths. A transparent menu-bar logo is recommended; when absent, the primary logo remains a colored image. A missing logo uses a neutral waveform rather than another product's artwork.

Every color uses opaque `#RRGGBB`; alpha values are not supported. Every shared palette token is required. Main text must achieve at least 4.5:1 contrast against all six shared backgrounds. Secondary and tertiary text, warning and success colors, and the accent must achieve at least 3:1 against those backgrounds, because they also appear as labels and standalone icons. Accent button text must achieve at least 4.5:1 against the accent fill. A pale accent with dark button text is insufficient if the accent itself disappears on the theme's backgrounds. Every shared text/status foreground and the accent must also keep one luminance polarity and its required contrast against the per-channel RGB minimum and maximum of all six backgrounds. This conservative envelope guards alpha blends of those defined opaque surfaces, including opposite-polarity and saturated hue mixtures. It may reject strongly multicolor palettes; it does not validate unrelated native materials, images or additional colors. Spacing scale accepts 0.8 to 1.3; corner-radius scale accepts 0.75 to 1.5. Names and tagline contain 1 to 120 printable characters. Public links require HTTPS without credentials.

PNG/JPEG logos are validated with ImageIO using their actual format and pixel dimensions, not their declared display size. Each logo is limited to 4 MB and 4096 pixels per side, combined artwork to 12 MB, and the JSON package to 17 MB. Animated/multipage and mismatched formats are rejected. The legacy eight-field profile format remains importable; it retains the selected logo and can subsequently be exported as a complete package.

## Atomic activation and live refresh

Validation runs away from the UI thread. The complete validated package is written atomically to the bundle's isolated Application Support `Brand/active.json`; large embedded images are not stored in preferences. Failed validation or persistence leaves the active package intact. Reset removes the override and restores the shipped package.

The active decoded package is cached. A revision counter invalidates decoded NSImage caches only after successful activation/reset. Rendering, live captions and repeated name lookups do not reread JSON or decode base64. SwiftUI content, the menu-bar menu/icon, Dock icon, application menu titles and current window titles refresh after import. Native button text uses a contrasting accent foreground. Shared palette tokens and onboarding text/surfaces honor light/dark themes; standard macOS menus, glass materials, semantic recording red and layout retain native/upstream behavior. Text typography uses the shared role resolver described below.

Explicit Light and Dark preferences also set the application-wide AppKit appearance, keeping About, open/save panels and native alerts consistent with SwiftUI. System clears that override so native panels follow later macOS appearance changes. About receives the active name and a copy of the active logo with a matching accessibility description; its version and legal credits remain bundle-owned.

Owned About, Hide and Quit commands follow the imported product name. The app also updates its public `NSMenu` titles, but macOS/SwiftUI can retain the installed process name for the top-level application-menu label. A runtime appearance import cannot promise to rename that system-owned label. Use the separately built distribution described below when every installed-system surface must show the new product name; changing runtime process metadata or rewriting a signed bundle is not an appearance operation.

Imported names and taglines are user data. They are not translated or recursively substituted. Interface language is an independent preference; adding languages uses the String Catalog, without editing brand files.

Suggested dictionary, backup and audio archive filenames use a sanitized current-brand prefix, bounded by UTF-8 bytes for filesystem compatibility. Transfer schema identifiers stay unchanged. The factory Parakeet vocabulary resolves its product placeholder only when creating a missing dictionary or requesting factory defaults. Existing dictionaries, explicit user words, transcripts and genuine model-author attribution are never rewritten on brand import.

## Separate installation identity

A runtime import cannot rename an installed `.app`, change its signed bundle identifier, Finder icon, macOS permission identity, data namespace or Keychain service. A separately installed Sber/Alfa/Pichi distribution consumes the **same appearance package** at build time and supplies its own unique installation identity.

Prepare validated build inputs on a Mac:

```bash
bash scripts/dev/prepare-brand-distribution.sh /path/to/brand.json ai.example.voice .build/example-brand
```

The helper refuses an existing output directory and emits the complete package, a trusted distribution resource, ten generated macOS app-icon sizes, and `Brand.xcconfig`. In an isolated distribution worktree, copy its generated `Sources/Fluid/Branding` resources and `Sources/Fluid/Assets.xcassets/BrandAppIcon.appiconset` into the matching source directories. Pass the generated absolute `Brand.xcconfig` path to Xcode with `-xcconfig`. It supplies `PICHI_PRODUCT_NAME`, `PICHI_BUNDLE_IDENTIFIER` and `PICHI_APP_ICON`, already consumed by the project. Targets and Swift test/module imports remain unchanged. Configure signing separately. Debug appends `.debug` and stays isolated from release.

The helper does not install, launch, sign, publish or overwrite an existing distribution. It requires an embedded primary logo and rejects build-setting/path syntax in the product name. Product display names and system permission descriptions use the build settings, with standard localized InfoPlist strings.

## Trusted service policy

`Sources/Fluid/Branding/brand-distribution.json` belongs to the built/signed bundle, not the runtime appearance store. It supplies asset names, the release repository, optional feedback endpoint and updater policy. Missing/corrupt resources fail closed to neutral appearance and disabled services. An imported public repository link is only a visible link; update checks use the trusted distribution repository.

Pichi ships with app updates disabled. Enabling updates in a trusted distribution requires a single validated GitHub repository, an expected signing team and a valid current code signature matching that team. Unsigned developer builds remain disabled. The existing updater still verifies downloaded app signatures. Runtime packages cannot enable updates, redirect telemetry, change consent or submit private data to a different endpoint. Analytics is independently configured through trusted bundle/build settings; see its development documentation when enabled.

The bundle ID controls UserDefaults, Application Support, provider Keychain and diagnostic-log namespaces. Local diagnostics use `~/Library/Logs/<bundle identifier>/diagnostics.log`, with the existing 1 MB rotation and one backup. Debug and separately installed distributions have separate logs. Existing FluidVoice logs, data and credentials are not copied or migrated. Baseline ASR runs keep their unique temporary root. Dependency-owned public model caches and genuine third-party model attribution remain explicit. Preserve original source copyright notices, GPL-3.0 and model licenses in every distribution.

## Verification

`bash Tests/run_brand_profile_tests.sh` verifies package/profile/image/contrast validation, atomic disk activation, invalid-import rollback, cached large-package lookups, reset, legacy migration, multi-brand substitutions and installation/service isolation. `bash scripts/dev/check.sh` verifies portable configuration; `bash scripts/dev/macos.sh build` is the separate native compilation check. The distribution helper also needs a native generated-resource/icon check. Interactive light/dark theme import, application-menu refresh, permissions and Finder/signing identity require Mac UI verification.

`style.defaultOnboardingLanguageID` is an optional BCP 47 language identifier for first-run speech-language selection. The packaged Pichi appearance sets `ru`; older brand files without the field remain supported. A configured language must have an available catalog route, otherwise the packaged available choice and existing catalog fallback apply. Existing explicit user choices survive replay and completion. The primary onboarding grid keeps its existing eleven-language capacity while promoting the configured available choice; remaining languages stay in Other.

## Shared native typography

`style.bodyFontDesign` and `style.titleFontDesign` optionally select `sans`, `serif` or `rounded`. These are native Apple font designs, not installed font names or downloadable font files. Missing fields preserve the original SF body, New York editorial headings and existing sizes/weights. The bank examples explicitly choose `sans` for both fields. Existing semantic title roles and editorial headings use the title choice; body, buttons, captions and owned native search input use the body choice. Numeric rounded metrics, monospaced code/live transcripts and SF Symbol-only icons retain their distinct roles. Standard macOS menus and controls retain system typography.

`FluidTypography` resolves the already decoded package, and `AppTheme.Typography` recomputes its existing role tokens after an appearance refresh. The root font modifier keeps one stable SwiftUI subtree. Native search font updates preserve the field, editor, query, focus and selection; typography import does not restart recordings or replace editors. No language or brand-specific font branch is needed.

Run `bash Tests/run_fluid_typography_tests.sh` on macOS to check direct CoreText glyph maps, without automatic fallback, for all 66 Russian letters including `ё/Ё`, Latin letters, digits, `№`, quotation marks and combining stress. The check covers four native designs, nine weights, seven sizes and roman/italic conversions, plus all nine body/title design combinations and unchanged mono/numeric roles. Coverage is measured on the host macOS version; run the same check on each supported macOS release.

`bash Tests/run_fluid_typography_tests.sh --specimens .build/font-specimens` also writes native, offscreen RU/Latin specimen PNGs for the Pichi, Sber and Alfa packages. They are font specimens, not screenshots or evidence of an interactive application run. The native integration suite separately verifies typography token refresh and preservation of search/editor state.
