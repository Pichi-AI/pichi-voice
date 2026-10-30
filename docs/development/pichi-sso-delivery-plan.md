# Pichi account, enterprise SSO and cloud publication delivery

Status: coordinated implementation, contract version 1. Initial baselines were verified on 2026-10-22.

## Product decisions

- Community Keycloak is the identity platform. Preserve Apache-2.0 notices; no paid identity-platform dependency is required.
- Sign-in is optional on iOS, iPadOS and macOS. Guest recording and manual export/import remain usable.
- Cloud publication is a separate opt-in. The initial payload is the existing protected transcript and metadata, without audio, original text, embeddings, identity evidence or file paths.
- First opt-in affects new eligible recordings only. Existing guest history is never silently assigned or uploaded.
- Corporate IdPs connect through OIDC or SAML. Native clients use Authorization Code with PKCE S256 through the system authentication browser.
- White-label appearance is separate from trusted issuer/API/client configuration, signing, Keychain and local storage namespaces.
- Ordinary B2B customers may share a realm with Organizations. Full white label may use a dedicated realm and verified domain; infrastructure isolation requires a dedicated deployment.
- Existing Neiroplan/Casdoor installations are outside this delivery. Do not migrate their production accounts or configuration.
- Pichi Voice retains GPL-3.0. This plan does not authorize a closed-source OEM licence or remove notices.

## Baselines and existing dependency

| Repository | Starting revision | Destination |
| --- | --- | --- |
| Pichi-AI/pichi-voice | `59e5079066406ff2f2ecdec8c1c2395eaf69e052` | Task branches to this repository only |
| Pichi-AI/web | `e6ebf04a3ca76730cccc1644ab0537002c39d9ca` | Task branches to this repository only |
| Pichi-AI/infra | `a262421bbbb294554e91776a35fee57ad663c927` | Task branches to this repository only |

[Web PR 1614](https://github.com/Pichi-AI/web/pull/1614) is OPEN and unmerged, at `10b3c1efc2530fcf699bda9974b63ddb6bcab52d`. It supplies structured protected import and assessment. Reuse its implementation after review; do not implement a competing importer. Its schema/migrations and latest changes must be reconciled with the web identity work before integration.

The existing local `pichi` checkout has unrelated changes and an `origin` pointing to Aspirity/AICallStudio. Web workers must use a fresh isolated clone whose `origin` is Pichi-AI/web. Do not change shared remotes or touch that checkout's changes.

## Eight delivery sessions and one planning PR

| ID | Session / PR | Repository | Owned implementation | Integration prerequisites |
| --- | --- | --- | --- | --- |
| P0 | Contracts and orchestration | pichi-voice | This plan and the versioned cross-repository contract | None |
| I1 | Keycloak foundation | infra | Reproducible dev/test deployment, pinned image, realms/clients, synthetic partner theme, secret references and runbook | P0 |
| W1 | Web identity bridge | web | OIDC web flow, verified native bearer principal, external identity links, account/capability endpoint, tenant membership checks | P0; live check with I1 |
| W2 | Protected cloud ingestion | web | PR 1614 integration, own-upload/assessment authorization, pending assessment resolution, durable dispatch, persistent deduplication, receipts/status | P0, W1, reviewed PR 1614 |
| N1 | Shared native account core | pichi-voice | Browser login, Keychain, refresh/logout, generation cancellation, trusted config and both composition roots | P0; live check with I1/W1 |
| N2 | Native profile isolation | pichi-voice | Account/guest storage boundaries, every private-data read path, owner profiles, dictionaries/credentials and safe migration | P0, N1 |
| N5 | Native durable outbox | pichi-voice | Immutable protected snapshots, consent, durable queue, transport/status, shared activation wiring, delivery recovery and pending assessment | P0, N1, N2; server integration with W2 |
| N3 | iPhone/iPad account UX | pichi-voice | Skippable onboarding migration, settings/account/workspace screens, consent and per-record statuses | N1/N2 for account UI; N5 for cloud UI |
| N4 | macOS account UX | pichi-voice | Desktop onboarding/settings/history presentation using the same services | N1/N2 for account UI; N5 for cloud UI |

Each session produces one focused draft PR. P0 is a documentation PR. The first planned delivery therefore has nine new PRs plus the existing import dependency. Native profile isolation and cloud delivery are separate reviewable changes because the inventory found private history, dictionaries, credentials, backups and cached projections beyond the outbox itself.

Independent implementation can proceed against [contract v1](pichi-account-sync-contract-v1.md). A dependent session may inspect sources, design UI and prepare its verification cases before prerequisites arrive. It must not duplicate another owner's runtime models, invent production stubs or mark dependency-bound behaviour as tested. Missing prerequisites are reported to the coordinator with the exact required interface.

```mermaid
flowchart TD
    P0[Contracts v1] --> I1[Keycloak foundation]
    P0 --> W1[Web identity]
    P0 --> N1[Native account core]
    W1 --> W2[Protected ingestion]
    E[Existing PR 1614] --> W2
    N1 --> N2[Native profile isolation]
    N2 --> N5[Native durable outbox]
    W2 --> N5
    N1 --> N3[iPhone and iPad UX]
    N1 --> N4[macOS UX]
    N2 --> N3
    N2 --> N4
    N5 --> N3
    N5 --> N4
    I1 --> V[Combined acceptance]
    W1 --> V
    W2 --> V
    N3 --> V
    N4 --> V
    V --> R[Independent review and controlled rollout]
```

## Shared-file ownership

- N1 owns both composition roots (`Sources/Mobile/MobileApp.swift` and `Sources/Fluid/Services/AppServices.swift`), account settings, trusted distribution auth configuration, callback declarations and initial Xcode target membership.
- N2 owns account isolation in `MeetingSessionStore`, meeting ownership metadata, owner voice/profile access, and every user-data read path including history, playback, summaries and Local API. A tagged outbox alone is insufficient.
- N5 owns cloud consent/outbox/status and the use of immutable publication sources admitted through N2. It does not implement another profile store or account manager.
- N2 may modify composition wiring after N1 publishes its stable commit; N5 follows N2's explicit handoff. N3/N4 request lifecycle hooks rather than adding independent account managers.
- N3 owns new shared account/sync String Catalog entries for both platforms. N4 sends its key delta through the coordinator. Avoid wholesale catalog reformatting.
- Xcode project, shared settings and entitlements changes are sequenced by the coordinator. Independent UI source files can proceed concurrently.
- W1 owns authentication middleware/principal and identity schema migrations. W2 consumes that boundary and owns recording/job schema migrations. Coordinate migration filenames and reconcile PR 1614 before assigning a new number.
- I1 owns identity deployment artifacts; W1 owns application environment consumption. Do not copy secrets or server configuration into the native brand package.

## Native delivery branches

The native delivery order is N1, N2, N5, then N3 and N4. This clarifies packaging; contract v1 at `f3ea4b15160b92c095d9d83036e6a66e3be81c34` and the eight implementation PRs remain unchanged.

**MUST:** Keep a combined test snapshot separate from each PR's delivery branch. A local snapshot containing profiles, outbox and UI is useful integration evidence, but publishing it as the N2 base would absorb the other features and create circular dependencies. Preserve combined snapshots under recoverable refs and retain their required ignored evidence before preparing delivery worktrees.

- N2 delivers profile contracts, private stores/readers, capture ownership, migration and joined cleanup. It excludes the cloud queue and account/cloud UI. The reviewed shared audio-export cancellation helper may be included as N4's privacy contribution, keeping the same implementation upstream of both UI changes.
- N5 consumes the focused N2 delivery and adds the queue, transport, facade and shared activation owner. N2 contributes reviewed common service wiring to this PR. Installation precedes account restoration; activation follows a committed verified context. Its mobile source list includes the cloud service files without referring to N3's UI types.
- N3 contributes the frozen shared account/cloud String Catalog as a resource dependency in N5. N3 remains its sole semantic editor. N5 consumes that exact additive resource without importing mobile UI, so N3 and N4 can both depend on N5 independently.
- N3 delivers mobile UI and the actual `MobileOnboarding` and `MobileMeetingRoot` account/cloud argument injections. N4 delivers desktop UI. Neither UI PR changes the shared service ownership or introduces another queue.

Delivery branches must descend from their existing published PR heads. Use separate owned worktrees, recheck remote heads and push without force. Project only the owner's changes and explicitly approved shared contributions; do not merge an entire combined snapshot back into a focused branch. Preserve the complete regression registry union at each boundary, deriving runner counts from the files actually present.

Before releasing a delivery dependency, check its allowed paths, source memberships and catalog references, then run its focused checks and affected native builds. Assemble the frozen deliveries in the coordinator's integration worktree and compare production source blobs with the reviewed owner snapshots. Record any deliberate composition, catalog, manifest or registry differences and repeat affected checks. A successful combined build does not establish that an individual delivery builds against its declared base.

## Merge and rollout gates

1. Review and publish P0. Freeze its commit and the three input revisions.
2. Run I1, W1 and N1 independently. W2 inventories and reconciles PR 1614; N2 inventories all local profile/read paths; N5 prepares the bounded delivery state machine. N3/N4 prepare platform UX against the agreed domain contract.
3. Integrate W1 before W2, N1 before N2, and N2 before N5 runtime wiring. Enable account UI in N3/N4 only after N1/N2; cloud UI requires N5. Use stacked draft PRs only when their base dependency is explicit.
4. Every PR preserves current behaviour when the trusted account configuration is absent or disabled. Test-only fakes must not activate production cloud paths.
5. Keep upload opt-in separate and off by default. Authentication errors never disable local recording. Account switching must not expose another profile's data.
6. Pin all candidate SHAs and run combined server/native acceptance. Isolated passing checks do not prove the combined flow.
7. Perform independent security and architecture review of the integrated commits, fix material findings and repeat affected checks.
8. Native iPhone/iPad simulator screenshots must be reviewed by the user before the final physical-device stage. Desktop native screenshots follow the same exact-build evidence policy.
9. Publish draft PRs freely within scope. Do not merge to main, deploy production infrastructure, mutate production identity/data, provision paid services or install on a physical device as part of session startup.

Each feature PR is independently reviewable and testable in its declared dependency context. It is not necessarily mergeable before its prerequisites. Do not squash unrelated session scopes into an integration feature PR.

## Existing production accounts

The user also requires a gradual future transition of existing production accounts. Follow the [account migration design](pichi-production-account-migration.md): preserve canonical user IDs, current browser sessions, history and application rights; initially federate existing credentials at normal login; enable verified browser conversion by cohort only after full legacy web parity and revocation checks. Password storage transfer is a separate optional stage with monotonic credential authority and rollback barriers.

W1 and I1 own the future application/provider mechanisms within their focused delivery scopes. This design does not add an implementation PR or authorize production changes. Current OIDC sessions select the restricted own-import surface, so the current callback cannot be used unchanged to migrate existing full web accounts. Native bearer restrictions, optional sign-in, guest isolation and separate cloud consent remain unchanged. Neiroplan/Casdoor and panel-admin migration remain outside this delivery.

## Required verification by owner

| Owner | Required focused checks |
| --- | --- |
| I1 | Fresh realm import, discovery/JWKS, PKCE/redirect validation, synthetic partner isolation, logout and documented key rotation; static Helm/compose validation as applicable |
| W1 | Wrong issuer/audience/signature/expiry, unavailable JWKS, no email-only account linking, cross-organization denial, existing local-session regression, web callback state/nonce |
| W2 | Same request retry, same key/different bytes conflict, scoped receipt access, representative upload and pending-assessment resolution without editor access, transaction/worker restart, no duplicate charge, source text/timing preservation |
| N1 | Callback/state/nonce failure and cancellation, single concurrent refresh, stale completion after logout, device-specific revoke, isolated branded credentials, actual affected macOS/iOS target builds |
| N2 | A/logout/B history/profile/dictionary/credential isolation, joined profile transitions, safe guest migration and backup/restore preservation |
| N5 | Offline restart, accepted-but-response-lost replay, logout during transfer, no retroactive upload, scoped consent, redaction/incomplete/size-limit failures and pending-assessment recovery |
| N3 | iPhone and iPad native simulator smoke, skip/cancel/offline/account switch, RU/EN and light/dark screenshots, onboarding resume migration |
| N4 | macOS build and focused integration checks, native skip/login/logout/relaunch/history smoke, RU/EN and light/dark screenshots |

Do not download speech models or use real recordings for auth/sync tests. Use approved synthetic transcript fixtures. No new generic testing framework is needed.

## Resources and coordination

The coordinator is the current chat `01a16612-f106-7292-9300-8e0e83997b0d`. It owns dependency releases, contract changes, combined review and the delivery register.

- Each coding session uses its own worktree and unique `codex/` branch. Repositories and push URLs are verified before publication.
- Every native worktree has private DerivedData and mutable SourcePackages. No alternates or cache donors may be assumed safe for deletion.
- Initial host preflight found 16 logical CPUs, 128 GiB RAM and low memory pressure. Admit at most two heavy native/container jobs initially, one per owner, and reduce concurrency under contention. Lightweight analysis/tests can run in parallel.
- I1 owns only its explicitly named local containers/loopback ports. W1/W2 own separate local test namespaces and databases.
- N3 may reserve owned iPhone/iPad simulators after dependencies compile. N4 owns its frozen test app. Foreground desktop, microphone, audio routing and physical mobile devices remain coordinator-owned until an explicit handoff.
- A session reports worktree/branch, frozen SHA, PR URL, tests, evidence paths, dependency gaps and cleanup. It stops owned processes and removes disposable outputs.
- Preserve useful evidence and ignored user data outside any worktree being removed, verify copies/hashes, and retain recoverable refs. App-managed worktrees use the app lifecycle tools.
- Keep a worktree only for a concrete active dependency or unfinished verification, recording its owner/path/reason. Never clean unrelated or shared resources.

## Completion definition

The planning task is complete after contracts are published, the eight sessions exist with bounded scopes, and their initial progress/dependency states are checked. Feature delivery remains in progress until all required PRs have passed their declared and combined acceptance gates. No session may describe planning, mocks or an unsigned build as production SSO, cloud sync, or physical-device validation.
