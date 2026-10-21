# Local owner verification diagnostics

The owner verifier can report the scalar values from its existing checks through an optional synchronous callback. This solves one concrete observability gap: the completed owner stage previously reported only encoded/confirmed profile counts, so a failed self-consistency, reference-distance or ambiguity check could not be distinguished. The callback adds no inference, distance calculation, new provider boundary, settings operation or product interface.

`confirmedTokens` retains the existing legacy and streamingV2 policies, complete-link worst distances, first-wins canonical mapping, linked-group short circuit and inclusive comparisons. Only streamingV2 validates duplicate tokens and identity links. The thresholds remain legacy reference/self 0.25/0.25, streamingV2 reference/self 0.65/0.45 and margin 0.10.

## Opt-in and Release behavior

The existing `PICHI_MEETING_DETAILED_PROFILE=1` launch environment enables the owner detail event in an ordinary signed Release build. It uses the existing info-level local support logger, which operates without `DEBUG` or `FLUIDVOICE_DIAGNOSTICS`. No global verbose logging or user-facing setting is added. The default callback is nil and the observer returns nil without formatting clip lengths when the flag is absent or any value other than `1`.

A future diagnostic launch is a separate test from acceptance of an unflagged frozen build. It must retain the same signed build, service composition, model recipe and Save Audio preference, and leave both existing companion options unset:

| Existing option | Effect when combined with detailed profiling |
| --- | --- |
| `PICHI_MEETING_PROFILE_COMPUTE_UNITS=cpuOnly` | Overrides the Fast32 diagnostic compute selection to CPU only. |
| `PICHI_MEETING_COMPUTE_PLAN=1` | Loads the separate Core ML compute-plan probe, with additional time and memory overhead. |

The static audit found these are the only companion environment options in the production meeting source. Detailed profiling alone adds counters, timers and metadata log rows. In the existing retained-recording route it decorates the existing `MeetingPCMReplaySource`; the decorator forwards the same requested range, validation, cancellation and returned samples to the original source, retains only that source and adds timing/count metadata. It does not select the retained-recording route, add a replay pass, open an audio file, create staging storage, alter resource ownership or retain another PCM buffer. The strict Save Audio off streaming route does not acquire this decorator. The Nemotron frontend/model flag only adds timing and numeric counters to existing work. None of the flag checks changes owner thresholds, service selection, residency admission or scheduling policy. Timing/log overhead still means flagged performance results cannot substitute for unflagged performance acceptance.

No launch environment, app, device or recording was changed to implement this patch.

## Privacy and bounds

Each completed verification emits at most one detail event. The report stores at most 128 query observations, using ephemeral input-profile ordinals with no token labels or identifiers. It reports policy/outcome enums, evaluated valid/rejected/skipped profile counts, accepted/rejected group counts, existing self/reference distances, best/runner distances, the existing winner margin and thresholds. Skipped means a linked group's earlier observation failed, so later observations were never measured. `unavailable` never fabricates a missing distance or runner.

The runtime internally maps admitted profiles to their original encoder samples before formatting clip frame counts. The encoder may omit invalid samples, so original sample-array ordinals cannot identify returned profiles. Duplicate/ambiguous input tokens produce unavailable lengths. At most 128 profiles and two clip lengths per profile are logged. Clip counts describe sample lengths at 16 kHz, not exact source timestamps; excerpts can join disjoint clean ranges. No source time range or clean-block rejection count is invented.

Neither the report nor its callback contains owner profile metadata, names, generation IDs, fingerprints, signatures, embeddings, raw PCM, recognized text, credentials, paths or error payloads. The callback captures only scalar strings for logging. It does not add fields to meeting state, checkpoints, transcripts or transcript exports. The existing local support log remains bounded by its normal 1 MiB rotation and 72-hour age policy. Similarity scores are intentionally opt-in local diagnostic data and should be handled with the same care as those support logs.

Synthetic example only, with invented distances and lengths:

```text
mode=streaming owner_verification_detail=completed policy=streamingV2 outcome=referenceDistance profileCount=2 validProfiles=1 rejectedProfiles=1 skippedProfiles=0 validGroups=1 rejectedGroups=1 reportedQueries=2 omittedQueries=0 querySelfLimit=0.4500 referenceLimit=0.6500 marginLimit=0.1000 bestReference=0.7400 runnerReference=unavailable winnerMargin=unavailable queries=[0:querySelfDistance:self=0.5200:reference=unavailable,1:measured:self=0.0800:reference=0.7400] excerptFramesByProfile=[0:80000+80000,1:64000+64000]
```

## Verification scope

`bash scripts/dev/test-runtime-voice-verification.sh` compiles the actual verifier, actual matcher distance/link checks, actual cosine distance, encoder admission and runtime observer into the existing pure harness. It checks both policies, legacy duplicate/link behavior, malformed and inconsistent profiles, linked complete-link rejection, reference and ambiguity failures, callback result parity, missing/invalid owner, bounded output and skipped encoder-input alignment. It exercises the exact launch gate with absent, `1` and `true` values. The harness uses synthetic vectors/clip arrays and a stub info logger, so it verifies formatting and dispatch, not production log delivery or real microphone recognition.

`bash scripts/dev/test-prepared-streaming-runtime.sh` covers the actual prepared streaming caller, cleanup ordering, encoder scope, cancellation, evidence and anonymous fallback with inert models. Swift parsing and portable repository checks provide their own narrower evidence. Native compilation, signed Release log delivery, real voice matching and device behavior remain parent integration checks after the active recording has completed.
