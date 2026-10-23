# Shared native cloud publication API

Status: early working source API for N3/N4 and the N2 composition owner. It is not a
production readiness declaration. The source probes use actual N1/N2/store/exporter code
with synthetic in-memory authentication and HTTP fixtures, not a live W2 service.

Source inputs: N1 `f989116f2028d1bb1d47cac86ff65f6e57a2391a`, integrated N2
`d5febd9421918c192063b61e53d3f208f80d2fb7`, W2 runtime source
`ac2b6c352de1c74080c44e0fe206f039b84726eb` and original wire fixtures
`128e1dc17b51f0f0877e00eafb1f73c13cadddf5` and additive provisional compatibility fixture
`c76d7dde2c7bc3c2f374238b8e780fab9d5a145f`. Focused PR publication remains gated on
N2 publishing the integrated correction to its named dependency branch. Source availability
does not establish combined native/runtime acceptance.

## One facade for both platforms

`Sources/Fluid/Services/CloudPublication/PichiCloudPublicationService.swift` defines the
main-actor `ObservableObject`. Its constructor is:

```swift
init(account: AccountSessionService,
     meetings: PrivateProfileMeetingStore = .shared,
     profiles: PrivateProfileService? = nil,
     http: (any PichiPublicationHTTPPerforming)? = nil)
```

The default profile participant is N2's existing service. A missing HTTP executor starts no
network. Production composition can create `PichiPublicationHTTPClient(configuration:)`
only from `account.configuration`. It owns an ephemeral session, refuses redirects and
cookies/cache/credential storage, limits response bodies and joins its requests on shutdown.
No view owns tokens, an HTTP executor, a queue or a separate profile/account manager.

| Operation | Concrete semantics |
| --- | --- |
| `install() async throws` | Once, before N1 restoration/login. Installs the one recording observer and registers the retained N2 transition participant. Does not configure readiness, restore or sign in. |
| `activateCurrentProfile() async throws` | After N1 publishes its verified current context and N2 has selected readable sources. Loads only known local queue records. Resumes eligible owner-bound work when scoped sync is on and not manually paused. |
| `refresh() async throws` | Refresh sanitized current-profile settings/pending projection without changing consent or scanning history. |
| `setCloudSyncEnabled(_ enabled: Bool) async throws` | The only UI Cloud sync toggle. OFF closes network admission immediately, cancels and joins owned POST/GET/PATCH, atomically disables future-capture consent and persists pause, then retains paused immutable work. ON opts in future captures and may resume only previously admitted work for the same verified owner. |
| `status(for id: MeetingSessionID) async throws -> PichiCloudPublicationStatus` | Load one known current-profile ID. Missing/guest/non-admitted records are local-only; never use this operation to discover uploads in history. |
| `send(_ id: MeetingSessionID) async throws` | Send only an existing eligible recording-time admission. Does not grant historical consent or resume unrelated user-paused work. Cloud sync must be on. |
| `retry(_ id: MeetingSessionID) async throws` | Explicit same-key, same-byte retry, preserving Retry-After. An accepted item reconciles instead of reimporting. Does not resume unrelated work. |
| `pause() async` | Join delivery and persist this account/workspace's pause. Future-capture policy stays unchanged. Write failure remains visible and current delivery stays closed. |
| `resume() async throws` | Explicitly clear the current owner's manual pause when Cloud sync is on. Review/billing/permission/validation pauses and Retry-After deadlines are preserved. |
| `reconcile(_ id: MeetingSessionID) async throws` | Owner-authorized GET of the existing import ID; update analysis without changing source identity. Blocked while Cloud sync is off. |
| `assessmentOptions(for id: MeetingSessionID, cursor: String? = nil, limit: Int = 50) async throws -> PichiPublicationAssessmentOptions` | One authorized criteria page and represented source participants for a known accepted meeting. Shares the receipt request lease, consent/grant/profile fences, cancellation joins and durable review handling. No automatic pagination or PATCH. |
| `resolveAssessment(_ id: MeetingSessionID, participantID: UUID, criteriaIDs: [String]) async throws` | Explicit represented source participant plus nonempty authorized criteria selection. PATCH never changes original POST fingerprint. No employee guess or implicit reanalysis. Blocked while sync is off. |
| `shutdown() async` | Join commands, callbacks and delivery, pause durable work, then shut down the owned HTTP executor. Does not stop local recording or delete cloud history. |

Do not bind a UI toggle to the low-level `PichiPublicationConsentStore` methods. They are
implementation operations and cannot by themselves join an active network request. Disable
repeat toggle commands while the coherent setter is pending. Its busy/cancellation errors
must not be converted into an optimistic successful UI state.

## Sanitized presentation

`@Published private(set) var snapshot: PichiCloudPublicationSnapshot` contains:

- `availability: PichiCloudPublicationAvailability`
- `cloudSyncEnabled: Bool`
- `items: [MeetingSessionID: PichiCloudPublicationStatus]`, bounded to 128 current-profile
  projections. Call `status(for:)` for visible known history rows outside this cache.

Availability codes are `unconfigured`, `signedOut`, `profileUnavailable`, `ready`, `pausing`,
`paused`, `transportUnavailable` and `storageUnavailable`. During OFF, `pausing` means a
concrete request or durable write is still joining. The published toggle value retains its
last verified value until the operation finishes. Never show "disabled" solely because the
user clicked OFF. A failed write leaves transport closed and a visible error; it does not
claim that a new setting was durably saved.

Delivery status is typed separately from analysis:

```swift
enum PichiCloudPublicationStatus {
    case localOnly, waitingForSource, queued, sending
    case withheld(PichiPublicationWithholdingReason)
    case retryScheduled(Date)
    case paused(PichiPublicationPauseReason)
    case accepted(PichiPublicationReceipt)
    case acceptedNeedsReview(PichiPublicationReceipt, PichiPublicationPauseReason)
    case conflict
}
```

`PichiPublicationReceipt` has schema version 1, opaque `importID`/`recordingID`, upload state
`accepted` and analysis state `queued`, `running`, `succeeded`, `failed`, `needsParticipant`
or `needsCriteria`. An upload can stay accepted when analysis fails or needs explicit input.
Initial POST assessment is always explicit null participant/empty criteria. A represented
participant is selected by the user later; `isLocalUser` and provisional display flags confer
no employee or account authority. W2 still owns authorized criteria discovery/detail routing.

`acceptedNeedsReview` retains the accepted receipt while showing a safe GET/PATCH failure.
A purge GET404 requires receipt review; replay POST409 retains the original conflict. Neither
can create a replacement operation or charge. Successful explicit reconciliation clears the
review overlay. Server Retry-After survives review, logout and restart, even after automatic
POST retries exhaust. Unrepresentable deadlines remain paused for review.

Receipt GET/PATCH requests share one per-record lease and reload durable deadlines after
acquisition. A concurrent request returns `AccountError.busy` before HTTP.

The active worker polls only observed queued/running receipts, at most 12 times per
observation, at least 10 seconds apart after the initial check, and at most four per worker
pass. It never scans settled history. Terminal/action/review states stop polling. After the
budget ends, explicit reconciliation remains available. OFF and transitions cancel and join
this same worker. Both platform views should use this owner instead of adding polling loops.

Source withholding codes are `notCompleted`, `redactionNotEnabled`, `originalTextRetained`,
`completenessUnknown`, `incompleteTranscript`, `emptyTranscript`, `excludedIntervals`,
`invalidTranscript` and `exportLimitExceeded`. A measured-complete empty source is not
called incomplete. All withheld sources remain local.

Pause codes are `userRequested`, `profileTransition`, `uncertainDelivery`,
`authenticationRequired`, `accountReview`, `permissionReview`, `receiptReview`,
`validationRejected`, `sourceConflict`, `retryBudgetExhausted`, `retryAfterBeyondBudget`,
`transportUnavailable` and `storageUnavailable`. A profile transition cannot turn 402,
permission/validation review or retry exhaustion into automatic delivery.

N3 owns shared String Catalog entries. Suggested exact English catalog keys are below;
they are presentation mappings, not behavior selectors or a second status contract.

| Code | Suggested String Catalog key |
| --- | --- |
| `localOnly` | `Saved on this device` |
| `waitingForSource` | `Waiting for protected transcript` |
| `queued` | `Queued for cloud upload` |
| `sending` | `Uploading protected transcript` |
| `retryScheduled` | `Retry at %@` |
| `accepted` | `Cloud upload accepted` |
| `acceptedNeedsReview(receipt, reason)` | Show retained upload acceptance and the matching `paused` reason below |
| `pausing` | `Stopping cloud sync` |
| `paused.userRequested` | `Cloud uploads paused` |
| `paused.authenticationRequired` | `Sign in again to resume cloud uploads` |
| `paused.accountReview` | `Review account balance` |
| `paused.permissionReview` | `Review workspace access` |
| `paused.receiptReview` | `Review cloud upload status` |
| `paused.validationRejected` | `Cloud upload needs validation review` |
| `paused.sourceConflict` / `conflict` | `Cloud source conflict` |
| `paused.retryBudgetExhausted` | `Automatic retries paused` |
| `paused.retryAfterBeyondBudget` | `Server requested a longer retry delay` |
| `withheld.emptyTranscript` | `No transcript text to upload` |
| `withheld.incompleteTranscript` | `Recognition is incomplete. Kept on this device.` |
| `withheld.completenessUnknown` | `Recognition completeness is unknown` |
| `withheld.redactionNotEnabled` | `This recording was captured without text redaction` |
| `withheld.originalTextRetained` | `Original text is still stored` |
| `withheld.excludedIntervals` | `Some audio intervals have no transcript` |
| `withheld.invalidTranscript` | `This protected source needs review` |
| `withheld.exportLimitExceeded` | `This source exceeds cloud upload limits` |
| `analysis.queued` / `analysis.running` | `Analysis queued` / `Analysis running` |
| `analysis.succeeded` | `Analysis completed` |
| `analysis.failed` | `Analysis failed. Upload retained.` |
| `analysis.needsParticipant` | `Choose the represented participant` |
| `analysis.needsCriteria` | `Choose assessment criteria` |
| `availability.storageUnavailable` | `Cloud storage unavailable. Transfers are paused.` |

Complete missing availability/pause labels in the same catalog. Format retry dates with the
existing localized date roles. User transcripts, participant names, criteria IDs and imported
brand names are never translated. Metadata may contain personal data; do not promise full
anonymization. Do not render arbitrary server error messages/details or credentials.

## Composition and remaining gates

N2 owns a small common composition hook: retain this facade, create the executor from N1's
trusted configuration, await `install()` before account restore/sign-in, and expose the same
instance to N3/N4. Invoke `activateCurrentProfile()` after the actual current account/profile
state is published. Do not invoke it inside an unfinished N1/N2 transition. Register the new
CloudPublication sources in the mobile manifest/Xcode project under N2's coordinated lease;
N5 does not regenerate or edit common composition, project IDs or readiness flags.

Earlier source evidence at `d42ceb25`: 73 durable-store checks and 37 facade checks passed in the actual
N1/N2 observer/store probe. They cover scoped policy, same-owner/new-generation recovery,
response loss, original-byte replay, A/B and guest isolation, coherent OFF join, OFF captures,
blocked GET/PATCH, explicit pending resolution and storage failure without recording failure.
The current correction adds individual cancellation, active GET/PATCH OFF joining, persistent
receipt review and bounded analysis polling. Fresh combined evidence is recorded with the
final frozen source revision; the earlier counts are not a fresh test of these changes.
The probe uses Swift 5 mode because the existing unrelated `ExportedTranscript: Encodable`
conformance warns under that mode; strict Swift 6 consent/wire checks are separate. These
results do not establish a native target build, UI quality, full N2 private-source inventory,
physical-device behavior, real token/browser behavior or live W2 persistence/billing/dispatch.

## Historical stable base verification

Code candidate `8f3055b2e49bd6a8a95c7150109b41a59fa2f66d` passed 81 durable-store and
61 facade checks in 40.119 seconds. Independent automated architecture/security review found
no unresolved material issue after the final corrections. The facade checks include actual
permission failures, recovery after repair, cancellation joins, concurrent receipt exclusion,
and local capture/save completing while an unrelated uncooperative upload remains held.

The strict Swift 6 consent/wire probe passed 62 and 151 checks at `60068f39`. The production
store/exporter/checkpoint/source probe passed 1,065 checks at that revision in 38.361 seconds.
Those inputs were unchanged within the historical `9dc4b6d5` base. They do not validate
the later assessment-options wire/HTTP changes; fresh additive results are recorded below. N1 core remains exact
to `f989116f`; N2 composition, project and mobile-manifest ownership remains unchanged.

No native target build, simulator/device UI, model/inference, actual recording, real account
credentials or live HTTPS endpoint was used. The existing Swift 5 exporter isolation warning
remains. N2 must publish the approved dependency base before the focused stacked draft PR.

## Authorized assessment options

The additive `assessmentOptions(for:cursor:limit:)` operation uses frozen W2 `ac2b6c35`:
`GET /api/v1/recordings/imports/{importID}/assessment-options` with the frozen current
organization/workspace, an explicit limit of 1 through 100 and an optional opaque cursor.
The default limit is 50. It requires the known meeting's retained accepted receipt and exact
frozen protected source. It cannot discover or claim history.

The concrete `PichiPublicationAssessmentOptions` value contains:

| Field | Swift type / meaning |
| --- | --- |
| `schemaVersion` | `Int`, verified as 1 |
| `context` | `Context(accountID: String, organizationID: String, workspaceID: String)` |
| `receipt` | `PichiPublicationReceipt`, retaining both known receipt IDs |
| `participants` | `[Participant]`, each with `id: UUID` and `displayName: String`; exactly the frozen source's represented UUIDs |
| `criteria` | `Criteria(data: [Criterion], pagination: Pagination)`; each criterion has opaque `id: String` and display `name: String` |
| `criteria.pagination` | `limit: Int`, `cursor: String?`, `nextCursor: String?`, `hasMore: Bool` |
| `currentAssessment` | `PichiPublicationAssessment`, separate from the immutable original POST binding |
| `canResolvePending` | `Bool`; only a pending receipt may report true, and the server remains authoritative |

Use `nextCursor` unchanged for a user-requested next page. Do not decode cursor internals,
aggregate every page automatically or retain unbounded pages in a sheet. Current assessment
criteria may belong to another page or may no longer be offered; preserve their IDs without
treating them as authorization to select new criteria. Display names remain user/server data,
never employee identities, defaults or localized selection keys.

The response is limited to 65,536 bytes, at most 100 participants and at most the requested
number of criteria. Context, receipt identity, exact object keys, typed scalar values, source
participant membership and echoed page metadata are checked before returning a value. W2
does not specify a separate criterion-name length cap; the whole-response byte limit bounds
these strings. GET200 is the only successful options status. Safe 400/409 errors retain
validation/conflict review; 401/403/404 and retry errors use the existing accepted-review path.

N3/N4 clear loaded options, cursors and selection drafts when account/workspace/profile
projection changes or a sheet closes. The facade owns no cross-profile options cache.
Only an explicit current user choice invokes `resolveAssessment`; loading options never
sets a participant, changes the original operation or sends PATCH. Both platforms use this
shared operation and do not add employee-directory requests or separate request loops.

N3 owns additional suggested catalog keys: `Loading assessment options`, `Load more criteria`,
`No represented participants`, `No assessment criteria available` and `Assessment options unavailable`.
Existing receipt review and participant/criteria selection keys remain applicable. N2 retains
the same eight CloudPublication sources; this addition creates no production source file or
second composition path. The previously published `9dc4b6d5` remains an immutable stable base handoff. The additive
options candidate and its fresh evidence are pinned separately below.

## Verified additive options candidate

Independent automated architecture/security review found no material issue at
`e14d749dbb55d6258074885e4c6ea4278d473c72`. Production options code is identical to
reviewed `b0176c90`; the final documentation correction changes no production source.

| Check | Tested revision | Result |
| --- | --- | --- |
| Strict Swift 6 consent/wire plus invalid-only HTTP preflight | `e14d749d` | 62 consent + 276 wire checks, 5.109 seconds; includes 125 new options checks |
| Actual N1/N2/store/facade with synthetic HTTP | `e4e29f5b` | 81 store + 73 facade checks, 42.603 seconds |
| Portable repository checks | `e14d749d` | Passed, 20.220 seconds |

The facade inputs are identical between `e4e29f5b` and `e14d749d`; the latter adds only
strict wire tests and their runner call. The historical 1,065 source/checkpoint result remains
reusable only for its unchanged source/exporter/payload inputs. It does not validate the
changed options wire/facade. The fresh cases cover exact W2-derived fixture provenance,
paging, context/receipt/participant checks, strict nested decoding, safe errors, narrow query
preflight, owner isolation, request exclusion, held OFF/logout joins and no automatic PATCH.

No valid HTTP request, native target build, simulator/device UI, live identity grant or
production readiness was exercised. N2 still owns the final coalesced composition/provider
configuration and source registration; N3/N4 consume this shared method and typed page.
