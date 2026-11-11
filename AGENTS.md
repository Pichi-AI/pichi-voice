# Pichi Voice development principles

Pichi Voice is a downstream of [FluidVoice](https://github.com/altic-dev/FluidVoice). Work belongs in [Pichi-AI/pichi-voice](https://github.com/Pichi-AI/pichi-voice); `upstream` is read-only. Preserve upstream history, copyright and GPL-3.0, and check runtime, model and dataset licenses before distribution.

## How to use this guidance

This file defines shared principles and non-negotiable boundaries for contributors and delegated agents. Choose implementation methods within those boundaries. Read the relevant canonical guide when its topic applies:

| Topic | Owning guide |
| --- | --- |
| Test requirements, locations and verification scope | [Testing](docs/development/testing.md) |
| Recording continuity, fault isolation and recovery | [Recording reliability](docs/development/recording-reliability.md) |
| Worktrees, delegation, native acceptance and cleanup | [Agent workflow](docs/development/agent-workflow.md) |
| Setup, environments and commands | [Development setup](docs/development/codex.md) |
| Extension contracts and upstream integration | [Upstream strategy](docs/development/upstream.md) |
| Appearance and interface language | [Branding](docs/development/branding.md), [localization](docs/development/localization.md) |
| Contribution and review | [Contributing](CONTRIBUTING.md) |

These guides elaborate this policy rather than create competing copies. Dated reports describe evidence at their recorded revisions; they do not establish current behavior or override this guidance. Keep global personal preferences outside the repository. Update the owning guide when a convention changes.

## Testable behavior is part of the implementation

**MUST:** Every new or changed executable behavior ships with unit tests in the same change. This includes application code, providers, native adapters and development tooling. Extend existing tests when they already own the contract. For a refactor, preserve and adapt tests for the affected behavior.

**MUST:** Code affecting interface interaction also ships with integration tests for the affected UI-to-service flow, alongside unit tests for state, validation and actions. Native UI automation and visual evidence complement these tests. Screenshots, compilation and source-text checks alone do not establish behavioral coverage.

Design boundaries so logic can be tested without real accounts, microphones, network services or model weights. Exercise production implementations through existing test targets and deterministic substitutes at external boundaries. Cover meaningful outcomes, failure and cancellation where relevant; avoid tests that merely repeat the implementation. Documentation-only changes need consistency and link checks, not artificial unit tests. Generated output is verified through its generator and consuming contract.

Test sources and approved fixtures belong in the versioned locations in [Testing](docs/development/testing.md#test-ownership-and-storage). Private data and generated results stay outside Git. Required tests are part of completion; unavailable execution is an explicit validation gap, never a pass or a reason to omit test code.

## Architecture requirements for every agent

**MUST:** Inspect current implementation, neighboring implementations and upstream contracts before choosing an extension point. Extend existing provider and meeting backend registries, settings, storage and resource services. Common orchestration consumes contracts and capabilities; model identity, artifact validation and inference construction belong to the registered descriptor or adapter. Do not add a model-specific switch, factory or constructor parameter to the common pipeline for each provider.

Prefer the smallest coherent change that preserves upstream integration. Justify a new abstraction with a concrete limitation. Avoid duplicated pipelines, parallel provider hierarchies, broad renaming and speculative frameworks. Onboarding, settings, files and API entry points share service operations for preparation, activation, cancellation and cleanup.

**MUST:** Captured audio is authoritative. In file-backed recording, failures or delays in transcription, metadata, indexing, echo analysis or optional publication must never automatically stop the microphone or discard already captured PCM. Bound memory, preserve exact measured time and explicit gaps, keep files recoverable independently of their index, and join optional workers without coupling their success to capture lifetime. A transient buffer overflow must allow later audio to continue. Respect mute/privacy admission and strict no-file policies; never label lost input as complete. See [Recording reliability](docs/development/recording-reliability.md).

Treat each attempt as an immutable selection of model, artifact and configuration. Resource ownership must be explicit, memory bounded, cancellation joined and restoration complete on success, failure and cancellation. Privacy decisions belong at the real admission, persistence and publication boundaries, with tests of those boundaries.

Product appearance belongs to the portable brand package and shared theme/text roles. Keep SwiftUI and AppKit typography consistent, including deliberate numeric and monospace roles. Supported fonts must directly cover the full Russian alphabet, including `Ё` and `ё`, across supported designs and weights. Interface copy belongs to String Catalogs and standard localization resources; behavior must not depend on translated labels or language-specific branches. User transcripts, dictionaries, imported brand names and model/API identifiers remain user data. Preserve genuine provider attribution and use provider metadata/assets for logos.

Imported appearance must never change signed identity, credential/storage namespaces, telemetry destinations or updater trust. Keep app distribution identity separate from third-party model-source trust. Do not reuse another installation's data or mass-rename upstream symbols for branding.

## Session isolation

**MUST:** Each editing session and each delegated implementation owner uses a separate Git worktree and unique `codex/<task>` branch. The primary checkout is for fetching and integrating reviewed work. Use the returned worktree path explicitly for commands and edits. Cloud tasks also use a linked worktree inside their isolated workspace. Resume owned work for the same outcome.

Preserve other sessions' changes and resource ownership. Never edit `main` directly, share mutable build/package directories, force-push published branches or rewrite published `main`. Confirm checkout and destination before publishing only the task branch to `origin`. Import upstream changes through the existing sync helper and a reviewed PR.

Delegate independent work when it shortens delivery. Give agents bounded scope, pinned inputs, relevant contracts, owned resources and completion criteria. The parent reviews and integrates their changes, validates the combined result and verifies cleanup. Read-only reviewers can inspect a pinned revision without another worktree; concurrent writers cannot share one.

## Verification

Deliver a small, usable and verified increment. State acceptance behavior, affected contracts and bounded checks before expensive work. Required unit and integration tests are the baseline; add broader checks for concrete risks or named consumers. Stop when acceptance and selected checks pass with no material finding. Reuse unchanged evidence with its actual revision and scope, and repeat only checks invalidated by a change.

Native acceptance uses the actual combined app and exact frozen signed build. Verify changed states, relevant light/dark appearances, localization and accessibility. For mobile UI changes, validate both iPhone and iPad simulators and show native evidence for user review before physical testing. Protect active recordings and existing installations. Follow the [native acceptance procedure](docs/development/agent-workflow.md#native-acceptance) for signing, permissions, captures and ownership.

Distinguish portable checks, unit tests, integration tests, native UI evidence, real inference and physical acceptance. None silently substitutes for another. Review the integrated revision independently before publication, including architecture, behavioral tests, privacy boundaries and upstream impact. Fix material findings and repeat affected checks.

## Data, resources and completion

**NEVER:** Commit private recordings, dictionaries, voice profiles, credentials, signing material, model weights or private evaluation datasets. Use synthetic or approved public fixtures with appropriate licenses. Ignoring data does not remove it from existing Git history.

Own the lifetime of everything started or reserved: agents, processes, models, ports, simulators, containers, caches and worktrees. Release task-owned resources when no longer needed, join child cleanup and preserve needed evidence and user data in independently verified copies before deleting originals. Do not stop or delete another session's resources, shared models or the user's active work. Use supported shutdown and worktree lifecycle operations; see [cleanup](docs/development/agent-workflow.md#resource-lifecycle-and-cleanup).

Completion reports identify the branch, revision, actual checks, remaining gaps and resource disposition. A cloud setup is ready only after publication and verification in a fresh cloud task. Evidence and unresolved limitations must remain recoverable after disposable resources are removed.
