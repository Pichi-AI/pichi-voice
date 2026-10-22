# FluidVoice 1.6.12 integration

## Pinned inputs

| Input | Revision |
| --- | --- |
| Downstream baseline | `59e5079066406ff2f2ecdec8c1c2395eaf69e052` |
| Previous upstream baseline | `2ca292d173f0ca6ab11cfb93fb52ace83e82248e`, v1.6.12-beta.1 |
| Published stable release | `8976f3aedc4f8fb3499a9a28c15fa29840f2b5f3`, v1.6.12 |
| Task branch | `codex/upstream-sync-537ab0b976` |

The release was published on October 22, 2026. Both the public release and the fetched tag resolve to the same immutable commit. The stable target includes the previously integrated beta. The existing open-PR and update-branch inventory contained no prepared integration of this SHA. The helper was invoked with the explicit tag `v1.6.12`; unpublished upstream main is not an update target.

The delta contains 12 commits and changes 157 paths. The initial merge reported 39 conflicted paths. Independent agents resolved disjoint source scopes in separate worktrees based on the same downstream SHA. Their resolved files were reviewed and imported into the parent merge. All combined checks belong to the resulting parent candidate, rather than the agents' syntax-only checks.

## Conflict decisions

- Dictionary UI keeps the new manual entry, pronunciation learning, spelling correction and word-test flows while retaining the responsive downstream drawer and shared provider/service operations. User words and custom model names remain data. A pending operation prevents another word test from taking capture ownership.
- Meeting UI keeps inline text editing, batch speaker edits, Markdown export, settings/history access, shortcuts and caption dragging. Existing participant presentation IDs, native member IDs, owner labels and downstream waveform are retained. The existing separate history snapshot is reused rather than adding a duplicate class.
- Meeting domain operations retain attribution provenance and stable correction IDs. Undo restores the complete prior correction state. The upstream destructive speaker inheritance and native-member deletion are not applied to downstream native evidence. The combined pipeline/backend versions are 17/9; older mismatched processing pins remain rejected rather than silently reinterpreted.
- Capture keeps the downstream memory consumer, immutable model/artifact selection, all-system audio contract and joined cleanup. The new comparison probe is admitted only for retained audio with PII redaction off. Its constructor independently rejects private sessions before creating files. Failure and Stop join its cleanup.
- Settings remain in the existing extracted key, model and meeting preference files. Automatically merged duplicate declarations are removed. Existing GigaAM source/default selection and explicit browser-detection preferences are retained.
- Dictation keeps authoritative loaded credentials, the admitted route/target/mode snapshot, connection options and rapid-toggle ownership. The new presentation cache has no authorization role. Standard/cloud idle connection pools retain request ownership and redirect policy; bounded local sessions retain their previous lifetime rules.
- Updater rollback uses the trusted distribution repository and the existing distribution admission gate. Upstream's hardcoded application repository is not an installation destination. Disabled production updates remain disabled, including the newly introduced rollback entry point.
- The clean textual Xcode merge repeated the earlier silent identity problem: duplicate upstream product/bundle/version settings. Each app configuration now has one Pichi identity and version 1.6.12, build 34, above the downstream build 33. Mobile identity/version are unchanged. The portable duplicate-setting check covers this boundary.
- The dictionary ribbon receives colors from the portable theme. Shared native controls retain their separate iOS implementation. Existing typography and genuine model attribution are preserved. New trusted interface copy has English and Russian String Catalog entries; existing entries remain unchanged.
- The ignore file retains downstream development instructions, privacy exclusions and update reports, together with upstream local Claude exclusions. The new recovery-copy standalone probe is explicitly registered without weakening registry coverage checks.

No provider hierarchy, model-specific coordinator factory or parallel audio pipeline is introduced. Upstream notices and licensed source/artifacts are retained. No personal dictionaries, recordings, model weights, credentials or signing identities are part of the committed update.

## Verification

The combined candidate is under validation. Actual results, exact reviewed revisions and remaining gates are recorded here before publication. Syntax checks in individual agent worktrees do not establish a compiled or functioning combined app.

The first portable attempt exposed an unregistered new upstream recovery-copy runner. It remains a failed initial attempt; the runner was added to the existing registry and the affected checks are repeated. Package resolution completed using the pinned lock file and task-owned checkouts.

The installed application, active user capture and physical devices are outside this task's test environment. This update does not install or replace an application and does not automatically merge into main. Microphone, Accessibility, real-model quality, hardware routes, cloud credentials and visual acceptance must be reported separately from automated checks. Previously accepted summary quality limitations remain limitations, not passing evidence.
