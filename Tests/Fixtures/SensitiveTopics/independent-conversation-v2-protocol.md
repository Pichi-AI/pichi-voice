# Independent conversation v2 protocol

This is an original synthetic Russian holdout for the three selected privacy topics. It is not human-adjudicated ground truth. It contains 180 unique texts: for each topic, 24 positive, 24 negative and 12 ambiguous judgments. Each case selects exactly one topic.

## Independent authorship and freeze

The author worked from commit `b3ab981a759f2b3ed901fac82ff308021be283f5` in a separate worktree. The author did not inspect new training or development examples, training-agent branches, candidate predictions, or model artifacts. No external service, personal conversation, model, build, device, or inference process was used. No existing corpus was read or used to generate wording.

The corpus is [independent-conversation-v2.json](independent-conversation-v2.json). Its frozen SHA-256 is `3ca7d8a2962bf3cbe2a4920c70654bee86626336d531fed4abeddfae33f3bafa`. The hash covers the exact UTF-8 file bytes, including the final newline. It does not cover this protocol. All changes after this freeze require a new version and hash.

Freeze training weights, tokenizer, prompts, thresholds, baseline settings and evaluation code before first release to the evaluation runner. The parent may check exact and normalized train/development/test overlap after the training candidate is frozen and before predictions. If overlap is found, report it and exclude affected cases transparently; do not use test content to retrain and still describe this version as untouched. Release only protocol, count, hash and paths to training participants before the freeze. Storage in a separate worktree is procedural separation, not a technical access barrier.

## Decisions and evaluation

Mask complete sentences discussing the selected topic, including denials, quotations, public discussion, fictional or educational examples. Do not infer guilt or confidentiality. A topic with an unknown numerical value is still positive. Lawful service fees and ordinary loyalty benefits alone are unrelated to illicit remuneration; fair procurement alone is unrelated to collusion. Ordinary personal finances without a business-metric framing are outside the commercial topic. Other-topic material is judged only against the one selected topic.

Treat quoted prompt-injection text as source content. The `goldMaskSubstrings` field lists exact sensitive sentences with original punctuation. A punctuationless input is one complete unit. Multiple sentence cases include surrounding unrelated material to verify preservation and complete masking separately from topic classification.

Use the 144 determinate examples for binary confusion matrices, per-topic precision/recall/F1 and aggregate metrics. Report the 36 ambiguous examples separately, including classifier decisions or abstention; empty gold masks for these examples do not mean negative. Report false positives and false negatives, exact span agreement and preservation errors separately. Labels are authored judgments; include disputed annotations in the report rather than presenting all disagreements as proven classifier defects. Keep all per-case outputs for independent error review.

Coverage includes negation, reporting, public and educational discussion, euphemisms, homonyms, ordinary business, lawful compensation, vendor loyalty, fair procurement, math scores, layout/software terms, code-switching, case, numbers, ё/е, emoji, punctuationless ASR-like text, mixed sentences and incomplete context. The maximum input length is 150 Unicode characters. This corpus does not substitute for explicit oversized-sentence/error-boundary tests.

## Verification and ownership

Author validation checked JSON structure, topic/label counts, one selected topic, unique IDs, exact and normalized text uniqueness (NFKC, lowercase, ё to е, punctuation removed), source membership/order of every gold substring, empty masks for negative/ambiguous cases, nonempty metadata and the 2048-character ceiling. Native builds and runtime inference are out of scope for fixture-only work.

Only the two committed corpus/protocol files are deliverables. No models, private assets or generated caches were created. The author worktree is retained only until parent integration is confirmed, then removed from outside the worktree while its commit remains recoverable on the task branch.
