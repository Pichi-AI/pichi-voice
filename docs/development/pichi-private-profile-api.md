# Private profile source API for N3, N4 and N5

Status: focused N2 private-profile foundation. N1 remains frozen at `f989116f2028d1bb1d47cac86ff65f6e57a2391a`. This layer supplies local source isolation, guest preservation, joined cleanup and original capture ownership. N5 delivers the queue and shared cloud activation after this foundation; N3 and N4 deliver account/cloud UI. Their implementations are excluded from the focused N2 branch.

N1 remains the only account/token manager. N2 supplies one `PrivateProfileService: AccountSessionLifecycle` participant. N5 registers its joined delivery cleanup inside that participant and owns its own consent/outbox/status operations. It must not install a second account lifecycle or create another profile registry.

## Immutable local sources

`Sources/Fluid/Account/PrivateProfileStorage.swift` defines `PrivateProfileSnapshot` with `id`, `context: AccountContext?`, `generation`, `rootDirectory`, `legacyRootDirectory`, `isReadable` and `isGuest`. Account paths use a bounded SHA-256 key over trusted distribution namespace plus N1's verified issuer, subject, internal user ID and optional organization/workspace. No email/display-name linking or raw identifier paths exist.

`PrivateProfileStorage.current` returns a value snapshot. `isReadable(snapshot)` validates the exact selected local generation and visibility; `acceptsNewWork` is a separate operation-admission gate. A concealed/closing profile must not start new publication. Snapshot paths and account identifiers are private local metadata, never transport fields or logs. Only N2 composition selects or conceals a scope.

Guest roots remain at their legacy paths. Account-private defaults use an explicit persistent domain with no guest fallback, through `PrivateProfileDefaults.shared` or `PrivateProfileDefaults.bound(to: snapshot) -> UserDefaults`. Legacy provider credentials/dictionaries are not copied into a login. The explicit device allowlist is in `PrivateProfileDefaults.sharedDeviceKeys`.

### Shared device guest meeting history

The October 28 meeting policy explicitly shares device-owned guest recordings across accounts. `PrivateProfileMeetingStore` presents guest meetings together with the current account's meetings. Other accounts and workspaces remain excluded. Guest files stay in the original root, retain guest ownership, and gain no account publication consent. Reading legacy ownerless guest data from an account adds guest provenance only to the returned value; an ordinary later edit persists the guest marker in the original guest file.

The existing UUID interface gives a current-profile directory precedence over a colliding guest UUID, including corrupt or foreign-owned current directories. Catalogs deduplicate by that same rule. Mutations reject mismatched owners and use the selected source's original root. Expected-owner deletion remains atomic and recognizes legacy ownerless guest records only for canonical guest ownership.

Guest encryption remains enabled on disk when captured that way. The shared facade loads only an existing guest recording key, never creates or replaces one, and revalidates the active reader generation. Decrypted guest recordings can appear in the shared local history; protected account recordings keep their existing display/export restrictions. An unavailable guest key cannot hide healthy plaintext guest or account records, and direct encrypted reads still fail closed.

Automatic retention uses `loadHistoryForMaintenance`, which excludes shared guest meetings while an account is selected. Automatic recovery also stays current-profile-only. Account preferences, provider credentials, dictionaries and voice profiles remain private; they are not inherited with shared meeting visibility.

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

N2 composition alone calls `configure(isBusy:prepare:activate:conceal:)` and installs the service through N1's `installLifecycle`. The concrete source hooks must be installed before isolation readiness is true. `conceal` cancels and joins private readers, settings work, background transfers and Local API requests even when an admitted recorder must continue. The quiescent `prepare` hook additionally retires capture-sensitive sources. An earlier marker or cleanup failure cannot skip the remaining joins or publish another readable profile.

Per-window readers and N5's delivery owner conform to:

```swift
@MainActor protocol PrivateProfileTransitionParticipant: AnyObject {
    func prepareForPrivateProfileTransition() async throws
}
```

Register through `PrivateProfileService.shared.register(_:)`. Registration is weak; the composition/view retains its participant. Cleanup closes admission, cancels and joins owned work, and clears private projections before source replacement. N5's participant pauses and joins transfers but preserves the original owner's durable queue.

N2 owns common app/window composition. Use `sourceRevision` for rebuilding private source-bound views after successful source replacement. `projectionRevision` also advances on concealment and must not key the whole app root during an admitted capture. Concealment hides private pixels, focus and accessibility while preserving the controller needed to stop/finalize the old recording. N3 owns mobile late copy/export/PDF result fences; N4 owns desktop view-local payload/projection fences. They must not install parallel root composition or profile managers. Account/workspace switching is blocked during capture/finalization and admitted output persistence. Logout clears N1 credentials offline while the local capture retains its original writer; another person cannot enter before required local cleanup completes. Token expiry alone never switches local profile or stops recording.

## Dictation and direct capture output

`PrivateDictationCaptureOutput` freezes the original history admission and recording-time history/audio preferences. A concealed capture saves its raw local result through that same admission. Empty ASR remains empty; successful approved WAV persistence can create an audio-only recoverable entry. No transcript text is fabricated. Failed WAV or history persistence retains the original payload and Stop owner for an explicit retry. `finish() async -> Bool` returns false until that ownership can be released safely.

`PrivateDirectDictationCapture` supplies the same admission and joined Stop ownership to existing command, rewrite, training and fallback controls. A visible consumer acknowledges its result synchronously; otherwise concealment preserves the result under the original owner. Recreated windows forward Stop to the retained exact capture ID. A queued old view cannot type, copy or reopen private output in another generation.

The common ASR service pins the existing provider and immutable model/options under its admitted dictation, file or Local API lease. Provider cleanup joins admitted recognition workers before releasing their options. This contract extends the existing provider boundary; common orchestration does not add a model-specific factory or switch.

## Process ownership boundary

Terminal commands run in an explicitly owned process group with bounded pipes, cancellation and timeout. Cleanup may signal that group only while its original leader remains reserved. A command that successfully starts an intentionally redirected background job transfers that job to the user; later profile cleanup does not kill it or claim it was joined. No broad process-name cleanup or process registry changes that boundary.

## Evidence and delivery boundaries

The focused foundation extends the reviewed `65b5eaa8` source with the corrected capture feedback, menu discovery, paste verification and approved shared audio-export cancellation. Menu discovery uses the existing private operation owner only until its immutable configuration is ready. Profile cleanup cancels and joins that phase; the existing coordinator independently owns capture admission afterward, so busy logout cannot cancel an admitted recorder.

Synthetic verification covers 1,148 checkpoint assertions, 167 admitted history/audio assertions, 59 callback/discovery assertions in each compiler mode, seven source guards and 14 negative controls. The typing-focus fixture covers 286 checks and rejects a wrong-field forwarding mutation. These results establish their recorded source and fixture scope. Final delivery checks and native build evidence are pinned independently to the delivery revision; portable or synthetic passes do not establish microphone, model inference, native visual quality or physical-device behavior.

The earlier `d5febd94` unsigned iOS simulator SDK compile is historical evidence for that revision only. Exact delivery compilation, signing, interactive screenshots, audio routing and physical-device acceptance remain separate gates. Production sign-in or cloud publication is not enabled by this foundation.

The mobile manifest explicitly registers the N1 account and N2 shared sources. Common cloud activation and N3/N4 account/cloud constructors are delivered in later layers. Project generation has one owner at a time.
