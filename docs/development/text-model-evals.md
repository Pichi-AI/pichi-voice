# Russian summary and AI enhancement evaluations

The opt-in [native runner](../../Tests/FluidDictationIntegrationTests/PichiTextModelEvalTests.swift) compares local text models through the application's existing contracts. It changes no selected model, provider, prompt, preference, original model tag or global server parameter. Normal CI skips inference. The checked-in [corpus](../../Tests/Fixtures/TextModelEvals/russian-v1.json) contains eight authored summary cases and eight authored dictation cases. It includes no user recording or transcript.

## Request profiles

| Task | Actual exercised path | Configured evaluation profile |
| --- | --- | --- |
| Summary | `PichiMeetingSummaryGenerator`, canonical validation, reconciliation and `PichiMeetingSummaryTransport` | Native Ollama, context 8192, output 3000, temperature 0, thinking off, `keep_alive=0` after every request |
| AI enhancement | `SettingsStore` built-in cleanup prompt, `DictationPromptRequest` JSON transcript envelope, `LLMClient`, thinking separation and existing output formatting | OpenAI-compatible Ollama endpoint; explicit bounded alias server context 8192/output 3000; existing `maxTokens=3000`, temperature 0.2 and existing reasoning configuration `reasoning_effort=none` |

The enhancement profile represents an explicitly configured existing provider. It is not a claim that arbitrary original model tags have the same context cap. The production enhancement service normally sets temperature 0.2 and no output/context cap. Summary and enhancement temperatures differ as they do in the application. Do not replace either task's prompt per candidate or compare a reasoning-only candidate with the nonthinking profile without recording a separate experiment. Unsupported API options, output truncation and rejected evidence are failures, not zero-quality accepted responses.

The parent creates unique local aliases with the official Ollama Modelfile `FROM <installed-base-id>`, `PARAMETER num_ctx 8192` and `PARAMETER num_predict 3000`. Alias creation reuses installed weight blobs. It must preserve every original tag and digest. The runner verifies the alias manifest hash, context/output fields, and installed original plus alias digests before inference. Do not repoint an alias while an evaluation is running. Only the parent owns server inference and runtime sampling; other agents must not run model requests concurrently.

After every attempted fixture for either task, including errors and cancellation, the test explicitly awaits an official loopback `/api/generate` unload request for that alias with `keep_alive=0`. Cleanup failure aborts the matrix and marks isolation as failed. Cancellation cleanup uses a bounded task whose completion is joined before the runner exits. It never unloads unrelated model identifiers. A summary's native transport already requests unload after each request, and the extra joined barrier also covers client timeouts and cancellation. Models requiring reasoning cannot be declared working under a profile that disables it.

## Running a bounded slice, then the matrix

Build the current integrated Debug test target using its own worktree and package/build directories. Prepare an ignored local JSON plan with this shape:

```json
{
  "sourceCommit": "<40-character reviewed source commit>",
  "sourceRoot": "<absolute current task worktree>",
  "fixturePath": "<worktree>/Tests/Fixtures/TextModelEvals/russian-v1.json",
  "outputDirectory": "<worktree>/.build/text-model-evals/results",
  "aliasManifestPath": "<worktree>/.build/text-model-evals/alias-manifest.json",
  "serverProfileSHA256": "<SHA256 of exact alias manifest bytes>",
  "models": [{
    "id": "<unique local eval alias>",
    "digest": "<installed alias digest>",
    "baseModelID": "<installed original identifier>",
    "baseDigest": "<unchanged original digest>",
    "usesLibraryAlias": true,
    "quantization": "<verified quantization>",
    "parameterSize": "<verified parameter count label>",
    "modelBytes": 1
  }],
  "caseIDs": ["summary-assignment-decision", "enhancement-clean-punctuation"],
  "repetitions": 1,
  "enhancementStreaming": false,
  "finalists": []
}
```

The hash-checked alias manifest has an `aliases` array with each model's `id`, `digest`, `baseModelID`, `baseDigest`, `usesLibraryAlias`, `numCtx=8192` and `numPredict=3000`. The plan must use actual verified `modelBytes`; the example value is a placeholder. First run one model and a small case selection. Check the ignored response files and runtime samples before scaling. Remove `caseIDs` to run the complete 16-case corpus. For finalist identifiers in `finalists`, the runner repeats critical cases at least twice with the same profile, source and prompt. Repetition is a reliability probe, not a confidence interval from a large dataset.

The main matrix uses the existing nonstreaming postprocessing request path. After choosing finalists, an explicitly separate plan with `enhancementStreaming=true` exercises the existing `LLMClient` SSE path on a small enhancement slice. Keep its report separate; it is a transport compatibility smoke check rather than a new full quality score.

Set `PICHI_TEXT_MODEL_EVAL_PLAN` on the **test bundle environment** inside the current `.xctestrun`, then run:

```bash
xcodebuild test-without-building \
  -xctestrun <current-worktree-test-run-file> \
  -only-testing:FluidDictationIntegrationTests/PichiTextModelEvalTests/testRussianTextModelEvaluationWhenExplicitlyEnabled
```

For format-2 `.xctestrun`, locate the test bundle dictionary recursively and change its `EnvironmentVariables`; a shell environment alone may not reach the host. Keep `.xctestrun` in its build products directory so `__TESTROOT__` continues to resolve. Never replace or sign the frozen user-facing app to run this quality matrix.

The runner writes incremental `evaluation.json` only inside an ignored `.build` directory. Each row records case, model, repetition, start/finish UTC, elapsed time, completion call count, request-body and message hashes, content, canonical summary or raw enhancement answer and separately formatted enhancement output, rejection category, deterministic gate results and the independent review rubric. It records exact source-file, corpus, default cleanup prompt and alias-manifest hashes. The two existing GAAV output-formatting flags are recorded at start; a change aborts the matrix after joined cleanup rather than mixing mutable formatting profiles. `response.thinking` is discarded and never used for judgment. Answer content remains local, including rejected structured responses; recognized embedded thinking tags are stripped by the existing client parser before audit persistence. Completion call counts include generator regeneration and reconciliation, but the existing LLM client may internally retry HTTP requests; these counts are not an exact HTTP request total. These are test artifacts, not analytics payloads or committed reports.

The native summary transport records `output-limit` only for a completed response whose `done_reason` is exactly `length`. An incomplete response or an empty completed response without that reason remains a transport rejection. The generator can retry a truncated first extraction by partitioning the same immutable source chunk at intact-turn boundaries, in chronological order, with three subdivision levels and a 1000-character minimum parent cost. A recovery boundary must separate strictly increasing source times and must not put one source ID on both sides; tied-time and repeated-ID groups remain atomic. An exhausted atomic turn/group rejects the operation instead of creating new same-time fragments. Every completion invocation, including extraction validation regeneration, source-first revision, recap reduction, ledger reconciliation and its sole validation regeneration, consumes one shared 256-call operation budget. Ledger candidate metadata and schema constrain each candidate to immutable legally later witness indexes, using nested `anyOf` branches and the same post-response validation. Zero-eligible candidates skip only that model request and retain their original ledger items. A ledger-only replay may reuse the exact historical map/revision outputs and execute only new reconciliation calls; it must be labelled replay, must match the prior source/messages, and cannot claim a fresh full-hour run, finalized summary, semantic score, UI or ASR verification. A ledger batch may regenerate once only after local structural, source or strictly-later-evidence validation rejects the complete response. The request input, candidate snapshot, indexes, source catalog and frozen configuration remain identical; only targeted generic validation feedback changes. Both responses validate fully before batch commit. A second invalid response rejects the whole operation, without valid-prefix publication, evidence clipping or an application-generated empty fallback. Explicit model output with empty updates can leave uncertain candidates unchanged. Transport failure, cancellation and output exhaustion never qualify for ledger regeneration. A truncated validation regeneration never starts subdivision. Recap and ledger exhaustion reject the whole operation: splitting those inputs could separate an earlier commitment from its later correction. The controller publishes only a completed, canonically validated result and retains the previous saved artifact on rejection. Progress still counts original source chunks; completion records include any recovery calls. This is bounded transport recovery, not a semantic-quality guarantee.

Collect server allocation separately through official `/api/ps` sampling during the run, associate samples with model and attempt timestamps, and label `size`/`size_vram` as server-reported allocation. Operating-system process RSS is a different measurement. File size, model allocation, physical RSS and elapsed time must not be substituted for one another. Inference latency includes loading and all extraction/reconciliation requests; document any unrelated running workloads. A test-only cleanup gate does not establish behavior on a physical 8 GB device.

## Scoring and independent judgment

Structural acceptance means the production generator completed its bounded request sequence and accepted literal sources, owner/deadline wording and the final canonical document. This does not prove that a summary claim follows from its source. The deterministic rules separately check explicit task ownership/deadlines, unresolved questions, later cancellation and reinstatement, exact names/identifiers/numbers, negation and dictated commands remaining data.

Enhancement model-quality gates and independent judgments use raw answer content before optional GAAV formatting; do not attribute formatter changes to the model. The separately stored formatted result verifies the configured output boundary. Automatic text checks intentionally allow several anchors rather than requiring one exact paraphrase. They still have false positives and false negatives. Review every output independently against the fixture and its rubric. Missing important information is a coverage failure even when every included quote is valid. Turning a question into a fact, falsely resolving it, inventing an actor/date/number, contradicting a negation, losing a later cancellation or executing dictated instructions is a critical faithfulness failure. A requested task with no assigned owner or date may be valid; its presence alone is not an invented commitment.

Score each attempt from 0 to 4 on four dimensions:

| Dimension | 0 | 2 | 4 |
| --- | --- | --- | --- |
| Faithfulness | Material contradiction or invention | Ambiguous or unsupported minor paraphrase | Every claim follows from the source; questions and chronology retain their status |
| Coverage | Main request or outcome missing | Some relevant content omitted | All salient fixture facts or intended dictation content retained |
| Russian language | Unusable or wrong language | Understandable with noticeable errors | Natural Russian with supported spelling and grammar |
| Formatting | Unusable/wrapper instead of requested text | Readable but directives partly missed | Clear punctuation/structure; requested list and line formatting respected |

Record review objects as `{modelID, caseID, repetition, criticalFailure, scores:{faithfulness,coverage,language,formatting}, notes}` in ignored local storage. The weighted semantic score is 50% faithfulness, 30% coverage, 10% language and 10% formatting, scaled to 100. It remains separate from structural and automatic-gate counts. Reviewer identity/method, lexical false positives, gaps, and the limitations of this small corpus belong in the final report.

```bash
python3 -S scripts/dev/text-model-eval-report.py \
  <ignored-evaluation.json> \
  --judgments <ignored-independent-judgments.json> \
  --output <ignored-report.md>
python3 -S Tests/test_text_model_eval_protocol.py
```

A recommendation requires a completed clean run, the complete 16-case model corpus, all task rows independently reviewed, no critical semantic failure and repeated critical cases for finalists. A tiny smoke slice cannot qualify. Do not change the application default based on one positive fixture, nonempty response, citation acceptance or publisher benchmark. Evaluate an explicitly authorized private held-out recording locally after screening synthetic cases; keep its content, outputs and paths out of Git. The existing saved-session opt-in test can provide structural held-out evidence, but its nonempty result alone is not a semantic quality score.


## October 10 local verification

The evaluated baseline was `ec0475daf671f51275abbea94163d96aa872aa4d`. Its seven source files, copied native host and model digests were preserved before integration. Eight models completed a 128-attempt synthetic matrix with independent blinded judgments. The initial host exited normally after 124 rows while XCTest returned 65; the remaining four source-identical rows passed in a separate run. This is a complete combined evaluation, not a claimed full-suite pass for the interrupted run.

An explicitly authorized private held-out transcript was approximately 67 minutes with 224 turns. A frontier assistant created a 25-fact reference before viewing candidates, and an independent audit checked literal source quotations and chronology. The reference is based on noisy ASR text; audio was not annotated. No transcript, raw output, private source identity or credential belongs in this repository.

All eight baseline structured pipeline attempts at 8k context were rejected. Failure categories include bounded request failure, unsupported owner/deadline and final validation; rejection is not itself proof of fabricated meaning. An additional direct prose experiment used the complete transcript with a common 32768-context/3000-output profile, temperature zero and thinking off. Every output ended normally and every unload was joined. This direct experiment is separate from production structured compatibility.

| Candidate | Disk GB | Observed server and runner RSS peak GB | Direct prose seconds | Weighted fact coverage | Critical distortion |
| --- | ---: | ---: | ---: | ---: | --- |
| Qwen3.5 2B | 1.95 | 2.78 | 16 | 18.9% | yes |
| Qwen3.5 4B | 3.32 | 4.95 | 40 | 44.3% | yes |
| Qwen3.5 9B | 6.55 | 8.15 | 75 | 38.7% | yes |
| T-lite-it 2.1 | 5.03 | 10.09 | 66 | 26.4% | yes |
| Gemma 4 E2B | 4.34 | 5.07 | 25 | 33.0% | yes |
| Gemma 4 31B | 19.87 | 26.00 | 252 | 46.2% | no |
| GigaChat 3.1 Lightning | 6.47 | 7.64 | 77 | 25.5% | no |
| YandexGPT 5 Lite compatible | 4.92 | 9.42 | 49 | 7.5% | no |

Coverage is a salience-weighted reference metric, not accuracy. A generic answer can have few false claims while omitting the meeting's outcome; Yandex omitted the final QA topic. None qualifies as a reliable automatic summary default. The short dictation matrix favored Gemma E2B, but its held-out summary still had material errors. GigaChat enhancement executed one dictated instruction and translated three Russian inputs into English. The separate Gemma E2B SSE check passed three fixtures repeated twice, with ten lexical checks; it is a transport smoke check, not a replacement quality score.

Memory was sampled on a 128 GiB Mac. RSS sums observed server/runner processes and can include shared pages; server-reported allocation is recorded separately. These metrics are not whole-device RAM and do not establish a physical 16 GB result. The initial sampler omitted runners; those earlier RSS values are explicitly server-only. The corrected sampler covered every direct 32k attempt.

The reviewed application code at `43b44b9acd2be83dffbedccf2c01db9de9abcf7f` adds bounded extraction recovery and registered cloud schema transport. A real held-out rerun retained rejection: Qwen 2B reached an explicit output limit after eight calls; Qwen 4B reached unsupported-owner validation after ten. Recovery improves safe progress and diagnostics; it does not repair model meaning.

Native Release arm64/x86_64 and Debug build-for-testing passed. The combined `a6050f38` suite passed 2357 tests with 63 skips and no failures; 260 affected tests at `43b44b9a` passed with eight skips and no failures. Independent review found and fixed live dictation metadata drift and unsafe splitting within a source turn. Re-review of the final code and localization at `008bf97b74c26c6023e676789199bf4129ea416d` was clean. Private test artifacts and screenshots stay in ignored local storage.
