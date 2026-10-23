# Shared native account core

N1 implements the optional account boundary for iOS, iPadOS and macOS against contract v1 at `85943ce799bc287097004f72feea7e318d443b97`. The N2/N5 split keeps profile isolation with N2 and durable publication with N5. Neither login nor cloud publication is enabled in the shipped bundle.

## Concrete dependency API

All declarations are in `Sources/Fluid/Account`. `AccountSessionService` is a main-actor `ObservableObject`, composed as `AppServices.accountSession` on both platforms. Its published projections are `state`, `account`, `context`, `generation` and `presentationError`. Stable presentation errors are `AccountError` cases; N3 owns their localized text.

The shared operations are `signIn() async`, `restore() async`, `cancelSignIn() async`, `selectWorkspace(organizationID:workspaceID:) async throws`, `logout() async`, `shutdown() async`, `authorizedAccess(for:) async throws` and `isCurrent(_:)`. UI never owns refresh tokens. Reauthentication through `signIn` first joins logout of the previous grant. Account switching uses logout followed by sign-in.

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

`AccountSystemBrowser` uses ephemeral `ASWebAuthenticationSession`, Authorization Code and PKCE S256 with independently random verifier/state/nonce. Callback scheme, host, path, fragment absence and unique state/code fields are checked. The transport accepts only same-origin discovery endpoints, refuses HTTP redirects, bounds time and response size, and disables cookies, cache and credential storage. RS256 signatures are verified with trusted JWKS using Security, then issuer, subject, audience, expiry, issuance time, optional not-before and ID-token nonce/authorized-party are checked. Other algorithms fail closed. The API receives the access token. The ID token is never an API credential.

`AccountKeychainStore` has an independent bundle/issuer/client/API/audience namespace. One versioned atomic active-device envelope binds the issuer, subject and internal account ID, replacing the access/refresh pair together with readback verification. It has no provider API-key migration, email linking, shared access group or Keychain cloud synchronization. Credentials use WhenUnlockedThisDeviceOnly. A scoped nonsecret logout marker prevents automatic restoration after an unsuccessful deletion. Raw errors, credentials, claims and personal metadata are not logged.

No cloud consent, outbox, recording transfer, audio, owner profile or account UI is implemented here.

## Evidence and remaining gates

`bash Tests/run_account_session_tests.sh` compiles the actual production account sources in Swift 6 with MainActor default isolation. The initial frozen-source run passed 57 synthetic assertions for PKCE/callback validation, RSA signatures/issuer/audience/nonce/time, inactive configuration, N2 admission, single-flight rotation, workspace generations, late login/refresh after logout, lookup failure after rotation, failed persistence/cleanup, joined failed admission and durable logout markers. Services are injected in memory. No real Keychain item, browser, user account, model, app UI, microphone or recording is accessed. Generated RSA keys are nonpersistent and used only for synthetic token verification.

Actual macOS and iOS target compilation, final independent security/architecture review, live I1/W1 provider integration and combined N2/N5 acceptance remain separate gates. Native simulator screenshots and physical-device review remain with the UI/integration owners. A source harness pass does not establish those results.
