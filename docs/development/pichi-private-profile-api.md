# Private profile source API for N3, N4 and N5

Status: early source handoff, not native/runtime acceptance. Baseline API is parent revision `911b0677`, containing the N1 source boundary, now corrected to `f989116f2028d1bb1d47cac86ff65f6e57a2391a`. N2 profile composition and admitted dictation-write corrections remain in progress. Do not enable production sign-in based on this source handoff.

N1 remains the only account/token manager. N2 supplies one `PrivateProfileService: AccountSessionLifecycle` participant. N5 registers its joined delivery cleanup inside that participant and owns its own consent/outbox/status operations. It must not install a second account lifecycle or create another profile registry.

## Immutable local sources

`Sources/Fluid/Account/PrivateProfileStorage.swift` defines `PrivateProfileSnapshot` with `id`, `context: AccountContext?`, `generation`, `rootDirectory`, `legacyRootDirectory`, `isReadable` and `isGuest`. Account paths use a bounded SHA-256 key over trusted distribution namespace plus N1's verified issuer, subject, internal user ID and optional organization/workspace. No email/display-name linking or raw identifier paths exist.

`PrivateProfileStorage.current` returns a value snapshot. `isReadable(snapshot)` validates the exact selected local generation and visibility; `acceptsNewWork` is a separate operation-admission gate. A concealed/closing profile must not start new publication. Snapshot paths and account identifiers are private local metadata, never transport fields or logs. Only N2 composition selects or conceals a scope.

Guest roots remain at their legacy paths. Account-private defaults use an explicit persistent domain with no guest fallback, through `PrivateProfileDefaults.shared` or `PrivateProfileDefaults.bound(to: snapshot) -> UserDefaults`. Legacy provider credentials/dictionaries are not copied into a login. The explicit device allowlist is in `PrivateProfileDefaults.sharedDeviceKeys`.

## Recording admission and persisted meeting source

`Sources/Fluid/Account/PrivateProfileMeetingStore.swift` defines:

```swift
nonisolated struct MeetingPrivateProfileAdmission: Sendable {
    let profile: PrivateProfileSnapshot
    var ownership: MeetingProfileOwnership { get }
}

nonisolated protocol PrivateProfileRecordingObserver: Sendable {
    func captureAdmitted(id: MeetingSessionID, admission: MeetingPrivateProfileAdmission) async
    func sourceDidPersist(id: MeetingSessionID, admission: MeetingPrivateProfileAdmission) async
    func captureAdmissionCancelled(id: MeetingSessionID, admission: MeetingPrivateProfileAdmission) async
}
```

The cancellation callback has a default no-op. `PrivateProfileMeetingStore.shared.installRecordingObserver(_:)` installs one N5 observer. Callbacks must perform bounded local work only. They cannot throw, start network/model work, stop recording or turn a publication failure into a local save failure.

The existing `MeetingSessionStoring` contract adds `captureOwnership(for:)` and `cancelCaptureAdmission(for:)`, with compatibility defaults for injected stores. The common coordinator calls capture ownership under its existing capture admission, before the first manifest and before audio capture starts. N5 uses `captureAdmitted` to freeze its separate recording-time consent/policy for that exact session ID and immutable owner. Changing consent or selected workspace later must not alter it.

`MeetingSession.profileOwnership` is durable local metadata: profile ID, issuer, subject, internal user ID and optional organization/workspace. Nil ownership belongs only to legacy guest history. The scoped store stamps/validates ownership and retains the admitted writer's original root if logout conceals it. Reads, playback/export directories and history use the selected visible profile. A stale or missing account owner cannot overwrite a different profile's same-UUID record.

After a completed source is saved, `sourceDidPersist` fires with its original admission. It is a persistence notification, not upload eligibility or analysis completeness. N5 must reload with:

```swift
try await PrivateProfileMeetingStore.shared.persistedSource(id: id, admission: admission)
```

That method requires the exact readable current generation and matching saved ownership; it never returns a coordinator's in-memory copy. N5 then applies its own consent/completeness/redaction/size eligibility through the existing protected exporter. Repeated completion notifications, post-publication edits and user corrections must not enqueue a second immutable import.

For a later retry/reconciliation after logout, a queue item keeps its frozen owner and bytes. A newly authenticated operation must first match that owner to the new N1 context. `PrivateProfileMeetingStore.shared.admission()` can supply a fresh current local snapshot for a local reload only after that match; it is not permission to retarget an old record or claim guest history. Delivery itself uses N1's frozen authorized operation.

## Joined transitions and UI projection lifetime

`PrivateProfileService.shared` is observable with `sourceRevision`, `projectionRevision`, `isTransitioning`, `isPrivateDataVisible` and `isAccountIsolationReady`. `requireTransitionAdmission()` allows N3/N4 to refuse an explicit account/workspace switch before invoking N1. N1's lifecycle remains the final isolation boundary.

N2 composition alone calls `configure(isBusy:prepare:activate:)` and installs the service through N1's `installLifecycle`. The concrete source hooks must be complete before isolation readiness is true. This source handoff does not assert that those production hooks are installed or verified.

Per-window readers and N5's delivery owner conform to:

```swift
@MainActor protocol PrivateProfileTransitionParticipant: AnyObject {
    func prepareForPrivateProfileTransition() async throws
}
```

Register through `PrivateProfileService.shared.register(_:)`. Registration is weak; the composition/view retains its participant. Cleanup closes admission, cancels and joins owned work, and clears private projections before source replacement. N5's participant pauses and joins transfers but preserves the original owner's durable queue.

N2 owns common app/window composition. Use `sourceRevision` for rebuilding private source-bound views after successful source replacement. `projectionRevision` also advances on concealment and must not key the whole app root during an admitted capture. Concealment hides private pixels, focus and accessibility while preserving the controller needed to stop/finalize the old recording. N3 owns mobile late copy/export/PDF result fences; N4 owns desktop view-local payload/projection fences. They must not install parallel root composition or profile managers. Account/workspace switching is blocked during capture/finalization and admitted output persistence. Logout clears N1 credentials offline while the local capture retains its original writer; another person cannot enter before required local cleanup completes. Token expiry alone never switches local profile or stops recording.

## Evidence and pending gates

The actual scoped meeting store, persisted codecs and exporter passed 960 synthetic assertions in the existing checkpoint runner, including 19 meeting-profile cases and 10 injected lifecycle cases. The new recording observer is source-only at this handoff; recording-observer cases and production composition are still being completed. Agent store/settings/auxiliary suites provide additional isolated evidence, not combined native acceptance.

Pending: admitted dictation/audio completion after immediate conceal, queued guest migration across conceal, full source/observer transition tests, combined independent review, actual sequential iOS/macOS builds under N2's admitted heavy slot. Cloud readiness remains separately owned by N5.

The mobile source manifest now explicitly registers N1 account files and the published N2 profile sources, so project regeneration preserves them. `update-mobile-project.py` already includes every top-level `Sources/Mobile/*.swift`; N3's `MobileAccount.swift` will therefore be included when its source branch is integrated and the common composition owner regenerates once. No concurrent project regeneration is authorized.
