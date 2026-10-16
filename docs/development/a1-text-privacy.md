# A1 local transcript privacy adapter

The shared transcript privacy model store now selects `PIIModelDescriptor.russianA1`.
Settings and meeting preparation continue to use the same installation, readiness,
cancellation and retirement operations on macOS and iOS. Existing tiny-news
artifacts are retained under their separate model ID; native tests can still load
that descriptor explicitly. An A1 preparation failure propagates rather than
silently using a different model or regex-only processing.

## Frozen assets and inference

The [author's release](https://huggingface.co/Powpowpow23/ru-pii-ner-a1/tree/67a6270bf24661bf62ea0e93582d02edcc8ee517)
is pinned to `67a6270bf24661bf62ea0e93582d02edcc8ee517`.
The descriptor records SHA-256 and byte lengths for the INT8 ONNX graph,
`tokenizer.json`, `model.json` and `inference_config.json`. Downloads use the
existing bounded, staged model store. No Python code is downloaded or executed;
weights remain outside Git. The author's Apache-2.0 license and inherited
Red Mad Robot notice are included in the existing notices resources. The author
also discloses an unresolved NEREL training-data provenance question; the notice
preserves that disclosure.

The existing serialized native ONNX runtime supports an independent BIO format
alongside its original token BIO format. A1 requires `[1, tokens, 25, 3]`
`ner_logits`; the unused gate is not consumed. Each head uses O/B/I argmax with
first-class tie resolution; orphan I starts a span. The adapter retains cross-head
overlaps and merges strictly overlapping same-policy spans across windows.
A score of 1 records a discrete admitted decision, not calibrated confidence.

The BERT adapter reads the verified vocabulary, preserves exact UTF-16 token
boundaries, and uses 256-token windows with a 64-token overlap. It keeps every
WordPiece, including words that cross windows. It compares vocabulary UTF-8
bytes explicitly: Swift's canonical string equality would otherwise treat
decomposed and precomposed Cyrillic characters as equivalent, unlike the author's
tokenizer. Input remains bounded to the existing 65,536 UTF-16 units, with one
native inference window resident at a time. Synchronous ONNX runs are joined;
cancellation is observed before/after each window and releases its temporaries.

Inference head names are translated once in the adapter into existing privacy
policy labels: names to `PER`, date of birth to `DOB`, card number to `CARD`,
CVV/PIN to `SECRET`, and driver license to `NUMBER`. Other author heads are
preserved so the existing policy can admit explicit supported types and avoid
blindly masking generic cities, regions, countries or dates.

## Verification scope

`PIIIndependentBIOTests` covers UTF-16 offsets including emoji and Ё, decomposed
characters, literal special tokens, complete >512-token coverage, exact overlap,
independent heads, orphan I, invalid logits, canonical labels and merging. The
opt-in `PICHI_PII_A1_TEST_MODEL_DIRECTORY` test verifies actual pinned native
inference, cancellation and unload. It expects the descriptor's flattened local
artifact layout, including `model_int8.onnx`.

A bounded local synthetic comparison against the author's tokenizer found and
corrected the Swift canonical-equivalence issue. The locally installed Python
`tokenizers` 0.23.1 produced incomplete overflow windows for long inputs:
300 one-token words produced window lengths 256 and 68 instead of 256 and 112.
Native windows follow the documented all-token 256/64 contract and are checked
against the author's tokenizer without truncation, followed by explicit slicing.
That Python overflow behavior is not copied into the application.

Native ONNX 1.24.2 and Python ONNX 1.31.0 are not bit-identical. On one synthetic
passport/address fixture with identical input IDs and the same verified graph,
the maximum absolute logit difference was 0.17994. One near-tied HOUSE decision
changed: Python O/B logits 5.01859/5.01576 versus native 5.04321/5.08002. The full
ADDRESS prediction agreed. Across 18 synthetic inputs, token IDs and UTF-16
offsets agreed in all cases after explicit full-token slicing. Span results
agreed in 16; the other difference was a long repeated-name stress input.
This is runtime numerical drift, not a tokenizer or
span-decoder correction; historical Python quality scores cannot establish the
new native application's quality. The integrated rules and native runtime need
a fresh synthetic evaluation and physical-iPad memory/meeting tests.
