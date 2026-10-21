# Mobile first-run setup and consolidated preferences

Work starts from `255039931e9578c0f1daf74e4ea3267c20047896`, the installed continuity branch, rather than current main. This report records implementation scope and open native validation gates. It does not establish model accuracy, latency or physical-device acceptance.

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

The mobile flow uses the portable brand mark, theme typography and String Catalog. The inherited desktop onboarding was inspected in `WelcomeView.swift` and `Theme/Components/OnboardingComponents.swift`; its AppKit window, shortcut and Accessibility controls cannot host an iPhone flow. ASR preparation continues through `ASRService`, participant installation through the registered `MeetingDiarizationModelStore`, VAD through `MeetingSpeechActivityResources`, and enrollment through `MeetingOwnerVoiceSettingsContent` and its existing service.

The initial mobile migration retires known disabled/after-recording participant preferences for new requests. It preserves unknown future timing values, explicit privacy, audio retention, selected ASR, stored voice profiles and encoded sessions/checkpoints. Existing installations continue into the ordinary app. New installations resume the last setup step and pending model selection. Privacy defaults off only when no choice exists.

`MobileRequiredResources` presents and joins one artifact preparation job for background setup, onboarding and Start. It does not load model engines. Foreground cancellation detaches its waiter while the app-owned job continues. Start waits before opening the microphone, so waiting for files cannot accumulate PCM. Native inference preparation and warmup retain the existing idle/runtime owners. Privacy installation/validation/loading is a separate requested transaction; committed activation follows successful service preparation. Copy/export honor the requested state and fail closed during preparation errors.

Custom sensitive phrases live in the existing settings namespace. A bounded immutable snapshot is captured before asynchronous attempt admission and passed through to the processing owner. Its digest participates in checkpoint identity. The shared privacy projection combines model and dictionary spans in original UTF-16 coordinates. Nonempty dictionaries keep the existing bounded lexical tail across VAD silence, because a pause may split a phrase; provisional display still uses the same privacy approval. No raw dictionary content enters checkpoints, logs or Git.

## Measured artifact inventory, 2026-10-20

Counts are logical file bytes from current owning manifests, pinned Hugging Face tree metadata and read-only installed-cache checks where stated. Download columns count payload, excluding protocol overhead. Installed bytes exclude APFS allocation and runtime-generated caches. No weights were downloaded for this inventory. Current engine RAM was not measured.

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

The current implementation retains automatic first-run downloads. It changes no signing, distribution or App Store policy. Weights remain outside Git.

| Candidate | Additional uncompressed payload | Resulting package before compression |
| --- | ---: | --- |
| VAD only | 1,063,425 bytes / 1.014 MiB | Base app + payload |
| VAD + streaming participant graph | 200,159,860 bytes / 190.887 MiB | Base app + payload |
| VAD + streaming graph + owner encoder | 208,114,004 bytes / 198.473 MiB | Base app + payload |
| Above plus privacy | 307,798,450 bytes / 293.539 MiB | Base app + payload |
| Both diarization profiles + VAD + owner encoder | 310,210,656 bytes / 295.840 MiB | Base app + payload |

The participant graph alone is 189.873 MiB. With its owner encoder, participants require 197.459 MiB before VAD. RAM, compressed IPA, download size and app thinning remain unknown until actual permitted archive/measurement. A bundle-to-support copy could create a second logical disk copy. Bundled files must retain the same manifest validation and resource ownership as downloaded artifacts.

VAD is a small MIT-licensed bundling candidate. The 198.473 MiB mandatory kit can be considered in a separate distribution decision, retaining required license/attribution notices. CC-BY-4.0 obligations and the actual distribution channel must be reviewed together. Privacy remains opt-in download; its disclosed provenance does not support claiming unrestricted clearance. ASR stays replaceable in Settings.

## Validation gates

Portable repository checks pass at the initial implementation checkpoint. Native build, new hosted transaction tests, actual utterance streaming regressions, independent review of the final integrated revision, iPad/iPhone light/dark Russian screenshots and combined owner-live integration remain required. The owner-live session currently owns the heavy resource slot. No physical device, microphone or user's recording was used for this implementation stage.

Parakeet and Tiny registration now selects the same existing streaming runtime/profile. Native utterances keep their real interval/precision/ID; word-specific sponsorship rules stay word-specific, and one utterance containing two voices stays uncertain. Registration changes and synthetic tests alone do not establish throughput, RAM, accuracy or live owner-label latency for these combinations.
