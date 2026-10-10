# Russian meetings and summaries

New meeting setups default to Russian. Saved language choices remain unchanged. The upstream Parakeet v3 final meeting backend already accepts Russian; its English-only live backend still has a separate language restriction.

The meeting Summary tab uses a Pichi provider based on the public `LLMClient`, independent of the private Fluid Intelligence runtime. Its default destination is Ollama on `http://127.0.0.1:11434/v1`, with `qwen3.5:4b` selected. Ollama and model weights must be installed separately. Refresh models to discover installed IDs, or enter a model served by LM Studio's compatible local API. `qwen3.5:2b` is an alternative when memory is limited. Actual memory and speed depend on the server's context configuration and require measurement on the target Mac.

Russian is the default summary language. English and the transcript's language are selectable independently of transcription. The optional Configured AI provider mode reuses an OpenAI-compatible provider selected in AI Enhancement settings. Its endpoint and model are displayed before generation. Remote endpoints require HTTPS and existing credentials; there is no automatic cloud fallback. A generation request sends transcript text, not audio. Summary transport and model discovery use an ephemeral session and reject HTTP redirects, so a localhost endpoint cannot redirect the transcript to a remote destination.

Every recap, decision, task and open question includes source segment IDs and exact transcript excerpts. Unknown IDs, invented quotations, and owners or dates absent from cited source speech or speaker labels cause rejection. This validates attribution and citations, not the semantic truth of every generated claim. Review the Sources disclosures before acting on a task or decision.

Long transcripts are processed sequentially in bounded chunks. A separate reduction stage condenses the recap; the decisions and task ledger remains complete. Explicit later cancellations or replacements are extracted and reconciled against the ledger. An earlier entry is retained as superseded, with the later correction's source quotation. Reconciliation cannot rewrite its original text, owner or date, remove it, or use an earlier event to supersede it. Transcript gaps appear as a warning. Provisional turns and probable echoes are excluded. Corrections, speaker changes, language changes, gaps, and summary model changes invalidate saved results.

The saved artifact is `pichi-meeting-summary.json` inside the existing session directory. It stores the transcript fingerprint, configuration identity, generation time and structured result. It contains no API credentials. Generation errors and cancellation do not replace or delete the transcript or audio. Existing upstream postprocessing artifacts remain compatible.

## Verification

`PichiMeetingSummaryTests` covers Russian evidence, invented citations/owners/dates, long turns, chunk reduction, cancellation, endpoint policy and invalidation. The suite is offline by default. For a real local inference check, run `testLiveRussianSummaryWithOllamaWhenEnabled` with `PICHI_MEETING_SUMMARY_LIVE=1` in the test process environment, after installing `qwen3.5:4b`. The fixture is synthetic and contains no personal audio or meeting information.

Only launch the test host after the Pichi bundle, storage and Keychain identity changes are present. Compilation alone does not verify audio capture, local model availability, or performance on Intel.
