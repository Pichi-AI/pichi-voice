# Experimental sensitive-topic classifier

All 154 cases in `synthetic-exploratory-v1.jsonl` are invented for this feature.
They contain no recordings, real business facts, or user dictionaries.
The implementation author saw every case. The exploratory split is consequently
not an independent acceptance set, and its results must not be called production
quality or calibrated privacy coverage.

The 90 training cases fit the weights. The 25 development cases select a fixed
threshold per topic, using a cost of three for a miss and one for extra masking.
The 39 exploratory cases only report results. A separately authored, unseen set
is required for the final comparison. Do not tune on that set after inspection.

Supported stable IDs:

| ID | Selected-topic policy |
| --- | --- |
| `illicit-remuneration` | Mention of unofficial personal benefits tied to a business or official decision, including denial, quotation and compliance discussion. Does not assert wrongdoing. |
| `procurement-collusion` | Mention of coordinated competition, tailored exclusion or imitation of competition, including investigation and denial. Ordinary competitive procurement is negative. |
| `commercial-metrics` | Nonpublic pricing floors, costs, margins, discount reserves or financial forecasts, including discussion of protecting those facts. General formulas and published figures are negative. |

This is a real learned one-vs-rest logistic classifier over hashed word unigrams,
word bigrams and character 3-5 grams. It is deliberately CPU-only and small.
It does not infer an arbitrary new topic from a user-entered word, understand all
euphemisms, or supply token-level semantic redaction. The detector masks the
selected complete sentence. Its trailing unfinished sentence stays private,
including when the ASR inserts a newline. Long unpunctuated input throws rather
than releasing an undecided prefix. Sentence boundaries and classification errors
remain material limitations.

Run `bash Tests/run_sensitive_topic_classifier_tests.sh`. The reproducible trainer
writes learned weights, score reports and the native test binary only below
ignored `.build/sensitive-topics/`. No learned weights belong in Git. The native
snapshot verifies the supplied SHA-256 and schema and freezes selected IDs.
The existing privacy resource/settings owner must own artifact import and retain
the snapshot per attempt. The detector adds no network, model server or alternate
installation lifecycle. It is optional and should remain off by default while
independent quality and iPad resource evaluation are incomplete.
