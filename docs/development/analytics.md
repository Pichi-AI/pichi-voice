# Distribution analytics

Pichi Voice retains the upstream typed, low-volume analytics pipeline. It sends explicit events through PostHog's [batch ingestion API](https://posthog.com/docs/api/capture). There is no analytics SDK, autocapture, session replay, exception autocapture, or remote configuration in this application.

## Trusted configuration

Analytics is disabled unless the trusted application bundle contains all three settings:

| Build setting | Meaning |
| --- | --- |
| `PICHI_POSTHOG_ENABLED` | Explicit `YES` enables the configured analytics destination. |
| `PICHI_POSTHOG_PROJECT_TOKEN` | An ingestion project token beginning with `phc_`. Personal/admin tokens are rejected. |
| `PICHI_POSTHOG_HOST` | Explicit HTTPS ingestion origin, without credentials, query, fragment or path. |

The shared Pichi PostHog project is [Pichi EU](https://eu.posthog.com/project/118685), with ingestion at `https://eu.i.posthog.com`. No upstream key or default cloud-region destination is used. Importing a brand/theme package cannot change these fields, enable telemetry or alter detailed consent. A separately distributed white-label build chooses its own trusted analytics configuration.

The Pichi application stores secrets in Infisical. Its README documents `https://infisical.int.aspirity.com`, project `a155711f-4926-4edb-bb2f-b2cdb82ed76b`, and the `local` environment. The server uses `POSTHOG_KEY`, `POSTHOG_HOST`, and `POSTHOG_ENABLED`; its optional `POSTHOG_PERSONAL_API_KEY` is an administrative credential and must never enter a client build. Project credentials are not checked into this repository.

Prepare only the ingestion token and origin in the current isolated worktree:

```bash
export PICHI_INFISICAL_DOMAIN=https://infisical.int.aspirity.com
export PICHI_INFISICAL_PROJECT_ID=a155711f-4926-4edb-bb2f-b2cdb82ed76b
export PICHI_INFISICAL_ENVIRONMENT=local
bash scripts/dev/analytics-config.sh infisical
```

The helper uses the existing Infisical login and fetches only `POSTHOG_KEY` and `POSTHOG_HOST`. It creates `.build/private/pichi-posthog.xcconfig` with mode `0600`, reports the origin without printing the token, and removes its previous output if refreshing fails. Nothing is sent while preparing the configuration. It does not log in, mutate shared secrets, or request the administrative token.

For a CI runner or an already resolved approved configuration, inject the same ingestion values as `PICHI_POSTHOG_PROJECT_TOKEN` and `PICHI_POSTHOG_HOST` in the process environment, then run `bash scripts/dev/analytics-config.sh env`. Do not put keys on a shell command line. The helper's explicit invocation prepares enabled configuration; set `PICHI_POSTHOG_ENABLED=no` for a disabled distribution.

Pass the generated file to Xcode with `-xcconfig .build/private/pichi-posthog.xcconfig`, using DerivedData and package checkouts inside the same worktree. Avoid printing expanded build settings or sharing build logs that contain the token. Do not use an analytics-enabled distribution as the integration-test host. Standard `macos.sh` and CI tests remain unconfigured and offline.

PostHog project ingestion tokens are public client credentials for sending events, rather than privileged API credentials. They can still be extracted from a distributed app, so the build helper is for configuration hygiene, not a claim that the token remains secret after distribution.

## Payload and consent

- Basic collection remains the existing anonymous daily active-use signal, buffered locally and uploaded weekly. The upstream beta policy also sends aggregate timing distributions if the installed bundle version contains the beta marker. The privacy view discloses both.
- Detailed collection defaults to off when the legacy `ShareAnonymousAnalytics` preference is absent. Existing explicit saved `true` or `false` choices keep their meaning, including settings backup restores. Enabling detailed collection uses the existing settings consent flow. Disabling it advances the consent generation, cancels uploads and securely removes queued detailed events and aggregates. Basic daily activity and beta aggregates follow the existing policy.
- Requests use an ephemeral session without shared cookies, credentials or cache. Redirects are refused.
- [Anonymous events](https://posthog.com/docs/data/anonymous-vs-identified-events) carry a random ID scoped to the local app profile and `$process_person_profile: false`. There are no person updates. Geographic enrichment is disabled and no IP address is added to the payload; the destination necessarily sees the network connection's source address.
- Only typed events and approved property keys are captured. Audio, transcripts, selected text, prompts, AI output, dictionaries, filenames/paths, recording URLs, window titles, customer names and email addresses have no capture API. Events carry `app_product: desktop_voice` and the trusted `app_bundle_id` so desktop usage can be separated from the existing Pichi web project without capturing imported brand names.
- Provider/model dimensions allow only reviewed shipped public identifiers. Custom endpoint labels, models and paths become `custom_provider` / `custom_model`. Previously queued custom identifiers and person updates are sanitized before upload.

## What to measure in PostHog

In the shared project scope Mac charts to `app_product = desktop_voice` and
`app_bundle_id = ai.pichi.voice`. The random analytics ID stays with a local
app profile, including across app updates. One person can appear as multiple
profiles across devices or when switching between a guest and a signed-in
profile. Use the measurement date below for daily charts because uploads can
arrive later.

| Event | Measures | Date or dimensions |
| --- | --- | --- |
| `active_user` | Active profiles and return frequency | `activity_date`, one per local day, uploaded after the local week ends |
| `usage_daily_summary` | Daily dictations, commands, edits, file transcriptions and live meeting starts | `usage_date`; sum the corresponding count field |
| `model_usage_daily_summary` | Use of shipped transcription and enhancement models | `usage_date`, `mode`, `role`, `provider`, `model`; sum `use_count` |
| `onboarding_started`, `onboarding_step_viewed`, `onboarding_step_completed`, `onboarding_completed`, `onboarding_tryout_finished` | Setup progression and tryout results | `flow_id`, `origin`, typed step and outcome where present |
| `model_download_started`, `model_download_finished` | Model setup completion, cancellations and failures | `download_id`, approved model, source, outcome and duration |
| `insertion_latency_daily_summary`, `dictation_performance_daily_summary` | Insertion latency and beta recognition or enhancement performance | Local measurement date, app version and applicable delivery or model dimensions |

`meeting_count` keeps its historical meaning of file transcription attempts after provider and format checks.
`live_meeting_count` counts accepted live recording starts, including a
successful Record Again. It is a daily aggregate that becomes eligible for
upload when the local date changes. Rejected starts and duplicate start
requests are excluded. The metric covers adoption; success of saving audio
and transcription, elapsed recording time and cloud upload are separate
product outcomes. Detailed charts cover profiles that opted in.

This collection is implemented in the macOS app. iPhone and iPad require
mobile target integration and matching privacy disclosures before activation.

## Verification

`bash Tests/run_analytics_config_tests.sh` checks fail-closed configuration, personal-token rejection, no upstream fallback, secure origins, private identifier collapse, older queued payload sanitization, no-cookie transport and refused redirects. `AnalyticsDatabaseTests` checks the stored anonymous flags, local aggregation and detailed opt-out behavior. `SettingsBackupRoundTripTests` checks missing-key consent defaults and preservation of explicit legacy choices in isolated preference suites without accessing application settings. Verify live ingestion using synthetic activity from an isolated configuration and confirm the event UUID and expected sanitized properties in the owning PostHog project. Scope synthetic activity to a dedicated test bundle ID so normal product charts exclude it. An HTTP success alone does not verify ingestion.
