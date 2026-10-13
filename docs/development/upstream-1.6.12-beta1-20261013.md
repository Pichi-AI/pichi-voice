# FluidVoice 1.6.12 beta 1 integration

## Pinned ancestry

The upstream target is `2ca292d173f0ca6ab11cfb93fb52ace83e82248e`, fetched `upstream/main` on October 13, 2026. It contains four commits after the prior release baseline `9bf99b4f51839c6927022ed76630533b0329fa32`:

- `20ae1948`: startup window handling, meeting provider selection and Fluid Server.
- `5ffc4beb`: end-of-meeting prompts and browser meeting detection.
- `283a5064`: version `1.6.12-beta.1`.
- `2ca292d1`: release highlights after each app update.

The required command was `bash scripts/dev/prepare-upstream-sync.sh 2ca292d173f0ca6ab11cfb93fb52ace83e82248e`. It recorded `origin/main` as `0295cd829f0389f928567d52eb36b21cb32469a9` and created an isolated worktree with a pending merge. The untouched merge in that new worktree was aborted, its branch advanced with `--ff-only` to the parent's reviewed `3c03f63ca4807b57ae285f3f6d84365579292360`, and the identical pinned upstream merge restarted. The resulting merge keeps both parent ancestries; main and other worktrees were not changed.

The effective common ancestor is `9bf99b4f51839c6927022ed76630533b0329fa32`. The task branch is `codex/upstream-1-6-12-beta-integration-20261013`. Parallel diagnostic and startup credential changes are integrated by the parent after this branch.

## Conflict decisions

| Path | Preserved behavior |
| --- | --- |
| `AppDelegate.swift` | Upstream startup/restorability handling plus downstream brand and resource behavior. Stable main-window identity works with localized page titles. |
| `SettingsStore.swift` | Existing credential, dictionary and settings contracts. New sharing stays off; absent browser detection stays off, while explicit values survive. Temperature lookup receives the resolved endpoint. |
| `LLMClient.swift` | Existing ephemeral local transport, cloud authorization and redirect policy plus completion metadata and endpoint-specific temperature learning. Each rejected local attempt joins its owned session before retrying. |
| `MeetingSessionCoordinator.swift` | Immutable selected model/artifact and existing capture lease, with the new live-speech observation reset. |
| `MeetingSummaryController.swift` | Existing optional processing drain and exclusive summary ownership. Upstream provider support remains available, while Pichi UI generation keeps the grounded pipeline. |
| `MenuBarManager.swift` | Existing key/minimize policy with stable main-window identity. |
| `ModelRepository.swift` | Existing injected transport and connection options, with upstream model capability metadata. |
| `MeetingRecordingSettingsSheet.swift` | Shared typography, localized rail and existing settings operations, with the new integration controls. |
| `MeetingSessionCanvases.swift` | Existing document presentation and ASR ownership are passed to the summary wrapper. |
| `MeetingSummaryView.swift` | Pichi's grounded summary view remains the UI. Upstream's own-window dictation target marker is retained. |
| `ReleaseHighlightsContent.swift` | Beta changes are described accurately through catalog keys; downstream does not display the upstream site's distribution notice. |
| `ReleaseHighlightsView.swift` | Shared fonts and AppBrand formatting; per-build upstream presentation policy remains. |
| `ReleaseHighlightsPolicyTests.swift` | Catalog coverage plus upstream version/build ledger behavior. |

## Semantic boundaries

The provider resolver freezes the existing verified provider/model, reasoning and connection options into `PichiMeetingSummaryConfiguration`. The structured schema, literal source citations, chronological ledger, cache version 19, redirect rejection, joined cancellation, local model snapshots and ASR residency remain in the existing pipeline. S1 still has no meeting-summary capability. Compatible-provider incomplete responses are rejected before grounded parsing.

`fv-serve` derives its meeting storage and preference domain from its real enclosing bundle's distribution identifier. It has no legacy FluidVoice fallback or caller-controlled defaults override. Skill ownership uses a namespace-specific marker; original generic FluidVoice markers and other installations are foreign and must not be replaced or removed. Display names remain data; the genuine `fv-serve` and `fluidmeet` identifiers are retained.

The helper reads the actual `pichi-meeting-summary.json` artifact through the same document, evidence validation, transcript fingerprint and Markdown export code as the application. It validates artifact version, source currentness and literal citations. It does not perform live model discovery or credential checks; the UI retains its additional current configuration/model identity checks. The helper also retains upstream's manual-summary reader for existing saved upstream artifacts.

To compile the existing document codec into the helper without audio services, pure document/export types were moved mechanically into `PichiMeetingSummaryDocument.swift`. Five existing persisted metadata codecs moved from capture/postprocessing/sidecar service files into `MeetingPersistedMetadata.swift`. Application-only validation methods moved to `MeetingPersistenceValidation.swift`. Type names, serialized fields and validation behavior are unchanged. The helper links CoreAudio only for the existing persisted `AudioObjectID` type and performs no capture or hardware queries.

Capability keys preserve model ID, URL path and query case; only URL scheme/host and trailing path slashes normalize. Unsafe older case-folded records are not migrated. A temperature retry changes only its frozen temperature and stops after a second rejection.

The embedded helper is required by the signed build contract. Synthetic signed-build fixtures now include it and separately verify rejection when it is missing. GNU-compatible private `mktemp` behavior, trusted product/bundle settings and duplicate Xcode setting checks remain.

New owned interface copy is in English/Russian String Catalog units. Runtime agent-state labels localize before rendering; agent names, browser names, paths, imported brand names, transcripts and prompts remain data. The narrow native ended-meeting prompt still needs a Russian layout check in the frozen application.

## Verification and remaining work

The standalone helper runner compiles the actual production codecs and command. Its 33 checks cover a real copied helper under a unique synthetic bundle/preference namespace, off/on consent, argument bypass rejection, trusted skill ownership, actual grounded artifact discovery, stale source/version/citation rejection, exact canonical Markdown, unchanged source files, and case-sensitive model/endpoint capabilities. It is registered in the existing standalone entrypoint; after parallel diagnostic integration the parent adjusts the combined registry count.

Three local retry/cancellation regressions ran with the full production LLM client and adapter in an isolated executable. Their transport intercepts every request; no inference server, credentials or models were used. Logging persistence is disabled in test support, and existing residency policy is extracted unchanged. Removing only the temperature-400 invalidation join from an ignored copy fails the regression. The XCTest form also compiled against Xcode's XCTest overlay.

Portable repository checks, the meaningful existing grounded evidence runner and Swift syntax parsing are run on this branch. Full native app builds, the combined XCTest host, independent review of the final merged revision and frozen native E2E are owned by the parent. Source-only checks do not establish native startup, permissions, capture, provider execution or visual quality. The separate Keychain startup stall is not attributed to the window identity fix.

## Containment and malformed-source follow-up

Review of `1856c8849afd4f32d9c790e1884e5d39b7c043f0` found that directory/file symlinks could redirect the read-only helper to another namespace, and unbounded/nonregular inputs could hang or exhaust it. A synthetic replay of that exact revision served a foreign fixture through a session-directory symlink. No real application data was used in the reproduction.

The feature-scoped `FluidServeFileBoundary` now owns no-follow descriptors for each root ancestor, session directory and regular single-link file. It verifies opened file identity, size and stable metadata, reads at most 4 MiB per manifest or 2 MiB per summary, and accounts for at most 64 MiB per library operation. Enumeration stops after 1024 inspected names before allocating a larger names array; at most 256 session directories are inspected. Commands return a clear failure on unsafe files or exceeded limits. Root and directory identity are retained across summary reads, and the source session is frozen per command. Metadata-provided audio paths are never opened by the helper.

A pure transcript structural validator was extracted from persistence admission and shared by the grounded artifact boundary. It rejects unsupported schemas, duplicate speaker/segment/track IDs, invalid source references, reversed/invalid/unrepresentable timestamps and invalid session date ranges before any unique-key dictionary or timestamp rendering. Application language/model admission remains in the existing application validation method.

The same directory descriptors protect the installed skill. Symlinked ancestor folders, broken or existing leaf symlinks, FIFOs, directories, hardlinks, oversized and unreadable/non-UTF-8 foreign entries remain untouched. New publication uses an exclusive atomic rename; updates atomically swap only a previously owned file and verify its exact identity/content before discarding the old inode. A raced foreign entry is restored or retained, never deleted. Removal similarly verifies a parked owned file before deletion.

The registered `fluid_serve` runner retains all 33 grounded-helper checks and adds 57 skill ownership checks plus 37 process-isolated containment cases with 280 checks. The corpus covers valid Pichi artifacts, foreign directory/file/root/ancestor symlinks, dense and sparse oversized files, FIFO/nonregular inputs, hardlinks, malformed structural IDs/references/times and exact/over-limit directory/session/read budgets. Each command child has a three-second deadline with joined termination escalation. Test appearance storage uses the existing standalone support; no installed appearance, real preferences, private meetings or inference service is accessed. Full native host execution remains with the parent.

## Recovery ownership correction

Review of `8e056753f5a95a75dfd7158365690313d12a9472` identified a remaining validation-to-unlink gap: checking an inode/content does not make a later deletion by name conditional on that inode. Permanent cleanup is now deferred entirely. Update/removal/failed publication entries remain under unique hidden recovery names; the active `SKILL.md` is still added, updated atomically or removed from agent discovery. No automatic file or empty-directory deletion is attempted. Owner-managed recovery cleanup is explicit and recoveries have no claimed automatic lifetime.

Each created instruction document remains limited to 64 KiB, and installation reserves an entry within a 128-entry folder budget. Directory locking serializes ordinary skill operations during count/publication; removal remains available at the budget and only renames its entry. A full recovery folder produces localized guidance to review and clean up saved entries. Normal synthetic tests verify retained bytes, active status, idempotent removal and budget behavior; source assertions prevent reintroducing permanent cleanup calls. No syscall-interception experiment is used.

## Registered-provider temperature recovery

Registered cloud providers now classify a complete, bounded wire error before producing the existing safe outward error. Classification remains private to the LLM transport; a typed rejection reaches the existing single retry and endpoint/model capability cache without exposing the response body. An explicit unsupported temperature parameter can be learned, while value/range errors and rejection of another parameter cannot. A second rejection returns the ordinary safe HTTP error. The classifier does not select providers or change a request's model, endpoint, credentials or operation ownership.

Thirty fully intercepted production-client scenarios cover registered cloud combinations, generic endpoints and local retry/cancellation. Synthetic credential and response sentinels must remain absent from outward errors and DEBUG logs. These fixtures use no actual network service or account; real cloud execution still requires native E2E evidence. The parent integrates this change together with the independently reviewed credential-startup and hotkey corrections before running the full native host.

## Reintegration of reviewed stable main

After PR 12 was merged separately, the parent reintegrated `origin/main` at `3dbde076b6d523ae699b2dcbabc8f4d24a95a01d` by an ordinary merge into the task branch starting at `3d45efea4eef4759e9e4d64542d5a8906ad7a1b0`. The fetched main tree matches the reviewed stable update head `58988c642ffeef9566332dba8ae9c4eb57b2906f`. No shared main, installed application, permission or other session worktree was changed by this reintegration.

Six textual conflicts were resolved by their contracts. The ignore file retains both the portable regression entrypoints and the stable update report. The portable check keeps every downstream gate. All 2737 main catalog keys already exist among the task's 2842 keys; four equivalent Russian mute strings retain the task's tested wording. The mute indicator retains the dark theme surface, width fallback and shared caption role used for narrow overlays. The backup test combines main's two meeting-preference preservation assertions with the existing legacy-field absence assertion. The upstream guide retains the protected-folder advice, identity validation and recorded app-local scheduling context.

The clean textual Xcode merge silently introduced a second `MARKETING_VERSION` in each application configuration. The stale `1.6.11` duplicates were removed, preserving exactly one `1.6.12-beta.1` value and the existing Debug/Release product, module and bundle identities. The duplicate-setting validator passed all 12 configuration blocks. ASR/summary service handoff, bounded mute timeline, resource ownership, backup service operations and recovery code remain the task's existing implementations.

Four inherited before/after mute images contain only synthetic fixture speech and standard labels. They were inspected before this merge and remain evidence of the stable rehearsal, not screenshots of the new task revision. Interactive installed UI and microphone use remain reserved for the concurrent dictation test on frozen `d346e915`.

## Native credential scheduling regression

The actual Xcode host exposed a test barrier that blocked MainActor before an async credential action could enter its owned worker. Moving the Task alone was insufficient because the native service retains its configured actor. The test now waits for its semaphore on a background queue and uses XCTest's expectation wait on main. Read-start, cached-state, rejected stale admission, MainActor cleanup, acknowledged intent and restart assertions remain intact. Three affected native cases passed on `7bf9f71a`, including TERM-resistant reader shutdown.

The registered credential runner executes the same 26 injected-backend cases under ordinary Swift defaults and under `-default-isolation MainActor` when the compiler exposes that option. On the tested Xcode 27 compiler, both modes execute: 52 pass, zero failures or skips. A source-only negative with the previous barrier reproduces six failed assertions in the same two cases under MainActor defaults. Older compilers explicitly report the unavailable second mode as skipped. The real Keychain singleton is guarded out of these fixtures. This scheduling coverage does not grant credentials or establish native permission behavior.
