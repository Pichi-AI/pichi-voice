# Built-in dictionary topic protection

The mobile privacy settings expose dictionary entries and expression groups. A fixed local conversational v2 classifier supports the same existing immutable privacy snapshot. There is no model picker, import screen, separate topic toggle or runtime download.

## Policy admission

- With no selected group and no recognized dictionary seed, semantic detection is inactive.
- Selecting `illicit-remuneration`, `procurement-collusion` or `commercial-metrics` automatically selects that classifier topic.
- A complete dictionary entry matching a catalog seed also selects its topic. For example, `взятка`, its recognized Russian forms, and the explicit dictionary seed `откат` select illicit remuneration. The application always uses Russian word forms. Existing stored exact entries retain their IDs and gain word-form behavior at admission; presentation reads do not rewrite private storage. Mutations persist word-form entries.
- Partial catalog matches and ambiguous standalone words such as `ТЗ`, `компания` or `интерес` do not select a topic. Additional seeds are catalog metadata rather than model switches in meeting orchestration.
- The other three groups and unknown custom words retain literal and Russian word-form masking. This fixed three-topic model does not learn a new topic from an arbitrary dictionary entry.
- The enabled data-cleanup function remains the admission boundary. Changing dictionary/group choices applies to new attempts. Admitted snapshots retain their exact model hash, selected topics and fingerprint across later edits or account changes.

The classifier hides complete sentences. Quoted statements, denials and educational discussion can still mention a selected topic. Its published quality limitations and false positives remain relevant; this integration changes activation, not learned weights or thresholds. Text protection does not modify recorded audio.

## Distribution and validation

`SensitiveTopicClassifierSnapshot.bundled` loads `sensitive-topics-v2.json` from the signed application resources and verifies SHA-256 `9952052146978b266af5d6c68855fc95161db36636711630113a4ac0f0f7c734`. Missing, malformed or changed bytes stop semantic policy admission instead of silently dropping protection. The existing classifier bounds, CPU execution, UTF-16 spans, sentence holdback and cancellation remain unchanged.

Model bytes are generated during the app build from the tracked synthetic train/development corpus and original continuation trainer. Weights are never committed to Git. Generation must reproduce the frozen checksum; a mismatch fails the build. TestFlight packaging includes the resulting resource in the app signature. Prior experimental imported-model preferences are no longer read or used for topic selection.

The service uses existing dictionary and profile settings operations. It adds no model server, model residency manager, alternate publication pipeline or persistent model configuration. Each admitted classifier is bounded and released with its existing privacy snapshot owner.

## Verification scope

The settings test runs production profile stores, dictionary service, packaged model loader and classifier. It covers automatic group and declined-word selection, ambiguity and substring controls, immutable fingerprints, unsupported groups, missing/corrupt resources, stale profile mutations and group limits. Simulator UI checks verify dictionary/group controls in Russian and English, light and dark appearances, and absence of model import/navigation controls. Source, build, screenshot and upload receipts are kept in task-owned local release evidence.

The [v2 evaluation](conversational-classifier-v2-evaluation.md) remains the independent quality/resource comparison for these exact weights. Its Mac measurements are not iPad memory, speed or battery measurements. Release availability and physical recording acceptance must be reported separately.

## Inline dictionary editing

As of 3 November 2026, the Add row becomes a focused text field in the same Form, presenting the keyboard without an extra tap. Return or the checkmark saves; the cancel action discards the draft. Existing entries edit in place and support native swipe deletion. There is no matching-mode picker or mode caption. The enclosing Form clears the draft synchronously at private-profile concealment and when leaving the page; each draft owns its bound settings operation. Profile source revision resets the dictionary view identity.

Data-cleanup controls and explanations use the cleanup terminology in English and Russian. Visibility controls for accounts, windows and other unrelated UI retain their own meaning. Low-level exact comparison remains available to reproduce the historical evaluation; application settings expose only word-form behavior.
