# Initial verification history, October 2026

Historical evidence moved from the development setup guide. All results and remaining gaps below apply to the recorded October revisions and environments. They do not describe the current installed app, CI settings or release status. Current principles live in [AGENTS.md](../../AGENTS.md), with [Testing](testing.md) and [Agent workflow](agent-workflow.md) as the owning guides. The original content is retained below.

## Initial verification on October 9, 2026

- Unsigned macOS build passed on Apple Silicon with Xcode 27.0.
- Configuration parsing, script syntax, documentation links, worktree creation, worktree-only build guard, and setup in a fresh worktree passed.
- The upstream sync helper confirmed that our main contains the current FluidVoice main.
- The upstream build emits compiler warnings and a CTranscribe framework symlink warning. Compilation success does not establish runtime or signed-build behavior.
- These checks established the initial upstream baseline. Pichi feature verification is recorded below; publishing a Codex Cloud environment still requires a fresh cloud task.

## Pichi feature verification on October 9-10, 2026

The feature branch builds on FluidVoice `1.6.10-beta.8`. Verification used macOS 26.6.2, Xcode 27.0 and an Apple Silicon Mac with 128 GB RAM. All build directories and approved private fixtures remained inside ignored local storage.

### Automated verification

| Revision | Result | Scope |
| --- | --- | --- |
| `912bff48` | Release `arm64` and `x86_64` builds and Debug build-for-testing passed | Integrated localization, theme contrast, runtime cleanup and final summary-validation changes; this is compilation evidence, not a new hardware test |
| `912bff48` | 2324 macOS tests, 62 skipped, zero failures in 145.379 seconds | Full regression, including native localization, shared typography, resource ownership and canonical summary limits |
| `912bff48` | 43 opt-in tests, zero skips and failures in 32.617 seconds | Actual optimized GigaAM model and approved Russian audio through the provider, file service, local API controller and pinned meeting ASR; real local summary generation |

The full suite retains the existing upstream Whisper tiny fixture exclusion. Test-host environment variables were applied recursively to the format-2 `.xctestrun`: `FLUIDVOICE_MIC_PHASE1=disabled` and `PICHI_INTERFACE_LANGUAGE=en`. This run does not validate live audio permissions or capture hardware. The opt-in GigaAM cases completed in 7.211 seconds. Summary tests used the configured default `qwen3.5:4b`: a saved Russian session completed in 19.485 seconds, a synthetic decision/task-owner/literal-deadline fixture in 2.870 seconds, and a new unanswered-question fixture with an unrelated later status in 2.749 seconds. The latter retained both unanswered questions without inventing an owner or deadline. Passing these bounded fixtures does not establish semantic correctness for every meeting or candidate model.

Portable checks at `912bff48` passed, including 2612 String Catalog entries, 17 native plural entries and six catalog tests. Separate CoreText probes passed 504 font-design, size, weight and italic combinations for all 66 Russian letters, including `Ё` and `ё`, plus the tested Latin characters, punctuation and combining stress mark. Nine brand/style combinations also passed. Offscreen font specimens are glyph evidence; actual app screenshots provide separate layout evidence.

Independent automated review covered integrated revision `912bff48`, tree `8081f84963ee7480261f91c156f60e7acd5eb3b0`. Three material findings were fixed: selected-sidebar text now uses the shared accent foreground; cached meeting runtime resources are released and profiling reset through the existing joined cleanup hook; and the complete reconciled summary is validated before publication or storage. Three native ownership tests verify cleanup using resource probes without loading model weights. Summary tests accept 15 original citations plus one later citation and reject 16 plus one against the canonical per-item limit of 16, before controller publication and with resource restoration. Review included existing extension-point reuse, cancellation, localization, brand boundaries and upstream merge impact. No material findings remained in the reviewed scope. Static review does not replace permission or interactive tests.

### Interactive evidence

- Frozen revision `37f52643` had working microphone and Accessibility permission checks. The user physically dictated a Russian phrase during onboarding and GigaAM recognized it. Typing recognized text into another application through Accessibility remains unverified.
- The same frozen app passed actual loopback HTTP health and transcription requests. The response identified provider `Pichi GigaAM v3`, processed 110251 samples and returned local Russian text. This complements the controller integration test with a real listener check.
- An empty Google Meet was tested with one participant and its microphone and camera off. Approved past recordings played through a local Chrome player, without sending their contents to Google Meet. Pichi captured the selected Chrome audio, displayed buffered GigaAM live text, completed transcription after stopping and saved the final meeting session. The source included silence and capture noise; this was a functional test, not a measured WER or multi-speaker accuracy benchmark.
- Frozen revision `d475473f` showed Russian onboarding with Russian selected first by default, a Russian main interface, and consistent shared typography. Sber and Alfa-Bank JSON imports updated visible names, colors and official logos. Light and dark themes and native About panels were checked. The About command now uses the localized application label. Imported appearance does not change the installed bundle identity, permission identity or service destinations.
- Frozen revision `912bff48` was launched and its Russian interface and typography checked. The selected sidebar and light-theme toolbar title now remain readable, and the history filter displays the localized `Все` label with a Russian accessibility label. Bank-package proof above is from `d475473f`; it must not be presented as a new bank-package or audio-capture test of `912bff48`.
- Russian summary generation for the saved session completed in the actual `d475473f` UI through the local endpoint. Human review found a question paraphrased as a fact and omitted topics. A separate `qwen3.5:9b` candidate regression falsely resolved an unanswered question using an unrelated later quote despite valid source identifiers and literal evidence. Selected reasoning-mode probes improved specific cases but failed a cancellation case within the output budget, so no experimental prompt, verifier or reasoning policy was adopted. Summary generation and citation validation work, but the general semantic quality gate remains open. The configured default remains `qwen3.5:4b`, which passed the new bounded synthetic unanswered-question regression at `912bff48`.
- The native onboarding flow produced `onboarding_started` and `onboarding_step_viewed` events received by our own Pichi PostHog project with `app_product=desktop_voice` and `app_bundle_id=ai.pichi.voice`. Detailed analytics was subsequently switched off, and analytics and local API test preferences were restored to their original unset state, which defaults to off.
- Screenshots are saved by test-plan identifier in ignored local storage. The `37f52643` video evidence includes a 12-second continuous live-text view and a 40-second condensed recording with an explicit omitted-gap caption. These videos show that revision's UI, including capture-warning English copy localized in later source; they are not evidence of completed capture on `d475473f` or `912bff48`.

Repeat the full suite with `bash scripts/dev/macos.sh test`. Real inference remains opt-in; see [GigaAM verification](../../Vendor/PichiGigaAM/README.md) and [Russian summary verification](russian-meetings.md#verification). Keep private fixture paths out of committed configuration.

### Remaining validation and release work

The frozen ad-hoc-signed `912bff48` copy has a different code identity from the earlier tested copies. Microphone and Accessibility authorization have not been validated for `912bff48`. The previous `d475473f` copy had confirmed Accessibility and an enabled system-audio permission switch, but microphone authorization remained pending. An enabled Settings row alone is not proof that the app received authorization or captured audio. Final-revision permission, capture and meeting E2E therefore remain incomplete; the successful `37f52643` capture must not be reported as a pass for a later copy. No valid local development or distribution signing identity was available; no permission database reset, weakened signing requirement or global trust change was used. Manual onboarding replay was cleaned up by restoring the previously completed onboarding state, without marking microphone authorization as granted.

The bounded-context `qwen3.5:4b` adapter was measured at approximately 3.15 GiB of model memory with an 8192-token context and released the model after the request. Physical Intel and 8 GB devices remain untested. Summary semantic regressions and external Accessibility typing still require verification. Signing for distribution, notarization, a Pichi update feed and a distributable optimized-model destination are separate release work. The installed FluidVoice application and its recordings were not modified. These local results do not establish current published CI or Codex Cloud readiness.

Current policy: [Testing](testing.md) and [Agent workflow](agent-workflow.md).
