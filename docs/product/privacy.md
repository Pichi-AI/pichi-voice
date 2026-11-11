# Privacy and data handling

Pichi Voice provides local recording and compatible on-device speech processing. Data transfer depends on the functions and providers you select. This guide explains product boundaries; the published [mobile privacy policy](https://pichi.ai/voice/privacy) provides the mobile app's policy and contact details. [Русская политика](https://pichi.ai/ru/voice/privacy).

## Local use

Core local recording and transcription do not require a Pichi account. Audio, transcript text, meeting metadata, speaker labels, dictionary entries and supported voice-profile data can be stored on the device. Check audio retention and recording settings before recording.

Download a compatible local speech model before going offline. Model downloads contact their publishers or hosting services, exposing normal request information such as a network address and requested file. A model download does not require uploading meeting audio to that host.

Local processing does not itself encrypt every exported file or prevent system backups and receiving applications from accessing files under their control.

## Optional network features

Cloud speech or text providers process content you send to them under their policies. Pichi sign-in, selected account features and explicit uploads also use network services. Review the selected provider and upload settings before processing sensitive content.

Optional location or other protected capabilities have their own product settings and OS permissions. Grant only the capabilities you want to use.

## Meeting microphones

Mac microphone and computer audio are separate sources. Pichi Voice's microphone control governs its local microphone admission. A conferencing app's mute state is a separate control unless a verified observer connects them. Client changes and observation delay can affect automatic mute handling; services do not share a universal timing guarantee.

## Export and support

The receiving app or service controls retention, indexing and synchronization of exported files. Deleting a local recording does not delete copies you exported or uploaded elsewhere.

Review diagnostics and screenshots before sharing. Use synthetic examples in public issues. Never post private voice profiles, recordings, API keys or verification codes. Record and share only conversations you are authorized to process, with any required participant notice.
