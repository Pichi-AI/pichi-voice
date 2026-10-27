# Tablet demo through the existing Pichi session

## Pinned inputs and scope

- Native baseline: TestFlight 0.1.0 (8), `e76e719344ff2229fc53caf4ad32c6c1cfc8b5e2`. It already contains the private profile and publication foundation. This delivery extends that released composition without integrating the unfinished SSO finalize branch.
- Native main checked at start: `0b3db1683509a58f7da9e8636da80c7ca3ece222`. It diverges from TF8; this candidate is based on TF8 and requires separate integration review before any main merge.
- Web main: `90ac3b59702f19c304605b6f2878502cfed51156`. Protected-import PR1614: `10b3c1efc2530fcf699bda9974b63ddb6bcab52d`, still unmerged.
- QA origin from repository deployment configuration, with a successful public health GET: `https://ai-call-studio.qa.aspirity.com`. Health does not establish import deployment or usable test credentials.
- Existing individual email/password login, new protected recording, explicit Send, existing Real calls history and existing assessment. Full OIDC, kiosk mode, CRM and new analytics are outside this increment.

## Small delivery plan

1. Extend the existing account service with an explicit legacy identity and trusted HTTPS origin. Use one isolated in-memory cookie session, fresh `/api/auth/me` and current workspace ACLs. Preserve the shared profile transition, generation and cancellation boundary. Passwords remain transient. Logout warns that the server revokes this user's sessions on every device.
2. Integrate PR1614 into a separate web candidate based on current main, append a nonconflicting migration, and expose honest import/billing/analysis status. Preserve the current importer, edit ACLs, selected employee, source speaker and criteria. An uncertain billing result must never trigger another automatic debit.
3. Extend the existing native publication facade and outbox with a cookie wire adapter. Freeze the protected document and explicit selection before transfer. Keep record-time ownership, source identity, opt-in, account isolation and joined cancellation. Fetch authorized selections before Send.
4. Connect the existing mobile account and publication screens, including Russian/English copy, destination review and explicit confirmation. Do not upload audio, original text, paths or voiceprints, or silently send old history.
5. Run focused synthetic contract/ownership/retry tests and repository checks, then build the combined candidate. Review it independently, fix material findings and repeat affected checks. Validate native UI on owned iPhone and iPad simulators and retain frames for user review before any physical-device stage.

## Verification and limits

The slowest early dependency is first native package resolution and simulator compilation, estimated at 10-20 minutes before UI testing. Lightweight source and wire checks run alongside isolated web checks; no models, physical devices, microphone or audio routing are needed for this phase.

Acceptance requires real in-app legacy login, fresh identity/workspace, a newly admitted synthetic protected source, one authorized import visible in History / Real calls, exact protected text/speakers/timing, selected employee/criteria and a separately verified terminal analysis outcome. Exercise offline/timeout retry, stable source replay, 409, expired/revoked sessions, logout, account A to B and denied workspaces. Code checks and simulator fixture screens do not establish live QA acceptance.

No main merge, remote deployment, production migration, TestFlight upload, external message or physical-device installation is authorized by this delivery. Preserve the other demo chat and stopped SSO resources.

## Updated requirement: automatic delivery and local retention

The user superseded per-record Send with automatic delivery of new completed protected transcripts, retry while the server is unavailable, and a separate setting to delete the local recording after verified server acceptance. The signed-in account owns the recording. A known local speaker may be a hint; absent voice attribution must not block upload or contextual server analysis.

1. Reuse existing scoped consent, capture observer, worker and outbox. Freeze automatic delivery and deletion policy at admission; never enroll old history after opt-in.
2. Before microphone capture, prepare a device-only Keychain recording key, pin encrypted persistence, memory-only audio and Privacy through the existing capture configuration. Preserve the ordinary Save Audio preference. This mode temporarily retains encrypted protected text and metadata, and does not retain or upload audio.
3. MeetingRecordingCipher is one authenticated file codec for existing stores, not a new store/profile/queue owner. Bind AES-GCM to profile ID, session UUID and artifact kind; no cleartext temporary manifest or queue payload. Optional local summaries stay in RAM in this mode. Missing keys, corrupt envelopes and known protected plaintext downgrades fail closed.
4. Restore only an unexpired scoped legacy cookie and a previously verified snapshot from device-only Keychain. Offline restoration permits local encrypted work only. Every remote operation still requires fresh identity and current ACL checks; passwords remain transient.
5. Wake the same worker on source readiness, connectivity and foreground. Offline waiting must not permanently exhaust retry permission. Auth, access, conflict and billing review remain explicit stops.
6. Persist verified receipt plus cleanup-pending before coordinator-owned deletion. Join persistence and retain ownership across partial removal. Preserve local edits made after upload began. Compact accepted state to minimal receipt/fingerprints, without text/names/title. A crash after acceptance retries cleanup or GET, never POST/debit.
7. Web account_context mode derives the employee from the authenticated user, preserves source JSON and performs contextual analysis with an optional known-speaker hint. Freeze current organization criteria at first ingest. Missing criteria gives the existing honest no-criteria outcome; overflow preserves source and reports failure/review without arbitrary selection.

Delivery needs executable app time, protected-data availability and a valid session. iOS force-quit/background scheduling cannot guarantee immediate delivery. The encrypted queue survives restart and resumes under the same validated identity when execution and network access are available.
