# Grounded meeting summaries

The public summary runtime extends the existing meeting and text-provider contracts. It uses one frozen transcript, provider configuration and execution profile for extraction, reconciliation, repair and recap reduction. No model-specific coordinator or separate small-model pipeline is required.

## Selected approach

1. Process bounded transcript windows sequentially. Extract atomic recap claims, explicit decisions, requested work, questions, corrections and answers with source indices. The application resolves those indices to immutable literal excerpts; the model does not retype UUIDs or source quotations.
2. Ask the model to check every assertion against its selected sources, including actor, number, time, negation, completion status and uncertainty. Keep questions, proposals and opinions distinguishable from answers, commitments and established facts. Copy action owners and deadlines verbatim when supported, otherwise use null. Prompt examples must not seed actual names or dates.
3. Validate structure, source membership, literal quotations and owner/deadline support. Use at most one targeted regeneration for a validation issue. Transport failure, cancellation and unsupported output are not accepted summaries. Citation existence is not semantic entailment: this validation cannot prove that every paraphrase is faithful.
4. Reconcile earlier ledgers against later explicit cancellation, replacement and answers. Preserve earlier entries and their source history. Reduce recap repetition separately, without replacing the action and decision ledgers with repeatedly compressed prose.
5. Retain the previous saved summary when regeneration fails or is cancelled. Keep processing alive across screen navigation, and reattach the active meeting and cancellation control when the user returns.

This follows the locate-then-summarize direction of [QMSum](https://arxiv.org/abs/2104.05938), the error-specific feedback approach in [What's Wrong? Refining Meeting Summaries with LLM Feedback](https://aclanthology.org/2025.coling-main.143/) and staged meeting-summary composition studied by [Dialpad](https://arxiv.org/abs/2310.19233). These papers motivate implementation choices; they do not certify this application's models or Russian summary quality. The existing canonical document, validation and meeting resource ownership remain the extension boundaries.

## Thinking and resource ownership

The ordinary profile permits 8192 context tokens, 3000 generated tokens, 180 seconds per request and 600 seconds per whole attempt. Extended processing permits 16384 context tokens, 8192 generated tokens, 900 seconds per request and 3600 seconds per whole attempt. Thinking uses the selected model's existing shared reasoning settings. Extended time does not automatically enable it, and a boolean thinking control must not be advertised as an unsupported maximum effort level. See [Ollama thinking controls](https://docs.ollama.com/capabilities/thinking).

The generation token limit includes reasoning and the final answer. An exhausted reasoning budget with no complete final object is a rejected attempt. This can occur even on short inputs. Resource settings and cache identity are fixed when an attempt starts; changing preferences during it cannot retarget its requests.

Native Ollama attempts create an owned, unpredictable alias of the admitted model artifact, verify its digest and use that alias for every request. Only the owned alias is deleted. The logical model identifier remains visible in the UI; the artifact digest is included in saved provenance and cache identity. Other API transports keep their existing server contracts rather than pretending to support local artifact pinning.

Cancellation and the total deadline join client work and release before admission and ASR resources are restored. Release failures remain visible after cancellation and prevent publication. There is a server-side limit: an Ollama copy may finish after its HTTP timeout and after a DELETE returned 404. Bounded client cleanup cannot guarantee absence of that late alias. It does not enumerate and delete other installations' models or force a global runner unload.

Offline viewing can show a validated saved summary matched to the transcript and base configuration. It is explicitly labelled historical because the current model artifact could not be checked. A reachable changed digest invalidates that cache.

## Evidence before changing defaults

A private October 10 experiment exercised Qwen3.5 0.8B, 2B, 4B and Gemma 4 E2B on one complete hour-long Russian transcript. Each model received two frozen prompts with thinking both disabled and enabled, for 16 direct prose attempts. The matched off/on pairs used the same artifact, source, family sampling, seed, 65536 context and 32768 generation limit. Every attempt completed and cleanup was joined. All 16 outputs had a critical semantic distortion in independent blinded review.

For Qwen3.5 4B, thinking reduced weighted reference fact coverage from 42.5% to 33.0% with the original prompt, and from 37.7% to 28.3% with the engineered prompt. Time rose from 44 to 109 seconds and from 42 to 130 seconds respectively. This is one sample per cell, not a universal model ranking. Coverage is not accuracy. It does not justify making thinking or a particular model an automatic default.

A separate native structured slice on four synthetic summary cases accepted two of four standard attempts and one of four extended-thinking attempts. The other extended attempts exhausted their output budget. Structural acceptance is separate from independent semantic quality. The direct prose experiment has different prompts and serving parameters; do not merge its success counts with native compatibility results.

Keep the full summaries, independent annotations, request hashes, memory observations and private sources in ignored local evaluation storage. The observed machine had 128 GiB of memory. Server/runner RSS is neither unique physical memory nor proof of operation on an 8 or 16 GB Mac. Only a complete corpus with no critical semantic failures and repeated finalist cases qualifies a default recommendation under the [evaluation protocol](text-model-evals.md).
