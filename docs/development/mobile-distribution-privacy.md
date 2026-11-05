# Mobile distribution privacy metadata

The mobile target copies `Sources/Mobile/Resources/PrivacyInfo.xcprivacy` into
the app bundle through its existing Resources phase. This manifest describes
the app's required API use, based on the mobile source membership at
`67c5698e7011d9638ebc58b362e674c23ffa29b8` and Apple's documentation checked on
2026-10-19. It does not change runtime behavior.

| API category | Reason | Existing mobile use |
| --- | --- | --- |
| User defaults | `CA92.1` | `SettingsStore` uses the app's standard defaults for preferences. `BrandPackageStore` and `PichiLocalization` use app-owned preference keys. No app-group defaults reason is declared. |
| System boot time | `35F9.1` | `systemUptime` measures elapsed inference/processing time, timers and local event ordering in `FluidAudioProvider`, `MeetingLiveTrackEngine` and the Nemotron runtime. This reason does not permit exporting raw device uptime. |
| File timestamps | `C617.1` | `PronunciationDictionaryStore` removes stale orphaned app files using modification times. `MeetingNemotronModelLocator` binds app-owned model metadata to an artifact. `CompactSpeechModelReleaseCatalog`, `MeetingSessionStore` and PCM storage use `fstat`/`lstat` to validate app-owned files. |
| Disk space | `E174.1` | `ParakeetArchiveDownloader.availableCapacity` checks capacity before downloading model files. `IOSMeetingCaptureEngine` rejects retained-file capture when capacity is insufficient. |

The review included the explicit mobile shared-source list, the mobile host
sources and the local `PichiGigaAM` source package. It found no active-keyboard
API use in these sources. The source review does not establish all privacy
practices of resolved third-party binaries. Their manifests, the archived app
privacy report and App Store Connect declarations still need distribution
review.

The app also declares seven collected data categories for its optional account
and cloud features and their server-side operation: name, email address, user
ID, other user content, product interaction, performance data and other diagnostic
data. Each is linked to the user and used for app functionality, without
tracking. These declarations include server login activity and API/security logs;
local-only audio, voice profiles and location do not by themselves establish
developer collection. The corresponding App Store Connect answers must remain
consistent with the actual service configuration. Apple's
[TN3184](https://developer.apple.com/documentation/technotes/tn3184-adding-data-collection-details-to-your-privacy-manifest)
describes these manifest entries. Metadata declarations do not enable optional
features or change runtime consent.

Apple's [required API categories and approved reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)
define these codes. [Required reason API policy](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
requires declarations to match actual use. [Manifest placement](https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk)
places an iOS manifest at the app bundle root.

The legacy 1024px PNG app icon had transparent outer margins and an alpha
channel. Its mobile export now composites the existing raster onto the
`#F7F6F4` background already defined in `Sources/Fluid/Branding/pichi-icon.svg`
and writes RGB PNG. Every originally opaque pixel, the mark's geometry, colors
and position remain identical. Only the transparent outer background and its
antialiased boundary are filled; iOS supplies the installed icon mask. The
portable brand package, desktop icons and vector source are unchanged.
This is the existing asset-catalog icon, not an Icon Composer layered icon.
Apple's [DTS response about alpha validation](https://developer.apple.com/forums/thread/795411)
records the large asset-catalog icon rejection.

Metadata changes produce a new source revision and require a fresh archive.
They do not validate an existing archive, signing, TestFlight acceptance or
the runtime behavior of the newly packaged revision.

Mobile Settings also exposes an offline Licenses list for guests and signed-in
users. `Notices/MobileLicenses.json` supplies versioned component groups and their
bundled documents; the generic viewer keeps original license and attribution
text selectable. Optional model notices do not indicate model installation.
The notices identify included components and do not establish App Store
distribution permission or a complete transitive license audit.
