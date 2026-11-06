# Pichi Voice

Pichi Voice is a downstream of [FluidVoice](https://github.com/altic-dev/FluidVoice).
Our repository is [Pichi-AI/pichi-voice](https://github.com/Pichi-AI/pichi-voice).
Read [development setup](docs/development/codex.md) and [upstream strategy](docs/development/upstream.md).

## Session isolation

**CRITICAL:** Every new coding session MUST use its own Git worktree. The primary checkout is for fetching and integrating reviewed branches.

- In the Codex app, start with **Worktree**, based on the current `main`, and use the **Pichi Voice** local environment.
- If a session starts in the primary checkout, create a worktree with the app's worktree tool or `bash scripts/dev/new-worktree.sh <task-slug>` before editing. Use the returned directory for every subsequent command and edit. The app tool does not change the shell's default directory.
- In Codex Cloud, each task already has an isolated workspace. For the same explicit worktree policy, create a linked worktree inside that workspace before editing. Do not share a worktree between cloud tasks.
- Environment installation may check prerequisites in the primary checkout with `bash scripts/dev/setup.sh --allow-primary`; this is not authorization to edit application code there.
- A Codex-managed worktree may begin with detached HEAD. Create a unique `codex/<task-slug>` branch before committing or publishing work. Never check out a branch that another worktree owns.
- Do not edit `main` directly. Do not delete other sessions' worktrees, discard their changes, or force-push published branches.

## Parallel agents and integration

**IMPORTANT:** Use parallel agents for independent implementation, research and review when that speeds up the task. Each coding agent **MUST** use a separate Git worktree and a unique `codex/<task>` branch; never let concurrent agents edit the same checkout.

- Give each agent a bounded scope, the relevant existing contracts, the starting commit and the checks it owns. Every agent must read these instructions, including the architecture requirements below.
- The parent agent owns integration. Review each completed branch's diff, integrate its commits into the parent task worktree, resolve conflicts there and run checks against the combined result. Do not treat passing isolated checks as proof that the integrated app works.
- Keep native build directories, package checkouts and private test artifacts isolated per worktree. The parent coordinates interactive testing and may assign distinct owned simulators and test containers to agents for parallel runs. The physical device, foreground desktop UI, microphone and audio routing each require one explicit owner; never compete for them.
- Run an independent code review against the integrated commit. Record the reviewed revision, fix material findings and repeat the affected checks before publishing. Stop completed child agents after collecting their results.

## Short iterations and verification cost

**CRITICAL:** Deliver the smallest verified, usable change. More tests, agents or artifacts are not evidence of better delivery. Preserve privacy, signing and resource ownership without turning a small change into a regression campaign.

- Before expensive work, state the acceptance behavior, affected contracts, selected checks and the slowest expected dependency. Choose a bounded verification set, not every available test command. For a small change, target a usable increment within 10 minutes; if compilation alone exceeds that, say so up front. At that boundary, reassess scope and remove unnecessary work instead of silently expanding the run.
- Use this default scope. Documentation/instruction edits: diff, links and consistency only. Local UI edits: affected target build plus the changed native states. Local behavior edits: focused tests for the changed contract and one relevant integration check. A mute-state change normally needs transition tests, one actual writer exclusion/resume check and a short smoke test in each requested conferencing platform. Privacy sensitivity requires checking the real admission boundary; it does not automatically require the full suite.
- Broaden checks only for an explicit user requirement, a concrete failure, or a changed shared contract with named consumers. Before broadening, identify the uncovered failure and the check that resolves it. Do not add model runs, hardware matrices, exhaustive UI permutations, unrelated recovery tests, benchmarks or a new test framework speculatively.
- **STOP verification** when the selected checks pass, the requested behavior is observed and no material finding remains. Do not repeat passing checks for reassurance, status updates, a merge commit, or documentation-only changes. Hypothetical edge cases must not indefinitely delay a usable increment; handle a material risk with a targeted fix/check and keep unrelated issues separate.
- For a small, tightly coupled change, use one implementation owner and one bounded independent code review. Add agents only for useful independent work that shortens the critical path. Do not create overlapping research, implementation and repeated review assignments for the same question.
- Freeze the candidate before expensive validation. Build each required configuration once per relevant source revision. A test build already establishes compilation; do not add a separate identical build. Build Release only when distribution/installation requires it. After a fix, repeat only invalidated checks and reuse unaffected results with their actual tested revision.
- Check the installed app revision, current activity and other task ownership before planning an installation build. Never overwrite a newer feature build with an older baseline. Integration needs a concrete compatibility decision before another full build, not after it.
- Pin input branch/PR SHAs and recheck them before publication. Keep tests bound to immutable inputs. Reuse results only when relevant source, resources, configuration, toolchain and test inputs are unchanged or equivalence is demonstrated. Record revision, scope, result and duration in one compact existing evidence location. Do not present reused results as fresh runtime acceptance.
- Prefer one short end-to-end smoke test early. For native UI, capture each distinct changed acceptance state, including relevant light/dark appearances, rather than every navigation click or identical frame. Run exhaustive sequences only when their specific contract changed or the user requested them. First-use tests still need an isolated container; real-model tests still need separately owned fixtures and resources.
- If a test harness stalls or a permission path fails, diagnose it once with a bounded probe. Do not keep raising timeouts, rebuilding, adding agents or repeating the same UI sequence without new evidence. Report the exact remaining acceptance gap and preserve the working increment.

## Resource scheduling and coordination

- **MUST** parallelize independent implementation, review and checks when this shortens completion time. Delegate bounded work with a clear output, owned resources and completion condition. Keep trivial or tightly coupled edits with one agent; do not create extra agents or worktrees without useful independent work.
- Before expensive jobs, inspect available CPU, memory pressure and existing task ownership once. Choose concurrency from the actual resource budget, leaving headroom for the user's work. Parallelize isolated builds, lightweight checks and simulator UI runs when capacity permits; avoid both blanket single-job serialization and unbounded fan-out. Reduce concurrency if swapping, contention or degraded responsiveness appears.
- Identify the owner and IDs/paths for each simulator, build directory, model cache and capture process in the existing task state or handoff. Coordinate with that owner before using a shared resource. Never stop another session's processes, reset its simulator or mutate its caches. Performance measurements require an appropriately isolated run; label measurements made under concurrent load.
- Reuse verified artifacts and immutable inputs where safe, but never share mutable DerivedData, package checkouts, preferences or test containers. Use separate namespaces for synthetic first-use tests and real-model replays. Do not redownload or repeatedly copy models already available as verified inputs when a safe local reuse mechanism exists.
- Prefer completion events and bounded status waits to repeated polling. While a dependency runs, do useful independent work. Report completed stages, blockers and changes to the expected path instead of narrating unchanged waits. If a stage exceeds its estimate, identify the actual bottleneck before adding retries or more workers.
- Stop completed agents and owned capture/test processes promptly. Release reservations after joined cleanup. Remove or archive only this task's unneeded worktrees after preserving required ignored artifacts; never delete another session's work or valuable backups to save space.

## Verification

The commands below are available checks, not a requirement to run every command for every change. Select them using the verification scope above.

- **IMPORTANT:** For iPad/iPhone changes, first validate the combined build in both simulators and show native screenshots or video to the user for review. Physical iPad/iPhone tests are the final stage after the simulator results work correctly and the user has reviewed them. Do not replace an active device recording to install a test build.
- `bash scripts/dev/check.sh`: portable repository and setup checks.
- `bash scripts/dev/setup.sh`: worktree and prerequisite check. Swift dependencies resolve during the first macOS build; no model downloads occur during setup.
- `bash scripts/dev/macos.sh build`: unsigned macOS build.
- `bash scripts/dev/macos.sh test`: upstream macOS integration suite, with the same known flaky Whisper fixture excluded as upstream CI.
- macOS builds require full Xcode. A successful cloud check is not evidence that the app compiled or that microphone, Accessibility, CoreML, or UI behavior works.
- Keep DerivedData and source package checkouts inside the current worktree. Never share a mutable build directory between concurrent sessions.
- Before interactive permission and audio tests, finish the required builds and local signing, verify the exact bundle and freeze a tested copy in ignored local storage. Do not rebuild, replace or re-sign the running copy during E2E. An ad-hoc signature identifies a particular build and cannot provide stable permission identity across rebuilds; use an existing valid development/distribution signing identity when available. Never weaken a signing requirement or edit/reset the system permission database to bypass a failed grant.
- Capture and save a native screenshot for each distinct changed acceptance state, named with the case and tested revision. Inspect contrast, layout, localization and state. Do not capture routine navigation clicks or repeat identical frames. Fix material issues and repeat only affected states/checks; changed application code requires a newly validated frozen copy before interactive testing resumes.
- During physical mobile runtime tests, also save a native device frame every second using `scripts/dev/capture-mobile-frames.py`. Prefer its continuous USB video mode with an explicitly selected `--stream-device-id` when available. The screenshot CLI fallback may miss seconds under load; record capture errors and missed seconds explicitly and never claim complete one-second coverage when frames are missing. Preserve every frame in ignored test artifacts, index decoded pixel changes, and visually analyze changed frames instead of repeatedly reviewing identical images. Start capture before the tested action and stop it after completion. Simulator UI tests use the helper's `--platform simulator` mode. A background model test whose visible app uses another service composition does not establish live interface responsiveness.
- Run an independent automated code review after integrating feature branches and before publishing a PR. Fix material findings, rerun affected checks, and report the reviewed commit and remaining limitations.

## Changes and upstream

- Keep feature changes small. Put Pichi-specific providers and resources in separate files where practical. Use the existing `TranscriptionProvider` interface.
- Do not rename every upstream type, target, directory, or symbol for branding. Centralize display names and assets; plan a separate bundle identifier, storage namespace, Keychain service, updater feed, and analytics policy before running a branded app.
- Import upstream changes with `bash scripts/dev/prepare-upstream-sync.sh`, resolve conflicts on that branch, verify on macOS, and open a PR to our repository. Never auto-merge upstream updates into `main`.
- `origin` is our repository; `upstream` is FluidVoice and must remain read-only. Published `main` history must not be rebased.
- Upstream community and contribution rules apply when proposing changes to FluidVoice. The user's instructions authorize work on this downstream repository.
- Preserve upstream copyright notices and GPL-3.0. Check model and dataset licenses separately before distribution. The private Fluid Intelligence runtime is not supplied by the public repository.

## Architecture requirements for every agent

**CRITICAL:** Minimal upstream changes mean extending the existing architecture correctly, not adding hardcoded shortcuts. These requirements apply to parent agents, delegated agents, implementation and code review.

- **MUST** inspect the current implementation, upstream contracts and neighboring implementations before choosing an extension point. Reuse the existing `TranscriptionProvider`, meeting backend registry, settings, storage and resource mechanisms when their contracts fit.
- **NEVER** add a model-specific factory, constructor parameter or model switch to a common meeting coordinator, processing pipeline or execution context for each new model. Register providers/backends through the existing extension boundary; common orchestration must consume contracts and capabilities. Model identifiers, artifact validation and engine-specific behavior belong to the registered descriptor or inference adapter.
- Keep model-specific types only where they represent actual inference/runtime differences. Do not rename inherited upstream types merely to make names generic, or create a parallel provider hierarchy that duplicates existing preparation, cancellation, audio routing or residency management.
- Onboarding, settings, files and API entry points must share the existing service operations for model installation, activation and resource cleanup. Common UI must use model metadata/capabilities and generic operation state instead of duplicating a lifecycle for each model.
- **MUST** justify each new abstraction, class, factory or shared integration point with the concrete existing limitation it solves. Prefer the smallest coherent extension over a new framework, speculative plug-in system or repository-wide rewrite. A small diff is insufficient justification for a brittle shortcut.
- Product names, logos, palettes and appearance belong to the versioned portable brand package. Common UI and services must use the shared branding/theme contracts; do not embed Pichi, a bank or the original product name as a new product default in Swift code. Preserve source copyright and genuine third-party model attribution.
- Typography must use the existing shared text roles and portable brand style. Keep heading and body fonts consistent across SwiftUI and AppKit controls, including onboarding. Preserve deliberate monospace and numeric roles; avoid per-screen or per-language font overrides.
- UI work must verify visual quality as well as behavior: consistent spacing, hierarchy, icon size and contrast in light and dark themes. Register genuine provider logos through existing provider metadata and local assets. Use native app screenshots to check the result; synthetic previews alone do not confirm the app's appearance.
- Every supported font design and weight must render the full Russian alphabet, including `Ё` and `ё`, directly. Verify Cyrillic coverage and actual localized layouts when changing fonts or brand packs; do not treat a missing-glyph fallback as font support.
- Interface copy belongs to Apple's String Catalogs and standard localization resources. Adding a language must not require a new language branch in application logic. Never use translated labels for behavior selection, or translate user transcripts, dictionaries, imported brand names, model/API identifiers or other user data.
- Keep imported appearance separate from trusted distribution identity, credential storage, analytics destinations and update/signing policy. A brand import must not change these service/security boundaries or reuse another installation's data.
- Reliability requirements include immutable model/artifact selection per attempt, explicit resource ownership, bounded memory, joined cancellation and restoration on success, failure and cancellation. Do not bypass these rules to make a new provider appear supported.
- **MUST** include architecture in the independent automated code review: check existing extension-point reuse, common-layer model/brand/language hardcoding, duplicated pipelines, mutable selection, cancellation, resource ownership and upstream merge impact. Report concrete design decisions and tests rather than claiming universal architecture without evidence.

## Data and completion

- **NEVER** commit personal dictionaries, private training audio, model weights, credentials, signing identities, or private evaluation datasets. Keep them in ignored local storage or an explicitly authorized artifact store. Only synthetic or approved public fixtures belong in Git.
- Before committing, inspect the diff and tracked paths. Before pushing, verify the working directory and destination repository. Push only the current task branch to `origin`.
- Report the branch, commit, checks actually run, and remaining limitations. Do not claim a cloud environment is ready until it is published and a new cloud task has verified it.

## See also

- [Development setup](docs/development/codex.md)
- [Upstream strategy](docs/development/upstream.md)
- [License](LICENSE)
