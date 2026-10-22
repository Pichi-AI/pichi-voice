# Owner confirmation with full streaming evidence

## Status and revisions

V4 is an experimental development candidate. Human review confirmed that both disputed control excerpts are nonowner speech. The previous transient confirmation of control B is absent from the V4 decisions and observations in the development replays below. General identity accuracy and delivery are not accepted.

- Base: `9c1a50fffd7f3dc893c95738100ce84345e34d6b`.
- Branch: `codex/owner-v4-full-evidence-20261021`.
- Initial frozen mobile revision: `f70a21011085b5775300a0b94377baa227c11f1e`.
- Final code and second frozen mobile revision: `378f4792ad57da661f6294a243df6d61dcc8e889`.

The latter changes one desktop test default argument. Production sources, mobile tests and the Xcode project are identical between these revisions. Results retain their actual binary revision. Each mobile freeze has 161 verified files, an embedded source revision and a valid development signature. The final desktop build and tests use an isolated bundle namespace with audio startup disabled.

## Change and architecture

Short query profiles could pass the existing numerical owner policy before enough clean speech had accumulated. V4 preserves the existing reference-distance, self-consistency and ambiguity limits. After ranking the complete valid candidate set, it additionally requires the winning profile's actual encoded inputs to contain two disjoint five-second clips at 16 kHz. Short competitors still participate in ambiguity checks; an immature winner cannot promote a weaker mature candidate.

The existing verifier accepts optional frame-count proof bound to unique encoder inputs and outputs. The prepared runtime caches each profile and its proof together, within its existing eight-candidate bound. Changed, missing, duplicate or failed evidence revokes confirmation. Unchanged evidence survives silence and unchanged EOF.

The existing frozen recipe selects V4 at the runtime leaf. Enrollment, encoder fingerprints and saved profile formats are unchanged. Exact V1/V2/V3 recipes retain their prior behavior. V4 retained retries discard only the cached owner decision, recollect the complete candidate evidence and retain independent ASR/diarizer checkpoints. Missing competing-track evidence or optional strict-read failure leaves identity anonymous while preserving available transcription.

No new provider hierarchy, coordinator model switch, brand default or localization branch was introduced. Independent review covered these boundaries, bounded caches, cancellation, resource ownership, compatibility and upstream impact. Its incomplete-rival and legacy read-failure findings were fixed before the final review of `378f4792`.

## Checks

| Check | Actual result |
| --- | --- |
| Portable repository checks | PASS at `f70a2101` and after documentation updates |
| Actual-source verifier probe | PASS with diagnostics absent, `1` and `true` |
| Actual-source prepared runtime | 24 groups PASS at `dd05feb9`; tested declarations unchanged afterward |
| macOS build-for-testing | PASS at `378f4792` |
| Native retained-backend class | 68 PASS, zero failures/skips at `378f4792` |
| Mobile arm64 build-for-testing | PASS at both frozen mobile revisions |
| Native mobile contracts | 33 PASS per form, zero failures/skips; iPad at `f70a2101`, iPhone at `378f4792` |
| Integrated code review | No material remaining findings at `f70a2101` and `378f4792` |

The earlier iPad contract attempt ran its 33 tests but failed its preservation harness after XCTest relocated the data container. It remains excluded from accepted complete runs. The corrected runner resolves the current container and verifies the unchanged profile before and after every case.

## Native development matrix

Every replay uses the registered composition, actual ASR, fast128 diarization, WeSpeaker, A1, production coordinator/store and native meeting view. Source PCM is injected in paced 100 ms blocks. This is simulator evidence, without physical microphone capture.

| Composition and source cases | iPad native result | iPhone native result |
| --- | --- | --- |
| GigaAM: A, B, A+B, owner positive, mixed pause/return | 5 PASS at `f70a2101` | 5 PASS at `378f4792` |
| GigaAM: original 8 s owner + 25 s silence | FAIL at `f70a2101` | FAIL at `378f4792` |
| GigaAM: additional 8 s owner + 20 s silence | PASS at `378f4792` | PASS at `378f4792` |
| Parakeet: positive, mixed, B | 3 PASS at `378f4792` | Positive PASS at `378f4792`; mixed/B not repeated |
| Tiny: positive, mixed, B | 3 FAIL at `378f4792` | Positive FAIL at `378f4792`; mixed/B not repeated |

There are 22 model replays: 16 native passes and six native failures. All 22 identity oracles pass, including the failed native cases. This does not convert the six full-flow failures into passes.

The oracle checks every real verification and every emitted owner observation against human-reviewed source intervals and the native clean-range support. It requires actual candidate evaluation, complete event sequences, closed trace counters, zero dropped/truncated events and exact EOF coverage including the harness's 88 terminal samples. Raw artifact review independently reconstructs the source support and audits all 70 core evaluations and 276 emitted observations. No negative token is confirmed, including after the real owner appears. All four short-owner cases emit zero owner tokens and produce two insufficient-evidence decisions each. Mature negative evidence is evaluated in the control cases; short abstention is reported separately.

## Timing and native frames

Times are seconds from the harness capture clock. Canonical state is sampled during paced input; it is separate from a display timestamp.

| GigaAM case | First core confirmation | First canonical owner | First saved visible owner timer |
| --- | ---: | ---: | --- |
| iPad positive | 24.089 | 24.103 | `00:24` |
| iPhone positive | 24.115 | 24.203 | `00:24` |
| iPad mixed | 43.694 | 43.712 | `00:45` |
| iPhone mixed | 43.690 | 43.709 | `00:44` |

The first owner speech in the mixed source spans 24 through 44 seconds. Core and canonical confirmation occur during that turn. Saved frames bound the iPad visible transition after timer `00:43` and by `00:45`; the intervening frame is missing. The phone transition is bounded after `00:42` and by `00:44`. These observations do not establish an exact display latency or visible confirmation before the pause.

All 1,336 model-replay frames are retained with decoded-pixel change indexes. There are 25 missed schedule slots and zero capture errors. This is not complete one-second coverage. Contract-test captures are separate. Independent saved-image review covers 25 contact sheets, 269 grouped content states and 23 full native frames across iPad light and iPhone dark. No material control overlap, clipping or unreadable text was observed. The existing phone footer guidance truncates with an ellipsis. Transcript-region grouping selects changed content while the original full-frame indexes retain timer and status changes; this does not verify every intermediate status state or scrolling behavior.

## Open gates and data scope

The original 33-second short-source cases have no canonical text before Stop, despite correct identity abstention and final recognized, attributed text. They remain FAIL. The additional 28-second variant was created after observing that failure by removing only five seconds of generated silence. It fits the existing under-30-second test contract, which does not require pre-Stop canonical output. Its pass does not fix or erase either original failure. No source assertion was relaxed.

Tiny also remains unaccepted for the complete owner-label flow. In its positive iPad case, owner confirmation precedes canonical admission, but the indivisible native utterance spans multiple positive acoustic tokens and correctly remains ambiguous under the existing attribution policy. The owning attribution implementations are unchanged from the base. This is evidence of inherited policy, not an empirically passing baseline replay. Other Tiny cases expose delayed privacy release or missing live owner attribution. No word timing was invented and no attribution rule was relaxed.

A/B are two reviewed excerpts, without proof that they represent two distinct people. The owner trims and repeated return are from the same source session. The development/source-session split was recorded before V4 model evaluation, but no approved independent owner/nonowner holdout sessions were available. These results do not estimate a general false-acceptance rate, ASR/PII accuracy, physical-device latency, thermal behavior or long-session reliability.

Audio, source pins, profiles, embeddings, transcripts, signatures and detailed evaluation artifacts remain outside Git. Final preservation checks verify the original enrollment, task copy and both simulator copies unchanged, plus both frozen product sets and signatures. Both owned simulators are shut down. Installed applications, physical devices and TestFlight delivery were outside this experiment.
