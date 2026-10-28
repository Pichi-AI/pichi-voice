# Native protected delivery over HTTPS

`MobileProtectedDeliveryHTTPTests` is an opt-in, serial simulator acceptance suite with separate local-stand and direct-QA modes. It uses the production `MeetingSessionCoordinator`, `PrivateProfileMeetingStore`, `LegacyAccountHTTPTransport`, `AccountSessionService` and `PichiCloudPublicationService`. An injected PCM source and recognizer supply invented speech. The local backend uses deterministic analysis for transport testing. A passing run does not establish real ASR, real AI analysis, UI concealment, physical microphone behavior, Keychain security or device Data Protection.

## Runtime gates

1. Integrate the delivery core changes exposing `SettingsStore.meetingEncryptLocalRecordings`, `MeetingSession.isLocalContentConcealed` and the facade's `localEncryptionRequested` closure. Run `scripts/dev/update-mobile-project.py` in the combined worktree so the new test file belongs to the mobile integration target.
2. Wait until the host disk hold is cleared and the isolated Docker stand owner reports readiness. Do not start or modify unrelated containers.
3. Use a newly created task-owned simulator with no real accounts, recordings or model caches. Install the stand's root CA into that simulator's trust store using its explicit simulator ID. The test adds no TLS exception or trust bypass. Never install this CA in the user's normal device or host trust store.
4. Stage a private configuration file where the test host can read it. Its POSIX mode must be `0600`; its path and the relaunch root must resolve without symbolic links. Use the stand owner's synthetic credentials file, never real account credentials.
5. Run these methods serially with test parallelization disabled. The stand has one synthetic personal account; `chargeCount` is its real balance delta since `resetLedger`, so concurrent sources invalidate billing evidence.

The private JSON configuration has this shape. Values shown here are invented placeholders, not usable credentials:

```json
{
  "origin": "https://localhost:18443",
  "email": "native-acceptance@example.invalid",
  "password": "replace-with-stand-synthetic-password",
  "organizationID": "1",
  "workspaceID": "1",
  "controlToken": "replace-with-task-private-control-token"
}
```

## Test-host environment

Inject these variables into the mobile integration test host, not just the parent shell:

| Variable | Value |
| --- | --- |
| `PICHI_NATIVE_HTTP_ACCEPTANCE` | `1` |
| `PICHI_HTTP_FIXTURE_PATH` | Absolute path to the private JSON file |
| `PICHI_TEST_REVISION` | Exact combined candidate commit for surrounding evidence |

For a `test-without-building` run, copy the generated mobile `.xctestrun` beside its original before changing its target environment; `__TESTROOT__` paths remain relative to that directory. The existing `configure_targets` function in `scripts/dev/macos-regression.py` can populate the supported `PICHI_` environment variables in either `.xctestrun` format. Use only the mobile integration target and these specific methods. Do not invoke the macOS build or test wrapper to configure mobile testing.

The four ordinary methods cover:

| Method | Required evidence |
| --- | --- |
| `testEncryptedCaptureRealHTTPSReceiptHistoryAndCurrentDeletePolicy` | Real encrypted capture and History, durable receipt, wrong-owner refusal, busy coordinator refusal, current OFF retaining deferred work, current ON reconciling that receipt while automatic sending is off |
| `testLostCommittedResponseRetainsSourceWithDeletionOnUntilDurableReceipt` | Deletion ON during a committed but lost response retains the encrypted local source; retry persists a matching receipt before source removal, with one server recording/import/charge |
| `testLostCommittedResponseRetriesIdenticalBodyWithoutDuplicateImportOrCharge` | Lost response after upstream commit, no local receipt or deletion before retry, two identical request bodies, one real source/import/recording/charge, edited source retained |
| `testOfflineQueueSurvivesFreshAccountStoreAndForegroundNetworkWake` | Encrypted offline queue, joined service/account shutdown, fresh account transport and store, cached same-owner restore, existing network and foreground wakes reaching a receipt |

Without explicit opt-in the methods skip. With opt-in, malformed or missing configuration, an unavailable stand, an untrusted certificate or invalid ledger evidence fails the run. Skipped tests are not acceptance evidence.

## Separate host relaunch

Run only `testOfflineQueueAcrossTestHostRelaunch` twice, with a separate test-host launch each time. Keep the same simulator, configuration and root. The root's last component must begin `pichi-http-` and it must not exist before the first phase.

| Invocation | Additional environment |
| --- | --- |
| First | `PICHI_HTTP_RELAUNCH_PHASE=queue`, `PICHI_HTTP_RELAUNCH_ROOT=<absolute-owned-path>/pichi-http-relaunch-<unique-id>` |
| Second | `PICHI_HTTP_RELAUNCH_PHASE=resume`, same `PICHI_HTTP_RELAUNCH_ROOT` |

The queue phase stops all fixture services, keeps the stand offline and preserves an ownership marker, synthetic session envelope, encrypted queue and private defaults suite. The resume phase refuses a missing or foreign marker, restores the previously verified offline account, reads its queued recording, restores the stand network and obtains a real receipt. No other method may reset the stand ledger between these phases. Recreating objects within one host is not evidence of this separate relaunch case.

## Stand controls and proof

Controls exist only on the task-private TLS proxy. Requests use `X-Codex-Control-Token`; there is no product test endpoint. `POST /__e2e/control` accepts `offline`, `dropNextSuccessfulImportResponse`, `offlineAfterDroppedResponse`, `holdNextImportResponse`, `releaseHeldResponses` and `resetLedger` booleans. Offline drops API sockets while control and ledger routes remain usable. The drop occurs only after draining a real successful upstream import response.

`GET /__e2e/ledger?sessionID=<UUID>` reports request body SHA256 values and outcomes, real SQL source/recording/import counts, SQL `chargedRecordingCount`, the actual account balance delta `chargeCount` and the declared `analysisProvider`. `dropped_after_commit` identifies the lost-response boundary. A proxy-generated success or a client callback cannot satisfy these assertions. The tests attach the ledger to the `.xcresult`; retain it with the tested revision and stand revision.

Each normal fixture resets controls and the billing baseline before sign-in. Teardown joins fixture publication, capture, coordinator and account work, invalidates its control session, restores the previous in-process profile, resets task-private proxy controls and removes only its own verified root and defaults suite. The queue phase intentionally preserves its root until resume. A failed test preserves synthetic forensic data and attaches the root path; the task owner must collect the needed evidence and then remove that verified owned root and its `MobileProtectedDeliveryHTTPTests.<runID>` defaults suite. Control reset or root removal failures fail the test explicitly. Simulator and backend cleanup remain with their recorded task owners.

## Direct QA online smoke

Run only `PichiVoiceMobileIntegrationTests/MobileProtectedDeliveryHTTPTests/testDirectQASyntheticCaptureReceiptHistoryAndLocalRemoval` for direct QA. The parent task owns its execution and resulting server writes. This source preparation does not mean QA acceptance has run or passed.

| Test-host variable | Required value |
| --- | --- |
| `PICHI_NATIVE_QA_ACCEPTANCE` | `1` |
| `PICHI_QA_FIXTURE_PATH` | Absolute path to the task-private `0600` QA configuration |
| `PICHI_TEST_REVISION` | Exact combined native commit |

The QA configuration uses the same JSON fields as the local fixture, plus a required `expectedAccountID` containing the verified dedicated account's stable numeric ID as a string. Set `origin` to exactly `https://ai-call-studio.qa.aspirity.com`, `organizationID` to `112` and `workspaceID` to `155`. The dedicated QA account's email and password come only from the user's private configuration. The unused `controlToken` field may be an empty string. Never put actual credentials in Git, shell output, logs or test attachments. The parent task removes the temporary configuration after the run.

QA requires its separate opt-in flag. The local flag and local configuration path cannot enable it. Local cases continue to require exactly `https://localhost:18443` and synthetic `.invalid` credentials; passing a QA configuration to a local case fails before a request. The QA case uses normal system certificate validation on the fixed QA hostname with proxy configuration disabled. It installs no CA or TLS exception and never calls `/__e2e/control` or `/__e2e/ledger`. Use a task-owned simulator; the local stand and its CA are unnecessary for this case.

Before enabling publication, the fixture checks the logged-in email, stable account ID, organization and selected workspace against the private configuration. Unexpected identity or missing editable-workspace permission fails closed. The QA session store keeps its cookie and account envelope in memory. No QA cookie or password is written into the fixture root, defaults, failure evidence or attachments. Joined shutdown clears the memory store without performing remote logout or revoking other sessions.

The case creates one fresh invented recording titled `pichi-native-qa-<runID>`, obtains a receipt from the encrypted durable outbox, and confirms the same source through the frontend's authenticated routes:

- `GET /api/recordings/<receipt.recordingID>` uses the account service's authorized production request path. The existing production receipt codec verifies the owner, source session UUID and canonical source hash.
- `GET /api/workspaces/155/recordings?page=1&limit=30&userId=<dedicated-account-id>` uses the same cookie-owning transport after fresh identity and workspace validation. It examines only the matching newly created recording and checks the title marker, source UUID, owner, workspace and account-context policy.

It then turns current local deletion ON, waits for source removal after the durable receipt, and verifies that the same server record remains in History and detail. Attachments contain only identifiers for the synthetic source and verification outcomes. The case does not attach raw server responses or other recordings. It performs no server deletion, role change, account seeding, deployment, billing mutation or fault injection. Normal import billing and analysis may occur on the dedicated account as part of the authorized upload. The synthetic server record intentionally remains for review, identified by its unique title and source UUID; remote cleanup requires separate authorization.

This smoke checks online ingestion, receipt persistence, ordinary server visibility and local cleanup. It does not prove lost-response deduplication, offline relaunch, SQL charge counts, completed analysis or AI quality on QA. Keep the local fault tests and their SQL ledger evidence separate. Retain the native revision, verified QA deployment revision and safe synthetic-source evidence with the parent task's acceptance result.
