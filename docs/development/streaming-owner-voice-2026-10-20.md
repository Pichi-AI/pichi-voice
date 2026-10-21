# Live owner voice verification

## Status

The saved owner can now be identified during an ongoing streaming meeting. Positive native simulator integration is verified. False-owner and physical-device acceptance remain open.

- Base: `255039931e9578c0f1daf74e4ea3267c20047896`.
- Branch: `codex/owner-voice-streaming-20261020`.
- Reviewed application revision: `0695937c3e76ef9b52cf19629d6a24544365c654`.
- Native identity/UI regression revision: `e80a49bf7e6654a171ea21923c466971da3da545`. Application sources are identical to `0695937c`; this revision only marks a custom fixture alias as manual metadata.
- Later candidate: `629a04d344254ea3c13ad226111f078794242698`. It adds enrollment resource admission, frozen participant-label metadata and the shared-source manifest correction described below. Native verification of these later changes is pending in the settings/onboarding integration; earlier measurements do not validate them.
- No physical installation, microphone test, main merge, TestFlight modification or update to PR25 was performed.

## Cause and change

The earlier prepared streaming scope collected clean voice clips while recording, but called the voice encoder and owner verifier only after `finishStreaming`, ASR cleanup and diarizer cleanup. This made a live owner label impossible even with a valid saved reference. Enrollment and matching already shared the pinned encoder, and a fresh recording already took a fresh immutable profile snapshot.

The registered V3 recipe now runs bounded voice verification on the existing serial controller worker after acoustic scoring. It compares actual embeddings against the immutable saved reference. It does not infer ownership from the first speaker, capture source or transcript text.

The optional `confirmedLocalUserTokens` observation field addresses a separate integration problem: acoustic evidence can precede canonical ASR/privacy speaker admission. The state holds this bounded decision and applies it when the same stable participant is admitted. An empty decision revokes a previous match. The observation cannot create a participant, publish unprotected text or advance the ASR source cursor.

Relevant implementation:

- `Sources/Fluid/Services/Meeting/Backend/MeetingPreparedStreamingRuntime.swift:265`: serial verification, bounded profile cache and acoustic decision publication.
- `Sources/Fluid/Services/Meeting/MeetingStreamingPCMController.swift:33`: ephemeral owner decision contract.
- `Sources/Fluid/Services/Meeting/MeetingStreamingTranscriptState.swift:140`: epoch validation and admission independent of text readiness.
- `Sources/Fluid/Services/Meeting/Backend/MeetingSpeakerVoiceModelArtifacts.swift:96`: exact V1/V2/V3 recipe compatibility.

The existing V2 distance, self-consistency and ambiguity limits are unchanged. Earlier anonymous, owner-V1 and owner-V2 recipes retain their original behavior. Their saved attempts do not silently acquire live inference.

## Evidence, scheduling and resources

The evidence selector still requires two disjoint clips containing at least three usable speech seconds each. Turn edges, overlap, poor signal, clipping and unscored audio are excluded. Six usable speech seconds are an evidence floor, not a promise of six-second visible recognition.

V3 retries after two new clean speech seconds until ten seconds have accumulated, then after each additional ten clean seconds. A final changed tail is evaluated once. Unchanged progress and silence do not repeatedly reload the encoder; silence may first settle previously unscored speech at the admission horizon.

The collector retains at most 256,000 PCM frames plus 1,344,000 clean/pending voice frames across eight slots, about 6.10 MiB of Float payload. Temporary excerpt copies and model allocations are additional. Only eight two-vector profiles survive an encoder call, at most 4,096 Floats. Neither audio evidence nor embeddings enter meeting storage or exports.

Idle preparation primes the same validated encoder on synthetic silence through the existing resource owner. `TranscriptionExecutor.runBlocking` keeps native compilation off the UI executor and joins cancellation. The model and temporary buffers leave their scope before preparation returns. This primes model execution without microphone use, profile writes or identity evidence. A recording may still begin before optional idle work finishes, so measurements must include or separately disclose that wait.

- `Sources/Fluid/Services/Meeting/Backend/MeetingProductionParakeetNemotronRuntime.swift:591`: existing idle preparation owner and optional voice priming.
- `Sources/Fluid/Services/Meeting/Backend/MeetingSpeakerVoiceEncoder.swift:47`: bounded synthetic preparation using the same model setup as enrollment and matching.

Encoder failure preserves anonymous transcription and stops repeated optional attempts in that recording. Cancellation joins the current native call before cleanup and resource restoration. Model selection, profile and artifact paths remain fixed for the attempt.

Independent integration review found that enrollment's audio lease alone could leave optional idle voice preparation running: a meeting may adopt idle resources, while enrollment creates its own encoder. Enrollment now calls the existing `beginOperationRetiringIdle` before microphone selection or capture construction and holds the ordinary model-operation token through capture, encoding and cleanup. It releases that token before returning the audio lease. This joins active idle retirement and rejects a queued idle load during enrollment. Three native regressions cover joined cancellation, queued idle rejection and admission failure without constructing capture hardware. Those new regressions have not yet completed native execution.

- `Sources/Fluid/UI/MeetingOwnerVoiceSettings.swift:140`: enrollment admission and cleanup order.
- `Tests/MobileIntegrationTests/MeetingOwnerVoiceEnrollmentCaptureTests.swift:13`: isolated real residency-owner regressions with a capture factory that throws before hardware access.

The mobile shared-source manifest now includes the existing `MeetingTimelineTrace.swift`. The checked-in project already included this source; project regeneration previously dropped its membership.

## Participant names and compatibility

The previous ordinal allocation counted the owner in `priorSpeakers.count`. Later setting `isLocalUser` therefore left a gap in participant numbering.

New automatically named identities carry optional `generatedParticipantNumber` metadata. Zero marks an automatically named owner. Other generated names are numbered in stable admission order, excluding owners and merged identities. Renaming clears the marker; undo restores both the prior name and marker. Missing metadata preserves older records and manual aliases without parsing translated labels. Speaker UUIDs and acoustic assignments do not change when a name is renumbered.

- `Sources/Fluid/Services/Meeting/MeetingModels.swift:833`: backward-compatible metadata and shared generated-name numbering.
- `Sources/Fluid/Services/Meeting/MeetingModels.swift:1126`: manual rename provenance.
- `Sources/Fluid/Services/Meeting/MeetingSessionCoordinator.swift:208`: rename undo metadata.

Protected word IDs, timestamps, privacy admission, audio source acknowledgements and the existing bounded word tail remain under their existing owners. Identity updates do not rewrite earlier raw inference evidence or introduce source labels as participant names.

The producing attempt now carries its frozen participant-label template in ephemeral `MeetingPCMTranscriptBatch.speakerNameFormat` metadata. Privacy holds, speech-boundary flushes, final tails and durable speaker merges retain that template. An interface-language change during recording cannot replace generated labels with the current global format. Explicit aliases remain untouched; this adds no translated-label parsing or persisted template field. This follow-up originated in the settings/onboarding integration and is included in the later candidate above.

## Native measurements

Two 45-second trials used the exact approved 20-second owner recording followed by 25 seconds of explicitly generated zero PCM. This is a scheduled local replay, not a fresh microphone recording. The simulator test used the existing real GigaAM, fast128 CPU diarizer, voice encoder, A1 privacy service, coordinator, store and production meeting view. The existing enrolled reference was copied only into task-owned simulators and verified unchanged against the original after testing.

Application revision: `0695937c3e76ef9b52cf19629d6a24544365c654`. Both frozen simulator products were signed locally and hash-verified before use. These timings are Mac CPU simulator measurements, not iPad or iPhone hardware measurements.

| Measurement | iPad Simulator | iPhone Simulator |
| --- | ---: | ---: |
| External XCTest result | 1 passed, 0 failed/skipped | 1 passed, 0 failed/skipped |
| First acoustic confirmation, approximate | 16.945 s | 16.837 s |
| First protected canonical word linked to owner | 21.8137 s | 21.8121 s |
| Live owner identities | 1 | 1 |
| Protected word elements before Stop | 14 | 14 |
| Final word elements | 46 | 46 |
| Sampled process peak | 562.36 MiB | 563.36 MiB |
| Process CPU time for the measured interval | 26.872 s | 26.738 s |
| MainActor queue-entry p95 | 83.0 microseconds | 80.7 microseconds |
| Native frames saved | 55 | 55 |
| Missed frame schedule slots | 1 | 0 |
| Frame capture errors | 0 | 0 |
| New persisted audio paths | 0 | 0 |

The acoustic timestamp is the encoder-end timestamp immediately before the confirmation decision. The protected-word timestamp measures canonical application state sampled during paced delivery. Neither is a precise display-frame timestamp. Native frames independently show the actual owner heading while recording continues, with UI timers at 00:22 and 00:21 respectively. All valid frames and decoded-pixel change indexes are retained privately; the iPad run does not provide complete one-second coverage.

The first live encoder call took about 144 ms after idle preparation in the iPad trial. The initial idle voice preparation took 5.340 s and partly overlapped the recording admission. An earlier cold comparison took 5.844 s for its first live encode. This demonstrates where cold preparation cost occurs, not a controlled whole-application resource improvement. The cleanup footprint delta includes runtime caches and does not establish a leak or prove complete memory retirement.

A separate real-encoder scalar diagnostic matched the saved reference at the seven-second source checkpoint and refused the six-second source checkpoint because it contained insufficient admitted clean speech. That diagnostic assumes the reviewed single voice for selection and does not include production diarizer, ASR or display latency.

These private references contain one reviewed voice and no text anchors or PII cases. The passes establish owner integration for that source, not general ASR, privacy accuracy, speaker accuracy, touch latency or thermal performance.

## Other voices and remaining accuracy gate

A 94-second scheduled replay used two weakly labelled real voice groups, the confirmed owner, 30 seconds of zero PCM and a replay of the same owner excerpt. It completed with three native profiles, one final owner, 103 protected elements before Stop, 163 final elements and no new persisted audio paths. The two other generated identities retained sequential participant labels. A repeated source is not independent new speech evidence.

This runtime pass is **not false-owner acceptance**. One unreviewed comparison voice temporarily passed the existing owner policy, then additional speech revoked that decision. Its real identity is awaiting human review. No threshold has been tuned to that weak label. The next calibration decision requires confirmed negative identities and preservation of the positive source. Private scores, recordings, references, signatures and transcripts remain outside Git.

The main coordinating chat owns the human identity questions and subsequent physical review. The heavy native/model slot was explicitly handed to the settings/onboarding session after these tests. Generic Parakeet/Whisper streaming registration work is separate and needs combined validation; this branch keeps the existing GigaAM registration.

## Checks and review

| Check | Result and scope |
| --- | --- |
| Worktree guard | Passed in isolated task worktree at the requested base |
| Portable repository checks | Passed again after the later candidate and report update; initial setup's runner timing failure did not reproduce on the complete rerun |
| Prepared streaming actual-source harness | 19 contract groups passed, including pre-Stop decision, retry cadence, optional failure, scope ownership and joined cancellation |
| Protected tail / registry / admission / state probes | 28,990 / 133 / 175 / 3,197 checks passed |
| Voice verifier actual-source probe | Passed under absent, `1` and `true` diagnostic gates; synthetic vectors and immutable recipe compatibility |
| Isolated numbering storage/export probe | 675 checks passed before integration; native combined checkpoint tests also passed |
| Mobile build-for-testing | Passed, both simulator architectures, isolated DerivedData and packages |
| Native identity, aliases, store and caption contracts | 18 passed, 0 failed/skipped on each simulator at `e80a49bf` |
| Native settings UI, English/light and Russian/dark, portrait/landscape | 1 passed, 0 failed/skipped on each simulator at `e80a49bf` |
| Real 45-second positive streaming integration | Passed on both simulators at `0695937c` |
| Real scheduled 94-second mixed/pause replay | Runtime passed on iPad Simulator at `e80a49bf`; identity accuracy remains unaccepted |
| Later enrollment admission and frozen-label regressions | Independent source review complete; combined native execution pending in settings/onboarding integration |
| macOS application regression | Not executed in this session; queued for combined integration after native resource-slot handoff |
| Physical device/microphone acceptance | Not executed; requires simulator review and the remaining identity gate |

The original short speech/silence probe incorrectly required a nonzero immutable committed prefix before Stop even when already published protected words were all still in the bounded attribution/privacy tail. The corrected test requires real canonical checkpoints and protected words, scored ASR/acoustic progress, pre-Stop owner publication and full EOF commitment. The earlier failed run remains failed. It is not counted as a green trial.

An initial native contract run also exposed a manually named fixture retaining the new generated-name marker and two English fixture assertions running under a forced Russian test locale. The fixture now marks its alias explicitly, and the contract suite runs under its normal English test locale. Production rename operations already clear the marker and preserve it in undo.

Independent automated code review covered the integrated revisions through `e80a49bf`, including existing extension points, absence of model/brand/language switches in common orchestration, bounds, profile immutability, ambiguity/revocation, cancellation, resource ownership, persistence and upstream impact. Its protected-tail formatter finding was fixed: every tail merge now passes its frozen format. Subsequent review identified two default-format callers in `MeetingPCMIdentityState.commit` and `checkpointMemoryTranscript` and the enrollment/idle-preparation overlap. Both fixes are included in the later candidate above. A final independent read-only review of exact `629a04d344254ea3c13ad226111f078794242698` found no material actionable issues; it did not run compilers, inference or UI. Independent evidence review separately verified frozen hashes, source composition, simulator reports, counts, timing definitions and frame indexes. The later code review is separate from native acceptance of those changes.

All raw evidence remains in ignored local task storage. This report intentionally contains no private source paths, audio hashes, profile metadata, embeddings, transcripts or private distance measurements. Do not merge, ship or claim false-owner acceptance from the positive/runtime passes alone.
