# Pichi Voice development setup

This document owns setup and command details. [AGENTS.md](../../AGENTS.md) defines shared principles; [Testing](testing.md) owns coverage and test storage, and [Agent workflow](agent-workflow.md) owns coordination, native acceptance and cleanup. Read the relevant guide before using the commands below.

For public Mac packaging, see [macOS distribution](macos-distribution.md).

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

Run `bash scripts/dev/standalone-regression.sh` for the registered standalone probes. The registry covers every `Tests/run_*` runner and lists the checks that live elsewhere by hand; `--list` prints them. The `scripts/dev/test-*.sh` probes that load real models stay manual and unregistered. It invokes shell and Python scripts with their declared interpreters, verifies registry coverage before execution, and continues through failures to retain a complete result. A changed script interpreter or unregistered runner requires a registry update.

Full runs require an isolated worktree, macOS and full Xcode. The runner prevents simultaneous standalone runs in one worktree. `--list` lists the names without starting native probes and is portable. Narrow a repeat run with repeated `--only NAME` options:

```bash
bash scripts/dev/standalone-regression.sh --list
bash scripts/dev/standalone-regression.sh --only file_export --only file_transcript_relative_date --only ui_contrast
bash scripts/dev/standalone-regression.sh --jobs 8
```

`--jobs N` runs N probes at once, with the same process ownership, cleanup and report as one at a time. Use it for a full run: 105 probes take about 5 minutes with 8 jobs instead of about 22 minutes. Timing-sensitive runs and performance measurements stay sequential.

Each probe owns a separate process session. INT, TERM and HUP trigger bounded TERM/KILL cleanup, wait for runnable descendants to stop and reap the direct process before releasing the worktree lock. Reports retain the runner's 130/143 status separately from the direct child's actual exit code. If cleanup cannot finish, its ownership marker blocks another suite from using those build directories. Signal delivery during process creation is deferred until its owner and marker are stored, without changing the child's inherited signal mask.

The `participant_input_contrast` probe compiles the complete participant sheet with inert meeting metadata and the actual shared theme/actions. Its never-visible, non-key windows test the sheet's own appearance boundary, retained native editor/drafts, caret contrast of at least 3, and inactive selection contrast of at least 3; ordinary typed text requires 4.5. Field-only rasters additionally cover empty hints and disabled controls. These checks do not establish active selection or exact application sheet appearance. Frozen application screenshots and physical focus/selection in both themes remain required native acceptance gates.

The update prompt probe can activate test UI. It is recorded as `SKIP` by default and runs only with the explicit `--include-ui` flag. Selecting it with `--only update_prompt` does not implicitly enable UI. Skipped probes are never counted as passes, and an all-skipped run returns failure.

Every started suite keeps `summary.json`, `summary.txt` and one combined stdout/stderr log per selected probe under a unique ignored `.build/standalone-regression/` directory. Reports include the exact revision, dirty/clean state, interpreter, argv, exit code, duration and PASS/FAIL/SKIP accounting. Any failed probe, missing script, launch error or interrupted run returns nonzero. These counts describe standalone probes, not the assertions reported inside each probe or full application XCTest coverage. Setup errors stop before starting the suite. Verify runner behavior portably with `python3 -S Tests/test_standalone_regression.py`.

The registered `diarization_repeatability` probe runs standard-library comparator tests against invented metadata only. It does not run speech models, inspect app history or change preferences. The optional [check-diarization-repeatability.py](../../scripts/dev/check-diarization-repeatability.py) command compares two caller-supplied raw diarizer JSON artifacts:

```bash
python3 -S scripts/dev/check-diarization-repeatability.py \
  .build/diarization/raw-run-a.json .build/diarization/raw-run-b.json \
  --tolerance-seconds 0.1
```

Each artifact must contain `segments`, with string `speakerID` and numeric `start`/`end` seconds. Arbitrary speaker IDs are normalized by chronological first appearance; a bounded global ID bijection handles allowed jitter that changes simultaneous first-appearance order. Metadata such as embeddings or text does not enter the comparison or report. Inputs must resolve to regular files, including through symlinks; nonblocking open plus descriptor validation rejects FIFOs, devices and directories before reading. Inputs are limited to 8 MiB, 10,000 segments, 256 distinct speakers, 256-character printable IDs and timestamps from 0 through 86,400 seconds. Positive duration is required. Cross-speaker overlap is supported; same-speaker overlapping slices are outside this raw-turn diagnostic contract and return `ERROR`. Boundary tolerance must be finite and from 0 through 60 seconds; zero requires exact boundaries. Boolean/nonnumeric times, nonfinite JSON numbers, duplicate keys and malformed artifacts return `ERROR` with exit 2. A changed speaker partition, segment count or boundary beyond tolerance returns `FAIL` with exit 1; equivalent partitions return `PASS` with exit 0. Reports contain counts and stable reason codes, without transcript content, raw speaker names or input paths.

This diagnostic compares repeatability, not speaker-identity accuracy. Even two empty artifacts compare equal; they do not prove usable transcription. On the observed synthetic `d346e915` run, repeated exact-two-speaker inference changed meaningful partitions after ID normalization. The pinned engine's public API does not promise deterministic partitions or expose its internal clustering seed. That observed limitation remains unresolved. Passing comparator self-tests does not fix engine quality, establish an audited two-voice reference, or replace a real-model regression with verified speaker provenance. Keep supplied audio, model weights, raw inference artifacts and history outside Git.

The registered `local_api_live_harness` probe runs portable harness self-tests with fake sockets and synthetic metadata. It performs no live HTTP or application inference. The separate [local-api-live.py](../../scripts/dev/local-api-live.py) command defaults to `DRY_RUN`; only `--run-live` permits requests against a caller-selected, already running frozen app:

```bash
python3 -S scripts/dev/local-api-live.py --run-live \
  --endpoint http://127.0.0.1:47733 \
  --app-pid "$pichi_frozen_pid" --app-bundle "$pichi_frozen_bundle" \
  --bundle-id "$pichi_frozen_bundle_id" \
  --synthetic-audio "$pichi_synthetic_wav" --timeout 120 \
  --expect-provider "$pichi_expected_provider" \
  --expect-text-contains "$pichi_synthetic_phrase"
```

Supply absolute paths. `--synthetic-audio` is an explicit attestation that the regular PCM WAV contains only synthetic speech, never a personal recording. The file must be 1-2 channels, 8-48 kHz, at most 30 seconds and 16 MiB. The optional provider and phrase expectations compare in memory without rewriting model output; omit them for provider-neutral shape checks. The harness does not launch the app, enable its API, change preferences, select/download models or grant permissions. Enable and validate the API through the authorized frozen-app UI workflow first.

Before every request and after its response, the harness verifies the supplied PID's native executable path and exclusive ownership of the TCP listener; bundle metadata must match the explicit bundle identifier, and health must match its version. Only literal loopback addresses are accepted, without DNS, proxies, credentials or redirects. The ten cases cover socket health, unknown route, method error, malformed HTTP/JSON, invalid Content-Length, missing/invalid audio and one path-based transcription. Successful transcription requires nonempty text/provider, finite confidence, and a sample count matching the caller's fixture. No history, meeting, dictionary or postprocess route is accessed. There is no public HTTP cancellation route; existing lease/connection tests cover that internal contract separately.

Non-inference requests have a total deadline of at most 5 seconds; transcription defaults to 120 seconds and cannot exceed 180. Headers are limited to 8 KiB and response bodies to 64 KiB. The first failure stops later requests. Empty, incomplete, failed or skipped runs cannot report live success. A private directory under ignored `.build/local-api-live-*/` retains a compact `summary.json` with case/status/counts and fixed failure codes. It excludes request/response bodies, transcripts, expected phrases, fixture/bundle paths, error descriptions and credentials. A safe default run and a passing harness self-test do not prove live API E2E.

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

`macos.sh regression` builds with the separate identity `ai.pichi.voice.regression` and its own derived data directory `.build/XcodeRegression`. That costs about 2 GB more per worktree but leaves the product of `macos.sh build` untouched. The first run under this identity downloads about 1 GB of models into `~/Library/Application Support/ai.pichi.voice.regression.debug`, and later runs reuse them. Tests still leave UUID-named preference files in `~/Library/Preferences`, which this script does not remove because it cannot tell its own files from another process's files. `macos.sh test`, which CI uses, has no separate identity.

Each run prints its artifact directory under `.build/regression/`. It keeps the revision and working-tree state, build/test logs, both `.xcresult` bundles, and the test report's JSON and concise summary. Counts come from `xcresulttool`, including skipped and expected-failure tests. Build failures, test failures, empty/all-skipped runs, and absent or malformed reports return failure. The configured `.xctestrun` stays beside its build products because Xcode resolves `__TESTROOT__` relative to that file. Python 3 and Xcode with `xcresulttool get test-results summary` are required. Do not run concurrent builds in one worktree.

## Initial verification on October 9, 2026

Historical results are retained in [Initial verification history](initial-verification-2026-10.md#initial-verification-on-october-9-2026). They apply only to those revisions.

## Pichi feature verification on October 9-10, 2026

Feature results and then-open validation gaps are retained in [Initial verification history](initial-verification-2026-10.md#pichi-feature-verification-on-october-9-10-2026). Recheck current sources and artifacts before making a present-tense claim.

## Test exceptions

`Tests/quarantine.json` lists known failures, each with an owner, a reason and an expiry date at most 90 days away. An entry with `"scope": "ci"` applies only on the CI runner (`GITHUB_ACTIONS=true`), whose image draws at 1x scale on a newer macOS; developer Macs keep running that test. `Tests/skip-registry.json` gives every skipped test a reason and the layer that should run it. `check.sh` runs `scripts/dev/check-test-policy.py` on the files only (shape, owners, expiry), so an expired entry fails the repository check. The gate script `scripts/dev/verify` leaves quarantined XCTest cases and probes out of its runs and passes its results to the checker with `--results <map.json> --complete`. With `--results` a skip without a registry entry fails. Only with `--complete`, which says every bundle in the map ran completely, does a registry entry for a test missing from the map fail as well.

## CI and cleanup

`python3 -S scripts/dev/lint-changed.py` lints only the Swift lines a branch changed. The repository has a large inherited baseline, so `force_cast`, `force_try` and `force_unwrapping` in `Sources/` block a change and every other rule is a note, including anything in `Vendor/`. The same check runs on each PR in `pichi-ci.yml`.

[Pichi Voice CI](../../.github/workflows/pichi-ci.yml) runs portable checks. Its macOS job runs `python3 -S scripts/dev/verify --layer L1` on the `xcode-27` runner: dispatch the workflow manually with `run_macos` selected, or set the repository variable `PICHI_VOICE_MACOS_CI` to `true` to run it on every pull request to `main` and every push to `main`. Quarantined tests stay out of that run, so a red result means a new failure.

Upstream community moderation and archive workflows are retained but guarded to run only in `altic-dev/FluidVoice`. Our repository does not inherit their scheduled issue closing or comment policies.

Inspect current repository visibility, plan, branch rules and enabled job conditions before describing enforcement. Worktree and review requirements are development policy; a document alone does not create GitHub branch protection or run native CI. See [Testing](testing.md#ci-and-review) and [GitHub branch protection availability](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches).

After review and integration, follow the canonical [resource lifecycle and cleanup](agent-workflow.md#resource-lifecycle-and-cleanup). Preserve needed ignored artifacts independently before archiving a task worktree.

## Hosted mobile acceptance

In Debug simulator builds, `PICHI_MOBILE_HOSTED_FIXTURE=1`,
`PICHI_NATIVE_HTTP_ACCEPTANCE=1` or `PICHI_NATIVE_QA_ACCEPTANCE=1` selects an inert
app host. Hosted fixtures own their injected service composition; the HTTP fixtures
own their account, profile, recording coordinator and publication service.
The host skips its ordinary private UI and app lifecycle service events, preventing
an unrelated production account restoration from competing for the shared profile
scope. Release builds and ordinary app launches retain their existing behavior.

The generic hosted-fixture flag does not enable HTTP cases. Local and QA HTTP
acceptance still require their existing opt-in flags and validated configuration.
The UI-test app runs in a separate process without the hosted-fixture flag.

HTTP checks exercise service composition, encrypted persistence and actual HTTP
delivery. They do not establish acceptance of the app UI, microphone or real ASR.

## See also

- [Agent instructions](../../AGENTS.md)
- [Testing policy and repository map](testing.md)
- [Agent workflow and native acceptance](agent-workflow.md)
- [Upstream and extension strategy](upstream.md)
- [Codex worktrees](https://learn.chatgpt.com/docs/environments/git-worktrees)
- [Local environments](https://learn.chatgpt.com/docs/environments/local-environment)
- [Cloud environments](https://learn.chatgpt.com/docs/environments/cloud-environments)
