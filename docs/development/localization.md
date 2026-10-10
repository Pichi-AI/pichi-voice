# Interface localization

Pichi Voice defaults to Russian regardless of the macOS language. Settings > General has an interface selector built from `Bundle.localizations`, stored in the app's own defaults domain under `PichiInterfaceLanguage`. This choice does not alter speech recognition, meeting transcription, summary language, provider payloads or user text.

English source strings remain in the upstream files. `Localizable.xcstrings` supplies Russian UI translations. SwiftUI views inherit the selected locale from `AdaptiveAppTheme`; dynamic UI labels and native AppKit menus use explicit `PichiLocalization.text` lookup. Do not pass transcripts, custom dictionary entries, prompt/profile names, device names, URLs or model identifiers to that helper. Unknown UI keys fall back to English. Language identifiers follow BCP 47, with regional fallback to a matching base localization. Adding a language to the catalog adds it to the selector without source switches. `PichiLocalization.locale` supplies the current locale for dates, numbers and sizes.

`AppBrand.text` localizes display copy before substituting product names. Imported brand names and taglines remain user content; they are never translated. Standard AppKit menu titles use this app's `AppleLanguages` preference and update on the next app launch. Changing the interface language preserves the current page and meeting state.

The public build's onboarding offers optional AI setup through a configured provider or Setup later. It does not recommend or download the unavailable private Fluid-1 runtime. Local meeting-summary configuration remains a separate feature.

For existing upstream English-string regression assertions, set `PICHI_INTERFACE_LANGUAGE=en` explicitly in the DEBUG XCTest host. This override is accepted only when XCTest is loaded, never in a production build. Localization tests use isolated defaults and a synthetic bundle to cover the Russian default, persistence, English fallback, brand substitution and formatting tokens.
