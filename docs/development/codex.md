# Pichi Voice development setup

## Repository and checkout

The primary checkout is a normal clone of [Pichi-AI/pichi-voice](https://github.com/Pichi-AI/pichi-voice). The code descends from [FluidVoice](https://github.com/altic-dev/FluidVoice), with its main history retained.

The shared setup script configures a read-only `upstream` on fresh local and cloud clones. It stops for review if an existing upstream points somewhere else.

| Remote | Role |
| --- | --- |
| `origin` | Pichi Voice branches, PRs, and releases |
| `upstream` | Read-only FluidVoice source updates |

For another computer, clone our repository, then configure the upstream:

```bash
git clone https://github.com/Pichi-AI/pichi-voice.git
cd pichi-voice
git remote add upstream https://github.com/altic-dev/FluidVoice.git
git config remote.upstream.fetch '+refs/heads/main:refs/remotes/upstream/main'
git config remote.upstream.pushurl DISABLED
git config remote.pushDefault origin
git fetch upstream main --tags
```

Only upstream `main` needs a tracking ref. Its other feature branches are not part of our update workflow and include names that collide on a case-insensitive macOS filesystem. This restriction does not discard the main commit history.

## New local sessions

1. Select the **Pichi Voice** project in Codex.
2. Select **Worktree**, start from the current `main`, and select the **Pichi Voice** local environment.
3. Send the task. The app creates a separate managed worktree and runs [setup.sh](../../scripts/dev/setup.sh).
4. Create a unique `codex/<task>` branch in the worktree before committing. Commit and push that branch to `origin`; review and merge through a PR.

The checked-in [environment.toml](../../.codex/environments/environment.toml) uses the local environment schema verified in the installed app. It supplies prerequisite checks and macOS build/test actions. A new chat should verify that the environment is selected and that setup succeeded.

The [SessionStart hook](../../.codex/hooks/session-start.py) reminds an agent when it is in the primary checkout. It cannot switch the chat's working directory or force the app's composer into Worktree mode. Project hooks require a trusted repository. [AGENTS.md](../../AGENTS.md) also requires worktree creation before edits if a chat starts in Local. This is a workflow rule, not an operating-system write barrier.

For terminal use or a cloud workspace:

```bash
bash scripts/dev/new-worktree.sh russian-provider
# Change into the absolute path printed by the script.
bash scripts/dev/setup.sh
```

`new-worktree.sh` fetches the latest `origin/main`, creates a unique branch, and puts the worktree beside the primary checkout. Set `PICHI_VOICE_WORKTREE_ROOT` to use another writable location. Native Codex-managed worktrees use the app's own worktree root instead.

Use the same worktree when resuming a chat. Create a new one for a different outcome. Each worktree keeps its own DerivedData and source package checkout; dependencies resolve during the first macOS build. Model weights and personal data are not copied automatically.

## Codex Cloud

A local project entry does not create a cloud environment. Publish a separate environment for this repository:

1. Open **Work in > Cloud > Select environment > Create environment**, or **Settings > Codex Cloud > Environments**.
2. Select only `Pichi-AI/pichi-voice`. If GitHub access is requested, grant access to this repository through the normal connector flow.
3. Ask setup to install Git, Bash, and Python 3.11 or later and run `bash scripts/dev/setup.sh --allow-primary`. Keep access private during initial development.
4. Review the setup result and choose **Publish**.
5. Start a fresh cloud task and verify checkout, worktree creation, and `bash scripts/dev/check.sh` before declaring the environment ready.

Suggested environment setup request:

> Prepare a private environment for Pichi-AI/pichi-voice. Install Git, Bash, and Python 3.11 or later. Run bash scripts/dev/setup.sh --allow-primary. For each coding task, follow AGENTS.md and create a separate linked worktree before edits. Do not download speech models or copy local dictionaries, recordings, signing material, or credentials. Run portable checks. Report macOS compilation and audio validation as requiring a separate Mac.

Each cloud task receives its own isolated filesystem. A linked worktree inside that task also keeps the explicit repository policy consistent. Local worktrees, Mac Keychain entries, Xcode, running apps, and ignored local files are not automatically available in Cloud. The cloud task must commit and push its branch before another computer can fetch its changes.

| Environment | Verification |
| --- | --- |
| Cloud or Linux | Repository checks, scripts, review, and any separately added portable tests |
| Mac with Xcode | Swift/macOS compilation, integration tests, CoreML compatibility |
| Interactive Mac | Microphone, audio routing, Accessibility typing, UI, and latency checks |

A green portable check does not replace macOS validation. The initial setup does not compile or launch the unchanged upstream app. Before installing a Pichi-branded build, separate its bundle identity, settings, Keychain entries, and updater from the installed FluidVoice app.

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
| `56f77326` | Release `arm64` and `x86_64` builds and Debug build-for-testing passed | Includes the localized microphone-setup action added after `d475473f`; this is compilation evidence, not a new hardware test |
| `d475473f` | 2318 macOS tests, 61 skipped, zero failures in 143.239 seconds | Full regression, including native localization, analytics consent, shared typography and localized settings alerts |
| `dd07609f` | 40 opt-in tests, zero skips and failures in 30.397 seconds | Actual optimized GigaAM model and approved Russian audio through the provider, file service, local API controller and pinned meeting ASR; real local summary generation |

The full suite retains the existing upstream Whisper tiny fixture exclusion. Test-host environment variables were applied recursively to the format-2 `.xctestrun`: `FLUIDVOICE_MIC_PHASE1=disabled` and `PICHI_INTERFACE_LANGUAGE=en`. This run does not validate live audio permissions or capture hardware. The opt-in summary tests used `qwen3.5:4b`: a saved Russian session completed in 19.313 seconds, and a synthetic fixture with a decision, task owner and literal deadline completed in approximately 3.68 seconds. Passing these fixtures does not establish semantic correctness for every meeting.

Portable checks at `56f77326` passed, including 2611 String Catalog entries, 17 native plural entries and six catalog tests. Separate CoreText probes passed 504 font-design, size, weight and italic combinations for all 66 Russian letters, including `Ё` and `ё`, plus the tested Latin characters, punctuation and combining stress mark. Nine brand/style combinations also passed. Offscreen font specimens are glyph evidence; actual app screenshots provide separate layout evidence.

Independent automated reviews covered the integrated summary and typography changes at `dd07609f`, the settings-copy follow-up at `d475473f`, and the final microphone-label change at `56f77326`, tree `7777c65748e34b24aca0321f922b0b893fd5d972`. No material findings remained in those reviewed scopes. Review included existing extension-point reuse, resource ownership, cancellation, source-evidence handling, localization and brand boundaries. Static review does not replace permission or interactive tests.

### Interactive evidence

- Frozen revision `37f52643` had working microphone and Accessibility permission checks. The user physically dictated a Russian phrase during onboarding and GigaAM recognized it. Typing recognized text into another application through Accessibility remains unverified.
- The same frozen app passed actual loopback HTTP health and transcription requests. The response identified provider `Pichi GigaAM v3`, processed 110251 samples and returned local Russian text. This complements the controller integration test with a real listener check.
- An empty Google Meet was tested with one participant and its microphone and camera off. Approved past recordings played through a local Chrome player, without sending their contents to Google Meet. Pichi captured the selected Chrome audio, displayed buffered GigaAM live text, completed transcription after stopping and saved the final meeting session. The source included silence and capture noise; this was a functional test, not a measured WER or multi-speaker accuracy benchmark.
- Frozen revision `d475473f` showed Russian onboarding with Russian selected first by default, a Russian main interface, and consistent shared typography. Sber and Alfa-Bank JSON imports updated visible names, colors and official logos. Light and dark themes and native About panels were checked. The About command now uses the localized application label. Imported appearance does not change the installed bundle identity, permission identity or service destinations.
- Russian summary generation for the saved session completed in the actual `d475473f` UI through the local endpoint. Human review found a question paraphrased as a fact and omitted topics. A separate candidate-model regression falsely resolved an unanswered question using an unrelated later quote despite valid source identifiers and literal evidence. Summary generation and citation validation work, but the semantic quality gate remains open. Additional model and reasoning tests are ongoing; the configured default remains `qwen3.5:4b`.
- The native onboarding flow produced `onboarding_started` and `onboarding_step_viewed` events received by our own Pichi PostHog project with `app_product=desktop_voice` and `app_bundle_id=ai.pichi.voice`. Detailed analytics was subsequently switched off, and analytics and local API test preferences were restored to their original unset state, which defaults to off.
- Screenshots are saved by test-plan identifier in ignored local storage. The `37f52643` video evidence includes a 12-second continuous live-text view and a 40-second condensed recording with an explicit omitted-gap caption. These videos show that revision's UI, including capture-warning English copy localized in later source; they are not evidence of completed capture on `d475473f` or `56f77326`.

Repeat the full suite with `bash scripts/dev/macos.sh test`. Real inference remains opt-in; see [GigaAM verification](../../Vendor/PichiGigaAM/README.md) and [Russian summary verification](russian-meetings.md#verification). Keep private fixture paths out of committed configuration.

### Remaining validation and release work

The later ad-hoc-signed `d475473f` copy has a different code identity from `37f52643`. Accessibility was confirmed for that exact copy and its system-audio permission switch was enabled through macOS, but microphone authorization remained pending. An enabled Settings row alone is not proof that the app received authorization or captured audio. Final-revision permission, capture and meeting E2E therefore remain incomplete; the previous build's successful capture must not be reported as a pass for the later copy. No permission database reset, weakened signing requirement or global trust change was used. Manual onboarding replay was cleaned up by restoring the previously completed onboarding state, without marking microphone authorization as granted.

The bounded-context `qwen3.5:4b` adapter was measured at approximately 3.15 GiB of model memory with an 8192-token context and released the model after the request. Physical Intel and 8 GB devices remain untested. Summary semantic regressions and external Accessibility typing still require verification. Signing for distribution, notarization, a Pichi update feed and a distributable optimized-model destination are separate release work. The installed FluidVoice application and its recordings were not modified. These local results do not establish current published CI or Codex Cloud readiness.

## CI and cleanup

[Pichi Voice CI](../../.github/workflows/pichi-ci.yml) runs portable checks. For macOS testing, manually dispatch the workflow with `run_macos` selected. To enable macOS testing on every code change, set the repository variable `PICHI_VOICE_MACOS_CI` to `true` after reviewing runner usage and the baseline results.

Upstream community moderation and archive workflows are retained but guarded to run only in `altic-dev/FluidVoice`. Our repository does not inherit their scheduled issue closing or comment policies.

The organization currently uses GitHub Free. GitHub does not provide protected branches for a private organization repository on that plan. The PR and worktree rules are therefore process rules during private development. Enable main-branch protection with the Repository checks status when the repository becomes public, or if the organization moves to GitHub Team. See [protected branch availability](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches).

Merge reviewed task branches, fetch the updated `main`, and start new work from it. Archive managed worktrees through Codex after checking that needed work is pushed. Remove manually created worktrees with `git worktree remove <path>` after confirming that their work is saved. Do not remove another active session's worktree.

## See also

- [Agent instructions](../../AGENTS.md)
- [Upstream and extension strategy](upstream.md)
- [Codex worktrees](https://learn.chatgpt.com/docs/environments/git-worktrees)
- [Local environments](https://learn.chatgpt.com/docs/environments/local-environment)
- [Cloud environments](https://learn.chatgpt.com/docs/environments/cloud-environments)
