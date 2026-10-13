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

## Reproducible macOS regression

Run `bash scripts/dev/standalone-regression.sh` for the registered standalone probes. The registry covers all 37 current runners, including the native export, relative-date and contrast probes. It invokes shell and Python scripts with their declared interpreters, verifies registry coverage before execution, and continues through failures to retain a complete result. A changed script interpreter or unregistered runner requires a registry update.

Full runs require an isolated worktree, macOS and full Xcode. The runner prevents simultaneous standalone runs in one worktree. `--list` lists the names without starting native probes and is portable. Narrow a repeat run with repeated `--only NAME` options:

```bash
bash scripts/dev/standalone-regression.sh --list
bash scripts/dev/standalone-regression.sh --only file_export --only file_transcript_relative_date --only ui_contrast
```

Each probe owns a separate process session. INT and TERM trigger bounded TERM/KILL cleanup, wait for runnable descendants to stop and reap the direct process before releasing the worktree lock. Reports retain the runner's 130/143 status separately from the direct child's actual exit code. If cleanup cannot finish, its ownership marker blocks another suite from using those build directories. Signal delivery during process creation is deferred until its owner and marker are stored, without changing the child's inherited signal mask.

The update prompt probe can activate test UI. It is recorded as `SKIP` by default and runs only with the explicit `--include-ui` flag. Selecting it with `--only update_prompt` does not implicitly enable UI. Skipped probes are never counted as passes, and an all-skipped run returns failure.

Every started suite keeps `summary.json`, `summary.txt` and one combined stdout/stderr log per selected probe under a unique ignored `.build/standalone-regression/` directory. Reports include the exact revision, dirty/clean state, interpreter, argv, exit code, duration and PASS/FAIL/SKIP accounting. Any failed probe, missing script, launch error or interrupted run returns nonzero. These counts describe standalone probes, not the assertions reported inside each probe or full application XCTest coverage. Setup errors stop before starting the suite. Verify runner behavior portably with `python3 -S Tests/test_standalone_regression.py`.

The separate `FluidASRBaseline` scheme has an explicit fixture staging contract and keeps Xcode user script sandboxing enabled. Its default declarations copy only the tracked public placeholder. To bundle an authorized local fixture directory, prepare private input/output filelists and a manifest under the current worktree's ignored `.build/asr-baseline-inputs/`:

```bash
pichi_baseline_config="$(python3 -S scripts/dev/asr-baseline-inputs.py prepare /absolute/approved/fixtures)"
xcodebuild -project Fluid.xcodeproj -target FluidASRBaselineHost -configuration Debug \
  -clonedSourcePackagesDirPath "$PWD/.build/SourcePackages" \
  OBJROOT="$PWD/.build/Xcode/Build/Intermediates.noindex" \
  SYMROOT="$PWD/.build/Xcode/Build/Products" clean
xcodebuild -project Fluid.xcodeproj -scheme FluidASRBaseline \
  -xcconfig "$pichi_baseline_config" -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PWD/.build/Xcode" \
  -clonedSourcePackagesDirPath "$PWD/.build/SourcePackages" test
```

Preparation deterministically enumerates regular files with bounded counts and sizes, rejects symlinks and unsafe paths, and pins the selected input directory. Staging copies only those declared files with bounded memory. A changed directory or file set requires cleaning the baseline products, so resources from a previous private fixture set cannot survive a successful build. Changed file sizes require preparing the declarations again. Keep fixture data and generated declarations local; they are not application resources or a distributable build. The scheme's benchmark remains opt-in through its existing `FLUID_ASR_RUN_BENCHMARK` test environment flag.

Run `bash scripts/dev/macos.sh regression` in the current task worktree. This uses the existing isolated build and package paths, builds Debug test products, recursively configures every test target, then runs `test-without-building`. It retains the upstream Whisper tiny exclusion. The existing test-host guard receives `FLUIDVOICE_MIC_PHASE1=disabled`, so the normal application UI/audio startup and the Phase 1 microphone probe are disabled. Other hardware, UI and real-model probes remain opt-in through their existing test gates. This command does not establish interactive E2E coverage.

`PICHI_INTERFACE_LANGUAGE` defaults to `en` for upstream assertions, independently of the user's stored language. An explicit caller value is retained. Caller environment variables with prefixes `PICHI_`, `FLUIDVOICE_`, `FLUIDAUDIO_`, `FV_`, and `TEST_`, plus `CI` and `GITHUB_ACTIONS`, are copied to the test host. This preserves existing real-model fixture opt-ins, such as `PICHI_GIGAAM_APP_TEST_MODEL_DIR` and `PICHI_GIGAAM_APP_TEST_AUDIO`. Phase 1 microphone capture remains disabled even if the caller supplies its flag. Fixture paths and test products stay in ignored local storage; never commit private fixtures or the generated plist.

Optional `-only-testing:target/class/test` and `-skip-testing:target/class/test` selectors narrow a repeat run. For example:

```bash
bash scripts/dev/macos.sh regression -only-testing:FluidDictationIntegrationTests/PichiGigaAMIntegrationTests
```

Each run prints its artifact directory under `.build/regression/`. It keeps the revision and working-tree state, build/test logs, both `.xcresult` bundles, and the test report's JSON and concise summary. Counts come from `xcresulttool`, including skipped and expected-failure tests. Build failures, test failures, empty/all-skipped runs, and absent or malformed reports return failure. The configured `.xctestrun` stays beside its build products because Xcode resolves `__TESTROOT__` relative to that file. Python 3 and Xcode with `xcresulttool get test-results summary` are required. Do not run concurrent builds in one worktree.

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
