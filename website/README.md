# Pichi Voice product website

The canonical product landing is English `/voice/` and Russian `/ru/voice/` on `https://pichi.ai`. The reviewed static source is in `dist/voice/` and `dist/ru/voice/`. It uses the bundled Pichi logo, system fonts and native HTML links/details, with one local JavaScript module for the illustrative voice demo and scroll reveals. It makes no microphone or external font/image requests.

## Publication

The production Pichi website is the Astro landing workspace in `Pichi-AI/web`. Copy only these two product directories into `apps/landing/public/voice/` and `apps/landing/public/ru/voice/`. Preserve the existing server-rendered policies at `/voice/privacy` and `/ru/voice/privacy`. Do not copy this directory's `dist/index.html` over the main site's home page; that file is only an entry point for the separate preview host.

Record the exact Pichi Voice source commit in the web change. Check the rendered routes, language links, assets, privacy routes and existing home pages through the actual Astro server. Publish only the landing component with the existing deployment workflow.

The `.openai/hosting.json` identifies the optional Sites preview publication. Keep that identity on updates. It is independent of the production site's route and does not configure `pichi.ai` by itself.

## Release links and copy

Enable a direct download only for an actually published compatible package. Show platform icons and Coming Soon for unavailable downloads. The public copy describes a native PKG installation; keep internal submission, build and signing details in development records. Preserve local-model download requirements, optional-cloud disclosures and the dated compatibility limits for conference clients.

The illustrated meeting text is synthetic and is not a screenshot or performance measurement. Application source and website assets remain subject to the repository's GPL-3.0 license; the static directory includes `voice/LICENSE.txt`.
