# Pichi account and protected cloud publication contract v1

> Historical design snapshot from PR #48 at `31d7a077a9ebd0855ed900e2cfbcea698e0971ae`, dated 2026-10-22. Session assignments, implementation statuses and source references below describe that snapshot. Current implementation and release acceptance evidence take precedence. Preserving this design does not establish deployed server support or authorize production account migration.

Status: implementation baseline for [the delivery plan](pichi-sso-delivery-plan.md). Changes require coordinator review and a new pinned contract commit.

## 1. Trust and identity

- Backend principal: a verified trusted issuer plus subject, mapped to an existing stable internal Pichi user ID. Email and display name are attributes, never identity keys.
- Preserve existing user IDs/history. Linking an existing local account requires proof of that account or an authorized administrative migration. Matching email alone is insufficient.
- Each issuer/realm is explicitly mapped to allowed Pichi organizations. A client-supplied organization/workspace, role or token claim cannot grant membership by itself.
- API authorization checks current membership and resource ownership, including status/receipt routes. Identity-provider role strings do not automatically grant Pichi admin.
- Native access tokens target the Pichi API resource. ID tokens are not API credentials. Validate signature/algorithm, issuer, audience, expiry and supported clock skew using trusted discovery/JWKS.
- Discovery/issuer/API URLs and client/redirect configuration come from signed distribution configuration or an explicitly trusted deployment registry. Brand imports and recordings cannot set them.
- Standard web sessions may continue using the existing HttpOnly/PASETO boundary after OIDC login. Keep CSRF, state, nonce and existing session compatibility.
- Native public clients use Authorization Code with PKCE S256. No client secret ships in an app.
- Initial synthetic registration names: realm `pichi`, clients `pichi-web`, `pichi-voice-ios`, `pichi-voice-macos`, API resource `pichi-api`. I1/W1 agree exact audience mapping and publish machine-readable local discovery/client configuration before live integration.
- Native callback schemes are derived from the actual signed distribution bundle identity. N1 owns exact registered callback declarations; I1 accepts only the enumerated callbacks. No wildcard redirect URIs.

## 2. Account endpoint

W1 owns `GET /api/v1/account` for verified native user bearer credentials and the existing web session where supported. Version 1 returns:

```json
{
  "schemaVersion": 1,
  "account": {"id": "123", "displayName": "Synthetic Representative", "email": null},
  "identity": {"issuer": "https://identity.example/realms/pichi", "subject": "synthetic-subject"},
  "organizations": [{
    "id": "17",
    "name": "Synthetic Company",
    "workspaces": [{
      "id": "9",
      "name": "Synthetic Team",
      "capabilities": ["recordings:create-own", "recordings:read-own", "recordings:assess-own"]
    }]
  }]
}
```

IDs in this boundary are opaque nonempty strings, even where the legacy database uses integer IDs. Identity issuer/subject must match the authenticated grant. Pagination/limits and unavailable memberships must fail explicitly rather than silently granting a default workspace.

`recordings:create-own` permits a representative to import a recording as themselves without workspace editor access. `recordings:assess-own` permits resolving the represented source participant and choosing only the workspace-authorized assessment criteria for their own import. Assignment to another employee requires an independent authorized capability. W1 supplies these principal/capability operations; W2 enforces them and owns the pending-assessment resolution path.

Authentication failure is 401. Valid identity without current permission is 403. Failure of an identity/database dependency is a bounded service error, not an anonymous fallback.

## 3. Shared native operation contract

N1 publishes the concrete Swift API and a frozen implementation commit before N2/N3/N4/N5 bind production code. Required semantics:

- Observable account states: unconfigured, signed out, signing in, signed in, reauthentication required; sanitized presentation errors are separate from tokens.
- Immutable account identity/context: issuer, subject, internal user ID, organization ID, workspace ID.
- An operation generation changes on logout/account switch. Late callbacks, refresh responses and upload results from an older generation cannot mutate the new account.
- One joined refresh per account at a time. Store rotating credentials atomically through a dedicated account Keychain namespace, separate from inference-provider API keys.
- UI requests sign-in, cancellation, workspace selection and logout through this one service. It never handles raw refresh tokens.
- Account logout clears local credentials/in-memory projections and joins/cancels account-owned work even when offline. Revoke this device's grant where supported. Global corporate logout is a distinct explicit operation.
- A signed-in UI is not enabled in shipped configuration until N2 supplies safe account/guest data isolation.
- Auth/session failures never stop local recording or erase stored meetings.

N2 publishes the concrete private-profile/isolation API and joined transition hooks. N5 consumes that boundary and publishes the shared sync/status API before N3/N4 bind cloud UI. Required delivery semantics: per-account/workspace consent, per-record eligibility/status, manual send/retry, pause/resume, joined logout and immutable owner snapshots. No independent mobile/desktop queue implementations and no second profile manager inside the outbox.

## 4. Local ownership and export

Capture admission fixes owner identity/local profile, organization/workspace and publication consent/policy. A later account switch cannot retarget the record.

- Legacy unowned records remain in the guest profile. Migration must preserve original data until independently verified copies and atomic metadata are safe.
- Isolate every account-owned read/write path, including history, playback, summaries, Local API, owner voice profiles and other private profile data. Inventory dictionaries/PII mappings/settings rather than assuming they are device-wide.
- Public model files may remain shared under existing ownership rules. Do not copy or delete shared models as part of account switching.
- Guest and account histories do not implicitly merge. Later explicit historical upload is a separate user action.
- First automatic publication requires recording-time opt-in and an eligible, persisted completed source. Reload the saved snapshot after terminal persistence.
- Reuse `MeetingTranscriptExporter.protectedTranscriptJSON` and its allowlist. Existing limits (750,000 bytes and 100,000 UTF-16 text units) and redaction policy remain enforced.
- `state == completed` alone does not establish complete coverage. Incomplete transcripts are withheld from automatic analysis with a visible reason until an explicit partial-source contract exists.
- Metadata and manually entered participant names may contain personal data. Do not claim full anonymization.
- Non-eligible, incomplete or oversized records stay local with a visible reason. Never silently drop or send a full internal JSON/audio export instead.

## 5. Protected import transport

W2 owns a native-capable route `POST /api/v1/recordings/imports`, consuming the protected importer service from PR 1614. Preserve manual import through that same service.

The request is multipart/form-data:

| Part/header | Meaning |
| --- | --- |
| `Authorization: Bearer ...` | Verified user grant for the Pichi API |
| `Idempotency-Key` | Stable client operation UUID, scoped server-side to tenant, user and workspace |
| `schemaVersion` | `1` |
| `organizationID`, `workspaceID` | Requested destination, validated against current principal |
| `sourceRevision` | `1`; the initial imported source is immutable |
| `sourceSHA256` | Lowercase SHA-256 of the exact UTF-8 transcript file bytes; server recomputes it |
| `transcript` | One application/json file containing the existing `pichi-voice-transcript` schemaVersion 1 |
| `assessment` | JSON object with `participantID` (source participant UUID or null) and `criteriaIDs` (array, possibly empty); destination employee is derived/authorized server-side |

No audio/file-path/embedding/original-text parts are allowed. Do not log credentials, raw source text or personal metadata.

W2 must publish a synthetic request/receipt fixture and exact validation/error codes before N5 runs live integration. Reusing the existing multipart/import service is preferred over a second parser.

Assessment identity is separate from upload ownership. Names, `isLocalUser` and heuristic diarization do not prove the represented employee. The new route persists an otherwise valid protected source even when participant/criteria binding is unavailable, returning `needsParticipant` or `needsCriteria`. It does not start assessment until the binding is explicit and authorized. This extends the new route only; the existing manual importer keeps its existing validation contract. No silent employee guess is allowed.

## 6. Acceptance, deduplication and status

For a new accepted source, return 202 after committing durable source ownership and recoverable analysis dispatch, using:

```json
{
  "schemaVersion": 1,
  "importID": "opaque-import-id",
  "recordingID": "opaque-recording-id",
  "uploadState": "accepted",
  "analysisState": "queued"
}
```

An identical retry returns 200 and the same receipt. The same scoped operation/source identity with different bytes or assessment binding returns 409. Persistent source uniqueness survives app/server restarts and response-cache expiry. Do not rely solely on the generic 24-hour idempotency cache.

Preserve the PR 1614 workspace/source uniqueness boundary and enforce uploader ownership on duplicate/status lookups. Record any necessary migration before changing that boundary.

`GET /api/v1/recordings/imports/{importID}` returns the authorized receipt/status. Analysis states are `queued`, `running`, `succeeded`, `failed`, `needsParticipant` and `needsCriteria`. Acceptance is not completed analysis.

W2 also owns `PATCH /api/v1/recordings/imports/{importID}/assessment`, taking `participantID` and `criteriaIDs`, and its minimal integration with the existing recording detail UI. Require current `recordings:assess-own`, import ownership, a valid source participant and workspace-authorized criteria. The operation can resolve a pending import without granting workspace editor rights or changing the destination employee/source bytes. Use the existing attempt/concurrency boundary, keep the original import fingerprint for identical delivery retries, and publish the resulting status/receipt. N5/N3/N4 expose the pending action and an authorized path to resolve it; they do not silently select another speaker or criteria policy.

- Use the existing durable job mechanism, such as pg-boss, with transaction/outbox recovery as needed.
- A crash between source persistence, billing and job dispatch must not lose analysis or charge twice.
- 401 pauses for reauthentication; 403 pauses for permission review; 409 requires explicit source-conflict handling; validation/size errors are not retried forever.
- Network failures and appropriate 429/5xx errors use bounded retry/backoff and Retry-After where supplied.
- Receipt reconciliation after a lost response must never reassign owner or create a second history entry.
- Local deletion, cloud deletion and post-publication edits are separate policies. V1 must not silently propagate deletion or overwrite an imported source.

## 7. Privacy, rollout and test gates

Cloud publication defaults off for every new account/workspace, independently of sign-in. Logging out pauses that account's queue; logging in as another person cannot resume it.

All initial infrastructure/accounts/transcripts are synthetic and local/test only. No production identity migration, external partner contact, paid provisioning, shared-device installation or live recording upload is authorized by this contract.

Required combined cases: guest/skip, local-only signed-in mode, account A/B isolation, offline restart, token refresh/revoke, response-lost replay, duplicate/conflicting import, membership revocation, worker restart, an ordinary representative resolving pending assessment without workspace edit privileges, partial source, size/redaction limits and white-label issuer/credential isolation.

Keep absence-of-configuration behaviour unchanged. A feature flag alone does not replace safe storage/auth boundaries. Native screenshots and physical-device gates remain governed by AGENTS.md.
