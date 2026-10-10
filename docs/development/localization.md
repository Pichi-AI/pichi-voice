# Interface localization

Pichi Voice defaults to Russian regardless of the macOS language. Settings > General has an interface selector built from `Bundle.localizations`, stored in the app's own defaults domain under `PichiInterfaceLanguage`. This choice does not alter speech recognition, meeting transcription, summary language, provider payloads or user text.

English source strings remain in the upstream files. `Localizable.xcstrings` supplies Russian UI translations. SwiftUI views inherit the selected locale from `AdaptiveAppTheme`; dynamic UI labels and native AppKit menus use explicit `PichiLocalization.text` lookup. Do not pass transcripts, custom dictionary entries, prompt/profile names, device names, URLs or model identifiers to that helper. Unknown UI keys fall back to English. Language identifiers follow BCP 47, with regional fallback to a matching base localization. Adding a language to the catalog adds it to the selector without source switches. `PichiLocalization.locale` supplies the current locale for dates, numbers and sizes.

`AppBrand.text` localizes display copy before substituting product names. Imported brand names and taglines remain user content; they are never translated. Standard AppKit menu titles use this app's `AppleLanguages` preference and update on the next app launch. Changing the interface language preserves the current page and meeting state.

The public build's onboarding offers optional AI setup through a configured provider or Setup later. It does not recommend or download the unavailable private Fluid-1 runtime. Local meeting-summary configuration remains a separate feature.

For existing upstream English-string regression assertions, set `PICHI_INTERFACE_LANGUAGE=en` explicitly in the DEBUG XCTest host. This override is accepted only when XCTest is loaded, never in a production build. Localization tests use isolated defaults and a synthetic bundle to cover the Russian default, persistence, English fallback, brand substitution and formatting tokens.

## Standard resources and context

The committed `Sources/Fluid/Localization/Localizable.xcstrings` is an Apple String Catalog, not a Swift translation dictionary. Xcode compiles it into standard bundle localization resources. It contains English source copy and Russian translations; the intermediate `LocalizationStaging` maps are removed. `InfoPlist.xcstrings` contains generic English and Russian permission-purpose descriptions. Native system dialogs and application identity follow macOS bundle rules; imported appearance cannot rewrite a signed bundle's identity.

Most inherited English keys stay unchanged to reduce upstream conflicts. Catalog symbol generation is disabled because inherited keys that differ only in capitalization or punctuation would generate colliding Swift symbols; Xcode still compiles the standard localization resources. Where one English word means different things, semantic catalog keys retain the same English text and provide independent translations. For example, `action.edit` means the Edit action, while the inherited `Edit` key means the editing mode. The narrow `PichiLocalization.text(key, defaultValue:)` overload performs the same standard bundle lookup with explicit English fallback copy. It does not infer keys from rendered text or translate data.

Plural-sensitive count labels use the catalog's native plural axis. English has `one` and `other`; Russian entries have `one`, `few`, `many` and `other`. Foundation and SwiftUI select the form from the integer argument and locale, including 11, 21 and 22. Do not add Russian plural algorithms or switch on a translated label. The prompt-selector icon uses `DictationPromptSelection`, preserving custom profile names as data.

Main and independent hosting surfaces inject both `locale` and `layoutDirection`. The direction comes from `Locale.Language.characterDirection`, so installing an Arabic, Hebrew or other catalog language needs no application-language case. Date, number and byte-size formatting use the selected locale. Language changes redraw existing views and typed status messages without replacing page, capture, countdown or summary-generation identity.

## Add another language

1. Add the language in Xcode's String Catalog editor to `Localizable.xcstrings` and `InfoPlist.xcstrings`, or import translator XLIFF resources using Xcode's localization workflow.
2. Translate values and context comments, preserving argument positions and C format types. Use native plural/device variations where needed. Keep product-name markers for substitution, and keep imported names, transcripts, prompts, dictionaries, file names, model IDs and URLs as data.
3. Use the same semantic key with its English default value for ambiguous UI contexts. A new language does not require a Swift enum case, conditional language branch or a separate view.
4. Run `bash scripts/dev/check.sh`, then compile and run the macOS localization tests. Review screenshots of the actual UI at narrow and wide window sizes; text expansion and right-to-left layout require visual validation.

The selector discovers installed languages from `Bundle.localizations`. Missing keys in an installed partial translation fall back through the English catalog resource, including its native plural grammar. Only keys absent from both resources use explicit English default copy or the source key. Unknown persisted choices return to the requested product default, Russian, without changing speech or summary-language preferences. Standard AppKit menu localization follows the app's scoped `AppleLanguages` preference on the next launch.

`check-localization.py` validates duplicate keys, catalog structure, English/Russian coverage, native plural categories and printf argument positions/types. It also checks explicit literal UI keys in the Swift sources. Swift interpolation and multiline/raw literals remain subject to Xcode compiler extraction through `SWIFT_EMIT_LOC_STRINGS`; the portable scanner is not a Swift type checker. Native tests verify the compiled catalog's actual plural output, additional-language fallback, generic layout direction and selection-based behavior. The scheme's English override applies only to DEBUG XCTest to retain upstream regression expectations.

Apple documents the native authoring and translator workflow in [Localizing and varying text with a string catalog](https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog) and [Discover String Catalogs](https://developer.apple.com/videos/play/wwdc2023/10155/).
