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
