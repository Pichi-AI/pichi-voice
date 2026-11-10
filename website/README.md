# Pichi Voice product website

The canonical product landing is English `/voice/` and Russian `/ru/voice/` on `https://pichi.ai`. The reviewed static source is in `dist/voice/` and `dist/ru/voice/`. It uses the bundled Pichi logo, system fonts and native HTML links/details, with one local JavaScript module for the illustrative voice demo and scroll reveals. It makes no microphone or external font/image requests.

## Publication

The production Pichi website is the Astro landing workspace in `Pichi-AI/web`. Copy only these two product directories into `apps/landing/public/voice/` and `apps/landing/public/ru/voice/`. Preserve the existing server-rendered policies at `/voice/privacy` and `/ru/voice/privacy`. Do not copy this directory's `dist/index.html` over the main site's home page; that file is only an entry point for the separate preview host.

Record the exact Pichi Voice source commit in the web change. Check the rendered routes, language links, assets, privacy routes and existing home pages through the actual Astro server. Publish only the landing component with the existing deployment workflow.

The `.openai/hosting.json` identifies the optional Sites preview publication. Keep that identity on updates. It is independent of the production site's route and does not configure `pichi.ai` by itself.

## Release links and copy

Enable a direct download only for an actually published compatible package. Show platform icons and Coming Soon for unavailable downloads. The active macOS link targets `Pichi-Voice-0.1.0-66-macos-arm64.dmg` in release `v0.1.0+66-public.1`. The release owner must publish and verify that exact DMG before deploying this change. No release asset is published by this website change. Keep compatibility, installation, build and signing details in the release and development records. Public copy retains local setup requirements, optional-cloud disclosure and the mobile distinction between offline in-person meetings and unavailable phone-call audio access.

The illustrated meeting text is synthetic and is not a screenshot or performance measurement. Application source and website assets remain subject to the repository's GPL-3.0 license; the static directory includes `voice/LICENSE.txt`.

## Hero animation and focused checks

The EN preview entry point stays byte-identical to `/voice/`. EN and RU use the same local demo adapter. The hero automatically streams a selected recording, holds the completed text for three seconds, then resets and repeats. The completed hold uses a timer instead of animation frames. Recordings opens the two synthetic entries; selection resets the loop and moves keyboard focus to the visible transcript heading. Settings is static. There are no replay or pause controls. Each selected conversation has a complete, stable visually hidden transcript for assistive reading; animated rows and the duplicate floating text are decorative.

Viewport exit, hidden documents and persisted `pagehide` cancel pending work and show the complete transcript. Returning to a visible, active viewport starts the selected recording again. Reduced motion and missing or failed viewport observation keep complete static transcripts. Unmount and terminal `pagehide` release the timer, frame, observer and listeners and restore static HTML. Nothing accesses a microphone, audio device or network.

Run `node --test Tests/test_voice_demo.mjs` from the repository root. The suite covers timeline/controller behavior and mounts the real shipped HTML through the production DOM adapter with deterministic browser boundaries. It does not establish browser visual acceptance or release-asset availability.
