# Agent workflow and native acceptance

This guide owns operational details for [AGENTS.md](../../AGENTS.md). Use [Testing](testing.md) for coverage, [development setup](codex.md) for commands and [upstream strategy](upstream.md) for sync operations.

## Work ownership and delegation

Start editing in a task-owned worktree based on current `main`, with a unique `codex/<task>` branch. Prefer app lifecycle tools; the terminal fallback is `bash scripts/dev/new-worktree.sh <task-slug>`. Use the returned absolute directory for every command and edit. Managed worktrees may start detached. In Cloud, create a linked worktree inside the isolated task workspace. `setup.sh --allow-primary` permits prerequisite setup only.

Resume the same owned worktree for the same outcome. Inspect saved and unsaved work before reuse. Before publishing, check staged, unstaged and untracked paths, branch, `origin` and explicit GitHub repository target. Pin input branch/PR SHAs and recheck before publication. Never publish to `upstream`, discard another session's changes or check out a branch owned elsewhere.

Use one implementation owner for tightly coupled changes. Delegate independent work when it improves completion time or quality. Writers own separate worktrees and branches; read-only agents inspect pinned revisions. Provide scope, architecture contracts, starting SHA, acceptance criteria, owned checks and resources. The parent reviews every diff, integrates commits, resolves conflicts and validates the combined candidate. Isolated checks do not establish integrated behavior.

Before expensive jobs, inspect CPU, memory pressure and existing ownership once. Choose concurrency with headroom for user work and reduce it on contention. Isolate DerivedData, mutable source packages, preferences and test containers per worktree. Reuse verified immutable model inputs without repeated downloads or copies. Separate synthetic first-use fixtures/containers from real-model replay.

Physical devices, foreground UI, microphones and audio routing each require one explicit owner. Parallel simulator work requires distinct owned devices and output paths. Age, an idle process or a directory name does not establish ownership. Coordinate ambiguous resources first.

## Bounded implementation and review

Before expensive validation, identify acceptance behavior, changed contracts, selected checks and the slowest dependency. Aim for a small usable increment; say early if compilation dominates. Reassess scope when progress exceeds the estimate instead of quietly adding a regression campaign.

Freeze the candidate before expensive checks. Complete required independent source review and reconcile the currently installed feature revision before starting a signed distribution build, so known review fixes and concurrent feature changes do not cause avoidable Release rebuilds. Build each needed configuration once per relevant source revision; a test build establishes compilation. Release builds are needed for distribution or Release-specific behavior. Repeat only invalidated checks after a fix. First-use tests use isolated containers. Prefer an early end-to-end check when it resolves integration uncertainty, alongside required unit tests.

Obtain independent automated review of the integrated revision before publishing a PR. Include existing extension-point reuse, model/brand/language hardcoding in common layers, duplicated pipelines, immutable selection, cancellation, ownership, privacy boundaries, tests and upstream merge impact. Record the reviewed revision, resolve material findings and rerun affected checks. Static review is separate from runtime acceptance.

## Native acceptance

Use this section for actual UI, permission, audio, device or model acceptance. Also read the affected feature's guide, such as [mobile Release recording](mobile-release-ui-verification.md) or [native HTTP acceptance](native-http-acceptance.md).

1. Establish ownership of device/UI/audio resources. Inspect installed app revision and activity before planning an install. Resolve compatibility before building. Never overwrite a newer feature build with an older baseline or replace an active recording.
2. Complete required builds and signing, verify the exact bundle and freeze a tested copy in ignored storage. Use an existing valid development/distribution identity when available. Ad-hoc identity changes between builds and cannot establish stable permission identity. Never weaken signing, reset/edit the system permission database or change global trust to bypass a failed grant.
3. Keep the frozen running bundle/signature unchanged during acceptance. Record source revision and binary/signature identity. Changed source needs newly validated artifacts before interactive testing resumes.
4. Exercise distinct changed states in the actual app. Save native screenshots named with case and tested revision. Inspect layout, contrast, shared typography, localization and state in relevant light/dark appearances. Font/brand changes include direct Cyrillic glyph coverage and real localized layouts. Offscreen renderings do not establish app appearance or focus.
5. For mobile UI changes, validate the combined app on both iPhone and iPad simulators and show native evidence for user review before physical testing. Simulator capture uses `scripts/dev/capture-mobile-frames.py --platform simulator` with explicitly owned devices.
6. During physical mobile runtime tests, use the capture helper to save a native frame every second from before the action through completion. Prefer continuous USB video with explicit `--stream-device-id`. Preserve every frame in ignored evidence, index decoded pixel changes and inspect changed frames. The CLI screenshot fallback may miss seconds; record errors/gaps and never claim complete coverage when frames are missing.
7. Record the exact observed boundary. Background inference using another service composition does not prove live UI responsiveness. Model replay is not microphone acceptance, an enabled permission row is not capture, and share presentation is not external delivery.

If a harness stalls or permissions fail, make one bounded diagnostic attempt based on evidence. Preserve the working increment and report the exact acceptance gap rather than repeatedly rebuilding or replaying unchanged steps. Follow-up checks need a concrete reason.

## Resource lifecycle and cleanup

Track created/reserved resources with owners and IDs/paths in existing task state or handoff, including delegated work. Release each when no longer needed, before completion.

Stop completed agents and owned build/test/capture/dev processes and their children, join shutdown, then release locks, ports, device/audio leases and reservations. Use supported unload/shutdown for task-owned models or inference servers. Preserve reusable model files. Never unload shared models or interrupt active user work.

Before deleting a simulator, container, temporary directory or worktree, inspect saved/unsaved data and staged, unstaged, untracked and needed ignored files. Preserve requested backups, original recordings, voice profiles, settings, needed evidence and unpublished work outside the target. Independently verify copy completeness and hashes before deleting originals. Git commits do not preserve ignored files or device/container data. Keep recoverable refs or an archive for unpublished commits.

Remove task-owned disposable simulators, containers, dependency checkouts, temporary files, build outputs and reproducible caches when no longer needed. Archive app-managed worktrees through the app. Remove manual worktrees from outside with `git worktree remove`; do not force away changes or delete a branch needed for recovery. Preserve the primary checkout. Never use broad system purges or clean another session's resources.

Verify cleanup by inspecting owned IDs/paths without launching builds, services, models or simulators solely for status. The parent verifies delegated cleanup and stops finished agents. Report released resources, preserved locations and failed cleanup. If anything must remain, record its owner, exact resource and concrete reason.

## Completion evidence

Report branch and revision, actual checks and scope, unresolved gaps, independent review and resource disposition. Prefer a concise PR or existing evidence record over a new report per test run. Claim Cloud readiness only after publication and verification in a fresh cloud task. Dated evidence applies only to the inputs it actually tested.
