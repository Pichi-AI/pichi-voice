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
- Keep native build directories, package checkouts and private test artifacts isolated per worktree. One parent agent owns interactive app and device testing so agents do not compete for the user's UI or microphone.
- Run an independent code review against the integrated commit. Record the reviewed revision, fix material findings and repeat the affected checks before publishing. Stop completed child agents after collecting their results.

## Verification

- `bash scripts/dev/check.sh`: portable repository and setup checks.
- `bash scripts/dev/setup.sh`: worktree and prerequisite check. Swift dependencies resolve during the first macOS build; no model downloads occur during setup.
- `bash scripts/dev/macos.sh build`: unsigned macOS build.
- `bash scripts/dev/macos.sh test`: upstream macOS integration suite, with the same known flaky Whisper fixture excluded as upstream CI.
- macOS builds require full Xcode. A successful cloud check is not evidence that the app compiled or that microphone, Accessibility, CoreML, or UI behavior works.
- Keep DerivedData and source package checkouts inside the current worktree. Never share a mutable build directory between concurrent sessions.
- Before interactive permission and audio tests, finish the required builds and local signing, verify the exact bundle and freeze a tested copy in ignored local storage. Do not rebuild, replace or re-sign the running copy during E2E. An ad-hoc signature identifies a particular build and cannot provide stable permission identity across rebuilds; use an existing valid development/distribution signing identity when available. Never weaken a signing requirement or edit/reset the system permission database to bypass a failed grant.
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
