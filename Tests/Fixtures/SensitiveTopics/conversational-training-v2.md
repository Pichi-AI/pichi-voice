# Conversational classifier continuation data

This is original synthetic development material for the three existing topic IDs. It is not a transcription, an independent test set, or copied article/book text. The native classifier format and feature space are unchanged.

`conversational-train-development-v2.jsonl` has 499 rows:

- 300 new training rows in 100 scenario families. Each family contains two topic paraphrases and one close benign contrast.
- 19 explicitly reviewed positive examples from the current published conversational catalog, training only. Boundary explanations and ambiguous terminology discussions are excluded.
- 90 original v1 training rows for rehearsal. Original v1 development/exploratory rows and previous evaluation fixtures are not training inputs.
- 90 new development rows in 30 separate families, ten families per topic.

Each row declares `familyID`, `split`, `topics`, `text` and provenance. Family IDs cannot cross splits; normalized text duplicates are rejected. This metadata is a split control, not a claim that authored development paraphrases form an independent semantic benchmark. The separate evaluation author and new test data are outside this training workflow.

The topic policy is topic mention rather than a determination of wrongdoing. Denials, quotations, fiction and educational discussion can still mention a selected topic. Ordinary disclosed fees, gratitude, documents, real loans, technical rollbacks, game rounds, property shares and other unrelated meanings supply counterexamples. Business revenue/cost/pricing/runway is distinct from personal pay or personal budgeting without business-cost framing.

## Real continuation

The baseline artifact has SHA-256 `394bad4607a11a55417148f1b575247e36161980581c09f9bf48fd6bafe2be9b` and is kept outside Git. `--initial-artifact` copies its learned weights and biases as the optimizer starting point; it does not reset them to zero. `--initial-sha256` is required. Feature identity, format version and dimensions must match the existing 16384-dimensional runtime.

The CLI without continuation options retains exact v1 reproduction. The existing output filename remains compatible with its original caller; the selected external v2 copy is named `conversational-topics-v2.json`. The artifact's codec version remains 1 because the decoder contract did not change.

Exactly three development-only configurations were tried: 40 epochs at learning rate 0.15, 80 at 0.15, and 80 at 0.3. The aggregate development objective is `3 * false negatives + false positives`; their losses were 18, 15 and 12. Per-topic thresholds use development only, resolving equal objective by fewer false positives then a higher threshold. The selected continuation is 80 epochs at 0.3. Its bytes were frozen before any new independent-test access.

Selected artifact: 678073 bytes, SHA-256 `9952052146978b266af5d6c68855fc95161db36636711630113a4ac0f0f7c734`. Input corpus SHA-256: `d4b50b686af5ef512cdd86aabd0f38b86098220920199d818d43ddc53caba462`.

The artifact training digest binds the corpus digest, initial artifact digest, optimizer settings, seed and threshold objective. A separate freeze record retains that protocol and the selection history. Weights are local artifacts and are not committed.

## Reproduce

```sh
python3 tools/sensitive_topic_classifier.py \
  --cases Tests/Fixtures/SensitiveTopics/conversational-train-development-v2.jsonl \
  --initial-artifact /absolute/path/to/frozen-baseline.json \
  --initial-sha256 394bad4607a11a55417148f1b575247e36161980581c09f9bf48fd6bafe2be9b \
  --epochs 80 --learning-rate 0.3 \
  --output-directory .build/topic-training/reproduction
python3 -B -S Tests/test_sensitive_topic_trainer.py
```

Controls passed: six continuation/checksum/schema/split tests; exact v1 and v2 artifact reproductions; 20 actual native loader/boundary checks on the selected v2 artifact; 1437 native/Python score comparisons on single-sentence rows (maximum absolute difference below 1e-8). Multi-sentence examples are processed per sentence by the native runtime and are intentionally excluded from the whole-text Python parity claim.

Development results are not an independent quality score. No model or threshold adjustment is permitted after the independent evaluation has been opened. Final quality, memory, speed and jury evaluation are owned by the parent task and recorded separately.
