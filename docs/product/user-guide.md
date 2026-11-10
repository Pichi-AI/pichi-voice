# Pichi Voice user guide

[Русский](user-guide.ru.md) · [Website](https://pichi.ai/voice) · [Support](../../SUPPORT.md)

## Prepare

[Download Pichi Voice for Mac](https://pichi.ai/voice#download), open the disk image, and drag Pichi Voice to Applications. Open it from Applications to start guided setup. Existing recordings and settings are preserved.

The current Mac package targets Apple Silicon and macOS 15 or later. Mobile builds target iOS/iPadOS 17 or later. Models have additional memory, storage and language requirements. Complete model downloads while online and try a short recording before relying on offline use.

## Voice typing on Mac

1. Grant microphone and Accessibility access.
2. Select a speech model and global dictation shortcut in Settings.
3. Focus the destination field, start dictation and speak.
4. Finish with the configured shortcut and review the text.

Use the personal dictionary for names and terminology. Review learned corrections. Optional text enhancement uses the local or cloud provider you choose.

## Meetings on Mac

Start a recording from Recordings. Grant screen/system-audio access for computer-audio recording and check your selected sources.

Microphone capture is separately controlled. Pausing, switching off Pichi's microphone and muting inside a conferencing app have different meanings. Automatic conference mute observation depends on client support and permissions. Use Pichi Voice's own control for direct microphone admission.

After Stop, review the saved transcript and speaker labels. Processing may refine results after capture stops. Correct participant labels and check generated summaries before sharing.

## In-person recording on iPhone and iPad

Grant microphone access, select a downloaded compatible model and start recording. This records the device microphone, not another iOS application's call audio.

Finish setup and downloads before going offline. Core local recording and compatible local transcription work without a Pichi account. Before an important meeting, try the intended foreground, background and lock-screen use on your actual device and released build.

## Review and export

Open a saved session in Recordings to read its transcript and play retained audio. Correct automatic speaker labels and verify generated summaries against the transcript. Review which content you export; destination apps and services have their own access and retention controls. See [data handling](privacy.md).

## Troubleshooting

| Symptom | Check |
| --- | --- |
| No microphone audio | OS permission, selected input and Pichi microphone control |
| No computer audio | Screen/system-audio permission and selected source |
| Dictation does not insert | Accessibility permission and destination focus |
| Local processing fails to start | Model download, language compatibility, memory and storage |
| No network | Fully downloaded local model and local processing settings |
| Wrong word or speaker | Correct the result and check model/language selection |

Follow the [support guide](../../SUPPORT.md) if the problem remains. Do not post private audio or unredacted diagnostics.

## Repeat the initial setup

Open Help at the bottom of the sidebar and choose Replay onboarding. The setup steps appear again. Recordings, dictionary, voice profile, downloaded models and other preferences stay in place. Existing macOS permissions remain granted.

To check reinstallation, quit the app, drag it from the DMG to Applications again, and open it. Then replay onboarding from Help. You do not need to remove data folders or run a cleanup script. Keep a backup of your data before this check.
