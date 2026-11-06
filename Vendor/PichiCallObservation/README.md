# Call observation module SDK v1

`PichiCallObservation` is a Foundation-only Swift package for declaring and evaluating communication app observations. It separates platform knowledge from the macOS recorder, transcription backends and audio admission. It performs no I/O, audio capture, keyboard listening or scheduling. The host owns those resources.

This is a source extension interface, not a dynamically loaded binary plugin system. The package currently lives in this repository and can be consumed with a SwiftPM local path dependency. There is no module download service, settings import UI, separate SDK release or third-party binary loader.

## Contract

Implement `CommunicationObservationModule`, or use `SemanticCommunicationModule` with a descriptor:

```swift
public protocol CommunicationObservationModule: Sendable {
    var descriptor: CommunicationModuleDescriptor { get }
    func matches(bundleIdentifier: String, documentURL: String?) -> Bool
    func evaluate(_ snapshot: CommunicationObservationSnapshot) -> CommunicationModuleEvidence
}
```

The immutable snapshot contains process/window identity, a browser document URL when applicable, bounded control roles/identifiers/labels/values/ancestor identifiers and optional audio activity. It does not contain PCM, credentials, chat history, editable page text or screenshots. Audio activity is not proof of mute or of a connected call.

The result has two independent axes:

| Axis | Values | Meaning |
| --- | --- | --- |
| Call | `indeterminate`, `ringing`, `inCall`, `onHold`, `ended` | Positive phase evidence from the selected call surface |
| Microphone | `indeterminate`, `muted`, `unmuted` | Positive evidence about the local user's transmission control |

`indeterminate` is an internal absence of evidence. It is never a new user-visible microphone state and never resets the host's remembered state. Pichi starts an observation attempt unmuted by product policy. Explicit mute/unmute transitions latch until a later explicit transition. Ringing, hold and end may close transmission admission without pretending the user clicked mute.

Keyboard down alone must never produce unmute. A declared PTT chord only associates a subsequent visible unmute with a temporary grant. Key-up closes that grant using acquisition time. Focus/listener loss closes only a known temporary grant, preserving ordinary persistent unmute. The current host default for this loss policy is an implementation choice awaiting separate product confirmation.

## Add a declarative module

1. Copy [the synthetic example](Examples/synthetic-web.callmodule.json), keeping a unique reverse-domain-style ID and schema version 1.
2. Replace the example identities with verified native bundle IDs or browser bundle IDs plus exact service origins. Do not guess a native bundle ID from a product name. Tenant/self-hosted origins need explicit rules.
3. Discover local call controls with Accessibility on the actual client. Prefer stable identifiers and `ancestorIdentifier` for the self toolbar. Labels are exact normalized matches, not arbitrary substring search. A button labelled with an action has the opposite current state: `Turn on microphone` proves muted.
4. Declare connected/ringing/hold/end controls separately. Device tests, prejoin pages and a persistent dialer window are not connected calls. Do not match another participant's moderation button.
5. Decode with `CommunicationModuleDescriptor.decode(data)` and construct `SemanticCommunicationModule`. Register it once in a `CommunicationModuleRegistry`. Invalid descriptors, duplicate IDs and over-capacity registries throw. Multiple matching modules resolve to no evidence instead of choosing by registration order.
6. For the app, add a separate file under `Sources/Fluid/Services/Meeting/Observation/Modules/` and register it in `MeetingCommunicationModuleHost`. The recorder and transcription coordinator must remain unchanged. A platform requiring rendered evidence supplies a host-side adapter through the existing registration factory.
7. Add synthetic contract tests, then perform a short real-client smoke test before declaring that client/version/language validated. Capture native self-control identities and both mute transitions in private evidence; never commit customer screenshots or call recordings.

For more complex call-leg semantics, implement `evaluate` directly over the same snapshot. The current generic host pins one process/window/document per recording; it does not expose a universal SIP call-ID or arbitrary in-process media stream. If two call legs share one unscoped window, an adapter needs verified self/call-leg ancestry before it can safely resolve them. Do not guess.

## Descriptor format

The authoritative decoder and validation are in [CommunicationObservation.swift](Sources/PichiCallObservation/CommunicationObservation.swift). Only `schemaVersion`, `id` and `displayName` are mandatory JSON keys, but an active descriptor must declare a native identity or browser identities with URL rules. Omitted arrays are empty, scheme restrictions default to HTTPS and subdomains default off. `researchOnly` profiles are excluded from normal candidates. Provenance labels are informational, not permissions or a security boundary.

| Field | Purpose |
| --- | --- |
| `nativeBundleIdentifiers` | Exact native owner identities |
| `browserBundleIdentifiers` | Browser identities; host also recognizes their `.app.` PWA namespace and still requires a matching URL |
| `urlRules` | Host, optional subdomains and segment-bounded allowed/excluded path prefixes; credentials rejected |
| `callRules` | `connected`, `ended`, `ringing`, `held` selector arrays |
| `microphoneRules` | `muted` and `unmuted` selector arrays |
| Selector | `role` (default AXButton), `identifier`, `labels`, `ancestorIdentifier`, `expectedValue`, `allowsShortcutSuffix` |
| `pushToTalkChords` | macOS physical key code plus exact modifiers; no remapped key assumption without evidence |
| `nativeWindowIdentifiers`, `nativeWindowTitles` | Optional additional exact native call-surface constraints |
| `validation` | `researchOnly`, `contractTested`, `nativeValidated`; the report records actual scope |

`allowsShortcutSuffix` permits a tightly constrained keyboard shortcut suffix such as `(Cmd+Shift+M)`. It does not permit arbitrary parenthetical participant names. Conflicting phase/self-mic controls yield indeterminate evidence. The descriptor data is limited to 64 KiB; the validator also bounds modules, rules, selectors, labels and chord counts. Programmatic construction must still call validation.

## Host lifecycle and cost

`MeetingCallObservationService` owns discovery attachment, active recording tokens, one adaptive scheduler and one passive PTT listener. Discovery ticks every 2 seconds. Active microphone observation ticks every 250 ms; the shared AX probe limits rediscovery to once per second, validates cached ancestry and bounds native requests. The Zoom/Meet adapter retains its existing small image capture path. These are configured budgets, not measured CPU or transition latency guarantees.

Stop closes delivery before joining the adapter. Old callbacks cannot affect a later recording. Each recording pins an immutable registry snapshot; active and draining observers share a capacity bound. Modules must not add timers, permissions, audio devices, logging of user text, network activity or unowned background processes.

## Verification

```sh
swift test --package-path Vendor/PichiCallObservation --scratch-path .build/call-module-sdk -j 2
```

This validates the SDK only. App integration is in the existing macOS XCTest target. Real platform acceptance and observed UI delay remain separate. Local UI polling cannot establish sample-exact mute suppression in the absence of a platform timing contract. See [the platform review](../../docs/research/communication-platforms-2026-11.md) for current coverage and limitations.
