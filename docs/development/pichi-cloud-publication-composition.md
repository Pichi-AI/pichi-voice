# Native protected publication composition

Desktop and mobile retain one `PichiCloudPublicationService` over their existing
`AccountSessionService`, `PrivateProfileService` and `PrivateProfileMeetingStore`.
Views obtain that same instance through `AppServices.cloudPublication`. The native
cloud publication controls consume the facade, without creating an outbox, account
lifecycle or HTTP client in a view.

`PichiCloudPublicationActivation` owns installation and the short activation task.
The composition waits for observer and transition participant installation before
calling account restore. The production profile's existing busy admission also
refuses sign-in until installation succeeds. Failed installation leaves this gate
closed. HTTP is constructed only from the account's trusted configuration. Missing
configuration remains an installed, inactive guest composition. Consent defaults
to off and activation never opts in or claims earlier guest/local-only recordings.

N1 publishes its context and state before its authentication command and operation
slots finish. A single immediate publisher callback cannot establish readiness.
The activation owner coalesces these notifications, joins the cancelled predecessor,
then captures the committed account context, profile and source revision. It waits
at most five seconds for the exact N1 context to become current, checking source
readability and admission at every await. A new profile, concealment, cancellation
or shutdown invalidates that attempt. A durable non-signed-in state refreshes the
sanitized publication projection, including the reauthentication pause. N5 retains
its own scope, consent, cancellation and network admission checks.

Initial restore explicitly awaits activation after the account command returns.
Later account commands and committed source changes are covered by the same
observers. Source restoration can request the same coalesced activation. Shutdown
removes these observers, cancels and joins activation and installation, and awaits
publication shutdown before shutting down N1's account transport.

Mobile fixture composition accepts any `MeetingSessionStoring`. A generic injected
store has no cloud publication facade, does not install an observer in the global
store, and cannot create production HTTP. A deliberately injected
`PrivateProfileMeetingStore` can receive an explicitly injected publication HTTP
transport. It never inherits a production transport from its injected account.

The N5 delivery source manifest registers exactly the eight N5 files and this activation
owner. It contains no `MobileAccount.swift` or dependency on N3 UI types. Its `MobileApp`
service container exposes the retained facade, while the `MobileOnboarding` and
`MobileMeetingRoot` call sites retain their existing signatures. N3 owns the later account
and cloud argument injections in its own delivery PR. N4 consumes the same service seam.

This is the projected N2 contribution from `32e5575496ffa9ea2a0bff1efeae989ce2a3e271`.
The delivery branch starts at published N5 `032ad7e3` and merges only focused N2
`ccd61fb78c1156432f339e03b4dd1ed596e3317e`. No coalesced snapshot or full N3 branch is
merged. Profile preparation, concealment and capture ownership code stays with N2. The
resolved roots preserve its retained capture admission and private-source cleanup alongside
the cloud installation gate; Local API restoration precedes cloud activation. The frozen shared catalog is imported as the exact
N3-authored `5bf11971` resource, with N3 retaining semantic ownership.

Run `bash Tests/run_publication_composition_tests.sh` for synthetic tests over the
actual frozen N1, N2 and N5 sources, in-memory credentials and an inert HTTP owner.
The fixture covers coalesced installation, pre-install sign-in refusal, real early
N1 notifications, closed-source activation, later workspace activation,
reauthentication, busy logout, cleanup retry, transport shutdown order and late
notifications. It makes no publication requests, loads no models and opens no UI.
`python3 -S Tests/test_build_identity.py` checks project regeneration. Native builds,
interactive acceptance and live API validation are separate parent-owned gates.
