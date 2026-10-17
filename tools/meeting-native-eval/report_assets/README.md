# Private offline evaluation report

`report.py` is a viewer and artifact packager. It never computes or overrides speaker decisions. It consumes the runner's schema-1 report index, validates source SHA-256 hashes, replays' evidence binding and a single policy fingerprint, then embeds private JSON safely into an offline HTML page.

```sh
python3 tools/meeting-native-eval/report.py \
  --index /absolute/private/final-report-index.private.json \
  --candidate standardV2 \
  --status final \
  --output /absolute/worktree/private_assets/final-meeting-report \
  --physical /absolute/private/ipad-report-summary.private.json \
  --notes /absolute/private/final-observations.ru.txt \
  --text-quality /absolute/private/final-weak-text.private.json
node tools/meeting-native-eval/test_report.js
```

`--status final` requires at least 20 actual cases from distinct recordings. Use `provisional` for partial development runs. By default the generator copies each verified WAV into the output's `audio/` directory. `--reference-audio-in-place` retains absolute file references instead. HTML, copied media and report proof are private and must remain ignored. No web hosting is needed. Browser rendering is not claimed by successful static generation.

Required index fields: `cases`, `aggregate`, `corpus_manifest_path`, `corpus_manifest_sha256`. Optional source proof fields: `status`, `native_source_commit`, `core_source_sha256`, `host_measurement_summary`, `by_weak_speaker_count`, `by_language`.

Each case includes `clip_id`, `meeting_id`, `split`, `language_condition`, `weak_speaker_count`, `duration_seconds`, `source_start_seconds`, `source_end_seconds`, `audio_path`, `audio_sha256`, `native_evidence_path`, `native_evidence_sha256`, `weak_reference_path`, `weak_reference_sha256`, `frozen_native_to_weak_reference_mapping`, `core_replay_paths` (variant name to actual replay path), and `case_metrics.variants` with profile counts under `strictWeak`, `interior1s`, `interior2s`. `native_anonymous_activity_slots` is optional. A future runner adapter should retain this contract or supply a new explicit adapter, rather than silently substitute missing metrics.

Physical summary contract: `{status, summary, runs: [...]}`. Suggested run fields are `id`, `fixture`, `tested_revision`, `audio_seconds`, `post_stop_seconds`, `total_seconds`, `peak_footprint_mib`, `baseline_footprint_mib`, `thermal_state`, `quality_note`. All supplied fields are visible in the expandable raw JSON, including conditions, missing samples, failures and measurement caveats. Missing fields display as missing. No physical file means pending, never inferred from Mac RSS. Prepare this summary from actual result attachments, with explicit units, tested revision and audio hashes, and exclude personal information.

The viewer shows one shared audio/seek marker, actual WAV waveform peaks, automatic Fathom utterances, anonymous fast32 activity, historical word attribution and the selected candidate. Reading groups retain all exact source word envelopes; no Fathom word times are manufactured. Word details retain original ASR assignment, acoustic projection, historical decision, final rule, candidates, background support and cues. Approximate reference names are qualified and never written into native tokens.

Security: transcript strings enter the DOM through `textContent`. Embedded JSON escapes markup delimiters and Unicode separators. Inline code/style are SHA-256 pinned in the CSP. Network fetch, forms, base URLs, external images and external scripts are blocked. No CDNs, telemetry or remote model calls. Existing browser access restrictions still apply; this generator is not an alternative browser access mechanism.

The optional `--text-quality` file is the separately computed guarded WER/CER schema-1 artifact. Its corpus, per-clip native evidence and reference hashes must match the report. It has an independent 0/1/2-second clip-edge guard selector, distinct from speaker-boundary collars. Undefined scores remain undefined; scores above 100 percent are not clamped. Without this file the report explicitly says text scores are not provided.

Final report source verification is mandatory. Each case supplies `core_replay_provenance[variant]` with `result_sha256`, `build_manifest_path`, `build_manifest_sha256`, `build_source_revision`, `core_source_sha256`, `native_runner_binary_path`, `native_runner_binary_sha256`, `run_manifest_path`, `run_manifest_sha256`, and `execution_mode`. The actual build manifest's source revision and canonical core source digest must match the frozen report index, its binary digest must match the retained executable, and its bytes must match the manifest SHA embedded in native inference evidence. Cases also supply `native_evidence_build_manifest_path` and `native_evidence_build_manifest_sha256`.

The complete pass run manifest must bind the same frozen corpus and parsed build manifest, with exactly one matching case result/evidence path and digest, meeting, split and policy fingerprint. Final cases require a positive actual native-inference duration for the confirmation pass. A provisional case without this provenance is explicitly unverified; index source claims are shown as unverified claims and never emitted as verified revision proof. Provided inconsistent provenance fails in either status. The proof establishes consistency of retained build/run records, not hardware attestation.

Presentation groups of unresolved words include the full scoped candidate set and evidence relation. Equivalent candidate order can merge; a changed source, track, epoch, generation or simultaneous/consecutive relation cannot silently inherit the preceding label. All source words remain separate in the details.
