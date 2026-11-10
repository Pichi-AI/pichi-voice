<p align="center"><img src="Sources/Fluid/Assets.xcassets/PichiAppIcon.appiconset/icon-128@1x.png" width="96" height="96" alt="Pichi Voice" /></p>

# Pichi Voice

**Speak your text. Keep your meetings on your device.**

Voice typing on Mac, local meeting recording and transcription on Mac, iPhone and iPad. Spend less time typing and keep control of your recordings.

[Русский](README.ru.md) · [Website](https://pichi.ai/voice) · [Releases](https://github.com/Pichi-AI/pichi-voice/releases) · [User guide](docs/product/user-guide.md) · [Support](SUPPORT.md)

## What you can do

| | Mac | iPhone and iPad |
| --- | --- | --- |
| Voice typing | Global shortcut and insertion into other apps | Meeting recording and transcription are the mobile focus |
| In-person meetings | Record through your microphone | Record conversations away from your computer |
| Online meetings | Capture computer audio and your microphone, with separate microphone controls | Record in-person conversations through the device microphone |
| Local transcription | Choose a compatible on-device speech model | Download a compatible model and transcribe on the device |
| Review | Transcripts, speaker labels, supported summaries and export | Recording history, audio playback and speaker-labelled transcripts |

Compatible speech models support Russian and English. Other languages, speed and memory requirements depend on the model and device. Automatic speaker labels and summaries can contain mistakes: review important results.

## Availability

| Platform | Requirements | Download |
| --- | --- | --- |
| macOS | macOS 15 or later; Apple Silicon | [Download Mac installer](https://github.com/Pichi-AI/pichi-voice/releases/download/v0.1.0%2B66-public.1/Pichi-Voice-0.1.0-66-macos-arm64.pkg) |
| Windows | - | Coming Soon |
| iOS (iPhone / iPad) | iOS / iPadOS 17 or later; memory and storage for the selected model | Coming Soon |
| Android | - | Coming Soon |

## Get started

1. [Download the Mac installer](https://github.com/Pichi-AI/pichi-voice/releases/download/v0.1.0%2B66-public.1/Pichi-Voice-0.1.0-66-macos-arm64.pkg) for Apple Silicon and macOS 15 or later.
2. Open the installer and follow the steps. It installs Pichi Voice in Applications and opens it for you.
3. Complete the guided setup when Pichi Voice opens. Grant microphone access, Accessibility for typing into other apps, and screen/system-audio access for computer-audio recording.
4. Select and download a speech model for your language while online.
5. Try a short dictation or recording and review the result.

Core local recording and compatible on-device transcription do not require a Pichi account.

See the [user guide](docs/product/user-guide.md) for recording, dictation, permissions and troubleshooting.

## Online meetings and conferencing

On Mac, Pichi Voice records locally rather than inviting a meeting bot. You control microphone capture separately from computer audio.

Zoom and Google Meet have been exercised in native checks. Audio capture, connected-call detection and observation of the conferencing app's microphone state are different capabilities. Automatic mute observation depends on the client, interface and permissions; it is not a universal or zero-delay guarantee. Use Pichi Voice's explicit microphone control for direct control over local microphone recording.

Compatibility work has also examined **Yandex Telemost, Kontur.Talk, MTS Link, VK Teams and TrueConf**. Complete connected-call and mute scenarios for these services remain under verification. The [dated compatibility report](docs/research/communication-platforms-2026-11.md) records the tested versions and remaining gaps.

## Privacy and offline use

Compatible local models process audio on your device after their required files are downloaded. Core local recording and transcription work without a Pichi account. Cloud AI providers and Pichi account/upload features are optional; selecting them can send relevant content to the chosen service.

Model downloads and optional services still use the network. Exported files are governed by the receiving app's or storage service's controls. Review audio retention and sharing settings, and record only conversations you are authorized to process.

Read [privacy and data handling](docs/product/privacy.md) and the [mobile privacy policy](https://pichi.ai/voice/privacy).

## Build and contribute

```sh
git clone https://github.com/Pichi-AI/pichi-voice.git
cd pichi-voice
bash scripts/dev/new-worktree.sh my-change
# Continue in the absolute worktree directory printed by the helper.
bash scripts/dev/setup.sh
bash scripts/dev/macos.sh build
```

Xcode is required for native Apple builds. Model weights are obtained separately under their own licenses and are not included in the repository.

[Development setup](docs/development/codex.md) · [Testing](docs/development/testing.md) · [Branding](docs/development/branding.md) · [Localization](docs/development/localization.md) · [Contributing](CONTRIBUTING.md)

## License and acknowledgements

Pichi Voice is free software under [GNU GPL version 3](LICENSE). It is a modified downstream of [FluidVoice](https://github.com/altic-dev/FluidVoice), with Pichi product identity and additional meeting, mobile and speech capabilities. Original copyright notices and upstream history are preserved.

See [acknowledgements and third-party software](docs/product/acknowledgements.md). Pichi Voice is distributed separately; use Pichi's own repository and releases for Pichi downloads and support.
