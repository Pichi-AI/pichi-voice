# Mobile first-run setup and consolidated preferences

Work starts from `255039931e9578c0f1daf74e4ea3267c20047896`, the installed continuity branch, rather than current main. This report records the implementation, native simulator acceptance and measured limitations. Physical-device acceptance and speaker-identity accuracy remain open.

## Product flow

| Remove from mobile preferences | Keep | Consolidate |
| --- | --- | --- |
| Enable participant labels | ASR model and supported language | Data cleanup toggle, actual readiness and local sensitive-phrase dictionary |
| Streaming versus after-recording participant processing | Microphone, audio saving and retention | Automatic VAD and participant artifact preparation with shared progress |
| Manual VAD and participant model installers | Existing owner-voice enrollment, deletion and saved profile | Same model/service operations in setup and Settings |

```mermaid
flowchart LR
    W[Welcome] --> A[Select ASR and prepare]
    A --> S[Automatic participant resources]
    S --> P[Audio policy and optional data cleanup]
    P --> V[Existing voice enrollment or Skip]
    V --> D[Ready]
```

The mobile flow uses the portable brand mark, theme typography and String Catalog. The inherited desktop onboarding was inspected in `WelcomeView.swift` and `Theme/Components/OnboardingComponents.swift`; its AppKit window, shortcut and Accessibility controls cannot host an iPhone flow. ASR preparation continues through `ASRService`, participant separation through the registered `MeetingDiarizationModelStore`, shared voice-encoder installation through the same canonical `.shared` operation as enrollment, VAD through `MeetingSpeechActivityResources`, and enrollment through `MeetingOwnerVoiceSettingsContent` and its existing service.

The initial mobile migration retires known disabled/after-recording participant preferences for new requests. It preserves unknown future timing values, explicit privacy, audio retention, selected ASR, stored voice profiles and encoded sessions/checkpoints. Existing installations continue into the ordinary app. New installations resume the last setup step and pending model selection. Privacy defaults off only when no choice exists.

`MobileRequiredResources` presents and joins one artifact preparation job for background setup, onboarding and Start. It does not load model engines. Foreground cancellation detaches its waiter while the app-owned job continues. Start waits before opening the microphone, so waiting for files cannot accumulate PCM. Native inference preparation and warmup retain the existing idle/runtime owners. Privacy installation/validation/loading is a separate requested transaction; committed activation follows successful service preparation. Copy/export honor the requested state and fail closed during preparation errors.

Custom sensitive phrases live in the existing settings namespace. A bounded immutable snapshot is captured before asynchronous attempt admission and passed through to the processing owner. Its digest participates in checkpoint identity. The shared privacy projection combines model and dictionary spans in original UTF-16 coordinates. Nonempty dictionaries keep the existing bounded lexical tail across VAD silence, because a pause may split a phrase; provisional display still uses the same privacy approval. No raw dictionary content enters checkpoints, logs or Git.

## Measured artifact inventory, 2026-10-20

Counts are logical file bytes from current owning manifests, pinned Hugging Face tree metadata and read-only installed-cache checks where stated. Download columns count payload, excluding protocol overhead. Installed bytes exclude APFS allocation and runtime-generated caches. Inventory research did not download weights. Later native acceptance used the normal first-run downloads and verified public cache copies. Isolated engine RAM was not measured.

| Artifact | Version / source revision | Download bytes | Installed bytes | Redistribution source |
| --- | --- | ---: | ---: | --- |
| GigaAM public CTC INT8 + vocabulary | v3, `322c3b29492673eb7d0b434bfa9dfb8653e34d02` | 224,895,354 | 224,895,354, cache confirmed | MIT [card](https://huggingface.co/istupakov/gigaam-v3-onnx/blob/322c3b29492673eb7d0b434bfa9dfb8653e34d02/README.md) |
| Parakeet TDT 0.6B v3 Core ML | source currently `resolve/main` | 483,254,686 current files | 483,254,686, cache confirmed | CC-BY-4.0 [NVIDIA card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) |
| Whisper Tiny multilingual Q8 GGUF | source currently `resolve/main` | 45,981,088 | 45,981,088, cache confirmed | Converter Apache-2.0 [card](https://huggingface.co/handy-computer/whisper-tiny-gguf); original weights/code MIT [license](https://github.com/openai/whisper/blob/main/LICENSE) |
| Silero unified 256ms | v6.0.0, `b419383c55c110e2c9271fa6ee0ea83d03c70d96` | 1,063,425 | 1,063,425 | MIT [card](https://huggingface.co/FluidInference/silero-vad-coreml/blob/b419383c55c110e2c9271fa6ee0ea83d03c70d96/README.md) |
| Streaming Nemotron fast128 FP16 CPU, including silence | `25a90f97f254428d4b30374b76af9c74fdee8327` | 199,096,435 | 199,096,435 | OpenMDW-1.1 [card](https://huggingface.co/FluidInference/nemotron-3-diarization-coreml/blob/25a90f97f254428d4b30374b76af9c74fdee8327/README.md), [terms](https://openmdw.ai/license/1-1/) |
| Internal after-recording fast32 split W8A8, including silence/projection | same revision | 102,096,652 | 102,096,652, cache confirmed | Same Nemotron terms |
| Legacy WeSpeaker v2 owner encoder | `7eab74f3463c736418d0eb10296261ae581146c9` | 7,954,144 | 7,954,144, cache confirmed | Exact legacy export CC-BY-4.0 [notice](https://huggingface.co/FluidInference/speaker-diarization-coreml/blob/7eab74f3463c736418d0eb10296261ae581146c9/NOTICE.md) |
| A1 Russian PII INT8 | v0.1.0, `67a6270bf24661bf62ea0e93582d02edcc8ee517` | 99,684,446 | 99,684,446 | Apache-2.0 weights [card](https://huggingface.co/Powpowpow23/ru-pii-ner-a1/blob/67a6270bf24661bf62ea0e93582d02edcc8ee517/README.md); unresolved NEREL permission review [provenance](https://huggingface.co/Powpowpow23/ru-pii-ner-a1/blob/67a6270bf24661bf62ea0e93582d02edcc8ee517/DATA_PROVENANCE.md) |

The current Parakeet catalog advertises 483,288,717 bytes, 34,031 bytes above the current complete files. Required graph files alone total 483,103,089 bytes; vocabulary/configuration also count. UI sizes remain estimates, not a repaired pinned manifest. Parakeet and Tiny downloads have no immutable source revision in their current downloader contract; a research lookup must not be presented as a pinned installation guarantee.

The retired `russianTiny` privacy descriptor is 30,334,469 bytes but is not the selected service artifact. Replacing A1 with it in package calculations would be incorrect. Historical process-footprint numbers in `mobile-meetings.md` cover a different whole composition, not isolated current engine RAM.

## Packaging decision

Implemented baseline: automatic first-run downloads; bundled models evaluated and deferred to a separate distribution decision. ASR downloads follow the selected model; privacy downloads only after explicit activation. Distribution packaging and App Store policy are unchanged. Weights remain outside Git.

| Candidate | Additional uncompressed payload | Resulting package before compression |
| --- | ---: | --- |
| VAD only | 1,063,425 bytes / 1.014 MiB | Base app + payload |
| VAD + streaming participant graph | 200,159,860 bytes / 190.887 MiB | Base app + payload |
| VAD + streaming graph + owner encoder | 208,114,004 bytes / 198.473 MiB | Base app + payload |
| Above plus privacy | 307,798,450 bytes / 293.539 MiB | Base app + payload |
| Both diarization profiles + VAD + owner encoder | 310,210,656 bytes / 295.840 MiB | Base app + payload |

The participant graph alone is 189.873 MiB. With its owner encoder, participants require 197.459 MiB before VAD. RAM, compressed IPA, download size and app thinning remain unknown until actual permitted archive/measurement. A bundle-to-support copy could create a second logical disk copy. Bundled files must retain the same manifest validation and resource ownership as downloaded artifacts.

VAD is a small MIT-licensed bundling candidate. The 198.473 MiB mandatory kit can be considered in a separate distribution decision, retaining required license/attribution notices. CC-BY-4.0 obligations and the actual distribution channel must be reviewed together. Privacy remains opt-in download; its disclosed provenance does not support claiming unrestricted clearance. ASR stays replaceable in Settings.

## Completed verification

Functional implementation was independently reviewed through `e63eec9e7bae3aa61192b64a7bc3de5c785764c4`. Material findings were fixed and affected checks repeated. The review covered extension-point reuse, immutable model/rules selection, cancellation, resource ownership, locale-stable speaker numbering, privacy publication and upstream impact. That revision adds an explicit conditional Combine import required by the macOS compiler; behavior is unchanged from the native runtime revision below.

The subsequent presentation-only revision `ec1d3d4782d5135f2658c7c8641e7ed3ee17c1f9` was independently reviewed without material findings. GigaAM and Parakeet v3 card descriptions now summarize Russian and multilingual/mixed speech. Existing detailed import information and the full language list moved into registered backend metadata, displayed by the existing About the model disclosure. Tiny's accuracy warning remains unchanged. No inference, admission capability, artifact fingerprint or common model-specific UI branch changed.

| Check | Result and scope |
| --- | --- |
| Repository/setup, localization, plist/project syntax, diff whitespace | PASS at the functional checkpoint. Its English/Russian catalog contained 3,081 complete keys. |
| Shared privacy/dictionary policy | PASS, including Unicode source offsets, boundaries, overlapping masks, immutable rules and sparse speech tails. |
| Streaming policy probes | PASS: protected tail 28,990 assertions; registry 133; admission 175; state 3,244. |
| Prepared runtime and runtime voice verification | PASS; prepared runtime covers 19 contract groups. |
| Mobile hosted native tests | 45/45 PASS, zero skipped, on `a98a6fd375f9311c205530e9b3d1205400eca613`, including actual A1 privacy inference and three enrollment admission/cancellation tests that never construct a microphone capture. |
| Native first-run acceptance | Fresh iPhone passed Welcome through real model/resource preparation, privacy OFF/ON/ready/OFF, voice Skip, normal app and restart on `712639820f546131161569511927d1e5167c082b`. iPad first-run preparation and interrupted privacy-step continuation also passed. |
| Native dictionary CRUD | Both simulators passed add, exact phrase replacement with Ё, save, delete and dark-theme restart on `71263982`. |
| Native layout review | All six Russian setup pages in light/dark on iPad and iPhone passed. Recording preferences passed English/light and Russian/dark in portrait/landscape on `a2a561ea811e430e48682203642a642871a76516`. |
| Real registered streaming composition | Parakeet and Tiny passed paced PCM, actual A1, fast128 speaker inference, protected publication before Stop, persistence and no full-recording replay on `a98a6fd3`. See limits below. |
| macOS Debug build-for-testing and focused regressions | PASS on `e63eec9e`: 25/25 tests in configuration, privacy publication and privacy readiness lifecycle. A separate test bundle namespace and disabled audio-service startup protected the installed Mac app's preferences and audio devices. The full upstream suite was not run. |
| Final model-card copy | PASS on `ec1d3d47`: 3,083 complete English/Russian catalog keys, signed arm64 mobile build-for-testing, and two scoped native UI cases with zero failures/skips. Four gated model-choice screenshots cover Russian light/dark on iPad and iPhone. No model/accuracy/macOS regression rerun was needed for this text-only change. |

The native application was copied to immutable ignored test storage, signed with an existing valid development identity and verified before each interactive acceptance revision. Source revision, file sizes and SHA-256 hashes were recorded. Tests did not rebuild or re-sign the running copy. This is Debug simulator evidence, not an IPA or physical-device performance claim.

The final `ec1d3d47` frozen app's 67 files, totaling 109,018,814 logical bytes, retained their recorded SHA-256 hashes and valid signature after both scoped UI cases. The original four screenshot PNGs and a source/hash manifest were copied to the local user-review artifact folder.

First-run cache inspection on both simulators found exactly 17 public resource files, totaling 433,009,358 bytes for GigaAM plus the required kit, and no TextPrivacy files before privacy activation. Parakeet/Tiny public cache copies used for separate inference cases were hash-checked and were not part of that first-run measurement.

Native review found and corrected a container accessibility identifier overriding Next, button contrast, a missing Russian completion label, dictionary row hit areas, Section-owned sheet presentation and editor toolbar sizing. The dictionary editor's presentation now belongs to the stable Form; its isolated draft retains errors and Cancel leaves saved rules unchanged. Normal participant settings expose status and preserve microphone/language/enrollment controls.

The test-only inference viewport uses the same adaptive theme as the app. Both privacy diagnostic decorators forward optional speech-boundary admission. A regression test catches the previous capability loss. Generic streaming checks require each canonical unit's actual interval, native precision and ID; an utterance is not converted into invented word times.

## Measured streaming sample and limitations

These are simulator whole-composition measurements from the final runtime revision `a98a6fd3`. The source is an ignored, reproducibly generated fictional RU/EN recording: 736,000 PCM16 frames at 16 kHz, 46 seconds, SHA-256 `02b8f38b1cda996b3b761d5b15816013a27a55e3a152acfe3b9cb1edb9e8784f`. Each paced test adds 88 terminal silence samples. No microphone, personal recording or enrolled voice profile was used.

| Metric | Parakeet v3 | Whisper Tiny |
| --- | ---: | ---: |
| First protected text after PCM starts | 15.63 s | 20.31 s |
| First labelled canonical speech | 22.50 s | 40.00 s |
| Canonical units before Stop / final | 37 / 37 words | 2 / 2 utterances |
| Non-sensitive reference anchors retained | 4 / 4 | 2 / 4 |
| Observed fictional sensitive case fully masked | 1 / 1 | 1 / 1 |
| Sampled whole-process peak footprint | 518.96 MiB | 228.08 MiB |
| Completion after Stop | 1.69 s | 0.64 s |

Both paths admitted all 736,088 frames through contiguous transport, preserved native unit identities and produced no whole-recording replay. Filesystem inventory observed no new audio/media paths before preparation, every 15 seconds during PCM and after completion; transient create/delete between observations was not proved absent. Resource and MainActor sampling describe these runs, not touch latency or FPS. Peak footprint includes the app, UI, models and inference and is not per-engine RAM.

Tiny omitted the entire English turn in this mixed-language window. All 320,000 frames of the first 20-second inference window reached its native backend; no 10-second truncation was found in the Swift routing or pinned native implementation. This result does not distinguish compact-model quality from native decoder behavior. No model-specific common-layer workaround, threshold tuning or fabricated timing was introduced.

Both models produced one anonymous cluster for two synthetic TTS voices. The tests establish the functional streaming and privacy contracts, not diarization accuracy, WER, DER or owner identity acceptance. Owner verification thresholds were unchanged. Actual owner-voice quality and long recordings on physical iPad/iPhone remain separate validation work.

Privacy and custom rules can keep a bounded short tail provisional until more context, a supported sealed boundary or Stop. The live caption now says labels appear after enough speech is collected, without promising a short fixed delay.

## Native evidence coverage

Ignored artifacts are under `.build/settings-onboarding/`, with per-case xcresult bundles, logs, frozen-bundle proofs, protected synthetic exports and capture indexes. The final stream summary is `final-native-streaming-summary.json`; mobile native counts are in `native-unit-ipad-a98a-summary.json`, and macOS evidence is under `macos/`.

| Final setup/CRUD capture | Saved | Changed | Unique decoded frames | Missed slots | Capture errors |
| --- | ---: | ---: | ---: | ---: | ---: |
| iPad dictionary | 145 | 51 | 50 | 38 | 0 |
| iPhone dictionary | 184 | 44 | 44 | 1 | 0 |
| iPhone first run | 179 | 53 | 41 | 6 | 1 |
| iPad setup layouts | 180 | 98 | 58 | 36 | 0 |
| iPhone setup layouts | 344 | 127 | 75 | 0 | 0 |

Every gated native screen was inspected before its next action. An independent visual review also inspected all 25 contact sheets covering 268 unique decoded frames from these five cases and found no additional persistent material layout, contrast or Cyrillic issues in the saved coverage. Capture uses the simulator screenshot fallback and does not establish complete one-second coverage. Every saved frame, error and missed slot was retained. Earlier unsuccessful acceptance runs are preserved and are not counted as final passes.

The bounded `ec1d3d47` model-choice followup saved 42 iPad frames (17 changed, 15 unique, 38 missed slots, two capture errors) and 73 iPhone frames (15 changed, 13 unique, three missed slots, zero capture errors). The parent inspected all four full-size gated screenshots and both contact sheets covering the 28 unique decoded frames. No additional material visual issue was found. These captures also have incomplete one-second coverage.

Physical tests were not started. Native screenshots are the review stage required before a physical install. No TestFlight upload, distribution archive, main merge or change to the prepared distribution build was performed.
