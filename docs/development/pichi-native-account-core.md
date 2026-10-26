# Shared native account core

N1 implements the optional account boundary for iOS, iPadOS and macOS against contract v1 at `85943ce799bc287097004f72feea7e318d443b97`. The N2/N5 split keeps profile isolation with N2 and durable publication with N5. Neither login nor cloud publication is enabled in the shipped bundle.

## Concrete dependency API

All declarations are in `Sources/Fluid/Account`. `AccountSessionService` is a main-actor `ObservableObject`, composed as `AppServices.accountSession` on both platforms. Its published projections are `state`, `account`, `context`, `generation` and `presentationError`. Stable presentation errors are `AccountError` cases; N3 owns their localized text.

The shared operations are `signIn() async`, `restore() async`, `cancelSignIn() async`, `switchPerson() async`, `selectWorkspace(organizationID:workspaceID:) async throws`, `logout() async`, `shutdown() async`, `authorizedAccess(for:) async throws` and `isCurrent(_:)`. UI never owns refresh tokens. Reauthentication through `signIn` first joins logout of the previous grant. `switchPerson` joins logout, requests explicit authentication and rejects the prior issuer/subject if the provider returns it again. Ordinary logout remains device-specific and does not reset browser cookies.

`AccountContext` is an immutable value with `identity: AccountIdentity`, optional `organizationID` and `workspaceID`, and `generation: UUID`. Identity contains verified `issuer`, `subject` and stable `internalUserID`. A signed-in account can have no selected workspace. The service never silently selects one. Workspace selection validates current server memberships and changes the generation.

N2 installs exactly one composition-owned participant through `installLifecycle(_:)` before restoring or signing in:

```swift
@MainActor protocol AccountSessionLifecycle: AnyObject {
    var isAccountIsolationReady: Bool { get }
    func transition(from: AccountContext?, to: AccountContext?, generation: UUID) async throws
}
```

The participant joins former-profile work, clears private presentation state and selects the next safe profile before returning. A nil destination means guest. It must tolerate repeated guest transitions after partial failures. It must preserve an admitted recording's owner and ongoing capture. N2 can compose N5 delivery cancellation inside this one transition owner after its handoff. No second account manager or token store is needed. Failed cleanup blocks new login until an explicit `logout()` cleanup retry succeeds.

`authorizedAccess(for:)` receives the caller's frozen context and returns `AccountAuthorizedAccess(context:accessToken:)` only while it is current. N5 passes this bearer only to the trusted API and calls `isCurrent` before accepting a response. It must not resolve a global current owner after an await. Refresh is single-flight; membership is revalidated before releasing refreshed access. Account and refresh results do not change a newer generation. Logout and termination cancel and join outstanding operations, including failed-admission rollback. Termination preserves the persisted device grant; explicit logout inhibits restoration durably and clears it, even when device revocation is offline.

## Trust, browser and storage

`BrandDistribution.account` is optional signed configuration with `issuer`, `apiBaseURL`, `clientID`, `apiAudience` and exact `bundleIdentifier`. URLs require HTTPS without credentials, query, fragment or trailing slash. Configuration and registered callback scheme must match the actual installed bundle identifier. Runtime visual packages cannot supply these fields. Production composition additionally requires the N2 participant's isolation readiness. Startup restoration remains an explicit composition operation for N2 to wire after profile isolation is ready.

Callbacks are exact, without a wildcard:

| Target | Redirect URI |
| --- | --- |
| macOS Debug | `ai.pichi.voice.debug:/oauth/callback` |
| macOS Release | `ai.pichi.voice:/oauth/callback` |
| iOS/iPadOS Debug and Release | `ai.pichi.voice.mobile:/oauth/callback` |

A separate signed brand uses its actual bundle identifier in the same `:/oauth/callback` pattern and requires its own enumerated IdP registration. Info.plist schemes use `$(PRODUCT_BUNDLE_IDENTIFIER)`. No shared Keychain group or associated-domain entitlement is added.

`AccountSystemBrowser` uses `ASWebAuthenticationSession`, Authorization Code and PKCE S256 with independently random verifier/state/nonce. Callback scheme, host, path, fragment absence and unique state/code fields are checked. The transport accepts only same-origin discovery endpoints, refuses HTTP redirects, bounds time and response size, and disables cookies, cache and credential storage. RS256 signatures are verified with trusted JWKS using Security, then issuer, subject, audience, expiry, issuance time, optional not-before and ID-token nonce/authorized-party are checked. Other algorithms fail closed. The API receives the access token. The ID token is never an API credential.

`AccountKeychainStore` has an independent bundle/issuer/client/API/audience namespace. One versioned atomic active-device envelope binds the issuer, subject and internal account ID, replacing the access/refresh pair together with readback verification. It has no provider API-key migration, email linking, shared access group or Keychain cloud synchronization. Credentials use WhenUnlockedThisDeviceOnly. A scoped nonsecret logout marker prevents automatic restoration after an unsuccessful deletion. Raw errors, credentials, claims and personal metadata are not logged.

The composition-only `AccountBrowserSessionPolicy` defaults to `sharedDevice`, requesting ephemeral authentication. Trusted personal-device composition can pass `personalDevice` to `AccountSessionService.production(bundle:browserSessionPolicy:)` to permit browser-session reuse. Explicit switching freezes the request to ephemeral mode plus exactly one OIDC `prompt=login` while preserving state/nonce/PKCE/redirect. A same-person return is rejected with `AccountError.previousAccountReturned`; N3 owns its localized copy. Neither policy nor the browser cookie store is controlled by appearance imports. The existing API remains source-compatible through an additive browser adapter overload. Actual federated browser SSO and account choice remain a live-provider gate. See [Apple's session policy](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession/prefersephemeralwebbrowsersession) and [OIDC authentication request parameters](https://openid.net/specs/openid-connect-core-1_0.html#AuthRequest).

No cloud consent, outbox, recording transfer, audio, owner profile or account UI is implemented here.

## Evidence and remaining gates

`bash Tests/run_account_session_tests.sh` compiles the actual production account sources in Swift 6 with MainActor default isolation. The current focused run passed 119 synthetic assertions for PKCE/callback validation, RSA signatures/issuer/audience/nonce/time, inactive configuration, N2 admission, single-flight rotation, workspace generations, late login/refresh after logout, lookup failure after rotation, failed persistence/cleanup, joined failed admission, workspace selection during refresh, ambiguous refresh across restart, discovery endpoint trust, form encoding, browser-policy matrix, explicit switching, shutdown after restore/logout and durable logout markers. Services are injected in memory. No real Keychain item, browser, user account, model, app UI, microphone or recording is accessed. Generated RSA keys are nonpersistent and used only for synthetic token verification.

Both actual native targets compiled and independent security/architecture review found no material findings at `413576584289b6c8cfee77a2904f5a9b81908bf9`. A subsequent narrow review found delayed browser cancellation also needed its captured session-ID fence; final compilation/review is recorded with that corrective commit. Live I1/W1 provider integration and combined N2/N5 acceptance remain separate gates. Native simulator screenshots and physical-device review remain with the UI/integration owners. A source harness pass does not establish those results.

Review follow-up: the initial independent review identified and corrected failed-admission cleanup outside joined work, rotation persistence ordering, profile rollback and failed-logout admission. A second review of `f6b0e48a0a8af5aa82926d61bb0e5d3a639c3d46` found completed-refresh retention across workspace generation changes and ambiguous-refresh restoration after restart. The follow-up clears refresh ownership by operation identity and after a joined workspace transition, inhibits restoration on invalid/ambiguous rotation, and tests both paths. Termination joins both ordinary and restoration refreshes through atomic persistence before changing its generation; a gated restoration/shutdown case verifies the replacement survives. Final review and target builds are bound to the follow-up commit.

The final operation owner stores its ID, kind and task as one immutable value, preventing a completed restore from leaving stale cancellation policy on the next login. Browser policy is immutable per adapter and explicit-identity intent is immutable per attempt. Both native targets built successfully at `c44b9315cf617450413a733f3cf322f3346c8073`; the policy/operation-owner delta requires its own reviewed frozen commit and incremental target builds before publication.

The browser cancellation handler now uses the same captured session-ID guard as its callback, so delayed cancellation cannot cancel a newer authentication attempt. Live browser cancellation behavior is still untested. The final portable run initially hit the existing `test_stalled_inspection_cannot_prevent_term_escalation_and_join` timing assertion under native build load; preserve the failed log and record its isolated/full rerun separately.

## Command cancellation correction after 9fc25a13

An account-UI review found that `switchPerson` and reauthentication could suspend in their initial logout before browser admission was owned. `cancelSignIn` only recognized `signingIn`, and cancelling the caller did not propagate into unstructured admission. The regression against production source `9fc25a13558d4eb241cebdf7ff92d059edb80804` recorded `joined=false`, two browser starts instead of one, and a failed assertion after safely releasing the synthetic logout gate. Its earlier successful target-build evidence remains separate.

A private immutable authentication-command owner now spans preflight logout and admission. It is separate from the inner operation slot because the logout boundary cancels/joins that slot; putting the encompassing command there would create a self-join. Public cancellation/logout/shutdown cancel the concrete command before awaiting cleanup, then join it. Internal preflight uses the same private joined profile/credential cleanup without awaiting its own encompassing command. Cancellation handlers synchronously propagate caller cancellation through the concrete command and admission tasks. A terminal shutdown gate prevents logout completion from reopening admission.

The public Swift signatures, account models, errors, lifecycle participant, callback/trust policy and N2/N5 interfaces are unchanged. `isSignInAvailable` is false while a full command is owned and after shutdown. No UI workaround or new platform manager is required. The actual-source standalone suite now passes 193 synthetic assertions. Added gates suspend logout for both switch and reauthentication, then exercise cancelSignIn, caller cancellation, public logout, shutdown and concurrent cancel/logout; after release they assert no extra authorization/browser, no saved grant/context, guest state and safe replacement admission. Discovery/exchange cancellation is also joined, including late token revocation. Corrective-source target builds require coordinator admission; the prior 9fc25a13 builds are not validation of this changed source.
