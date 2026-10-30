# Business privacy vocabulary and independent evaluation

Catalog revision: `sensitive-business-groups-ru-v1`. Research date: 2026-10-30.

The catalog supplies opt-in suggestions to the existing sensitive-word settings. It owns no persistence, inference engine, or transcription pipeline. Its six groups contain 76 expressions in total. `maximumCatalogTerms = 128` is separate from the existing limit of 128 private user entries; integration must not silently crowd out or truncate private entries. `defaultSelectedGroupIDs` is empty.

`terms` are explicit expressions a user can review before selecting a group. They are data in their source language, not UI strings. `titleKey` and `descriptionKey` are interface localization keys. `contextualExamples` illustrate broader meanings and ambiguous business speech; they must never be silently turned into literal rules. All changes to selected vocabulary must be frozen in the existing attempt snapshot and fingerprint.

## Proposed groups

| Stable ID | Topic | Why a user may select it | Deliberately excluded bare triggers |
| --- | --- | --- | --- |
| `illicit-remuneration` | Bribes and illicit remuneration | Suppress discussion of payments for decisions, including quoted or denied claims | откат, занос, благодарность, комиссия, решить вопрос |
| `procurement-collusion` | Arranged bidding | Suppress discussion of coordinated bids or predetermined winners | тендер, участник, ТЗ, заточка |
| `commercial-metrics` | Commercial metrics and pricing | Suppress margin, acquisition cost, pricing concessions and financial planning vocabulary | runway, пайплайн, воронка, процент, скидка |
| `planned-transactions` | Investments and corporate transactions | Suppress funding rounds, ownership and transaction vocabulary | раунд, доля, оффер, слияние |
| `employee-compensation` | Pay and employment packages | Suppress salary ranges, pay reviews and retention payments | оклад, премия, бонус, грейд, оффер |
| `personal-health` | Health and medical information | Suppress medical discussion separately from named-entity detection | диагноз, анализ, операция, здоровье |

These are topic preferences, not a determination that a statement is illegal or secret. Public lectures, denials, quotations, and ordinary lawful discussion still mention a selected topic. Literal selection can mask a homonym, such as a card-game use of `взятка`; a contextual topic classifier is evaluated separately on preserving such uses. This distinction must stay visible in comparisons.

Modern euphemisms frequently overlap with legitimate work: agency fees, consulting services, personal percentages, gratitude for a signature, technical participants, and arranging a question. The examples in this catalog are original illustrations, not a frequency-ranked corpus of actual private business conversations. A broad blanket blacklist of `комиссия`, `бонус`, `благодарность` or `решить вопрос` would remove normal business speech. Credentials, document numbers, and payment-card identifiers remain the existing PII policy's responsibility; this catalog does not replace it.

## Public primary sources and their limits

- [OECD Guidelines for Fighting Bid Rigging, 2025 update, chapter 1](https://www.oecd.org/en/publications/oecd-guidelines-for-fighting-bid-rigging-in-public-procurement-2025-update_cbe05a56-en/full-report/component-3.html), published 2025-09-11. The primary guideline distinguishes cover bidding, suppression, rotation, and market allocation. This supports the topic taxonomy. Russian phrases and all fixtures here are original paraphrases, not quotations or claims about a particular company.
- [US DOJ, consulting-fee kickback case](https://www.justice.gov/usao-ma/pr/cfo-boston-area-spinal-device-company-sentenced-four-months-prison-kickback-scheme), accessed 2026-10-30. The enforcement account describes sham consulting fees, illustrating why the label of a payment alone cannot distinguish a real service from illicit remuneration. It does not justify classifying every consulting fee as a bribe.
- [Russian prosecutor's office, commercial bribery case](https://epp.genproc.gov.ru/ru/proc_54/mass-media/news/archive/e4433664/), published 2022-11-18. This is an attestation of the Russian `откат` sense in procurement, not evidence that every use of the word has that sense and not a current slang-frequency study.
- [Mindbox, unit economics](https://mindbox.ru/journal/education/unit-ekonomika/), accessed 2026-10-30. The vendor's own discussion uses CAC, LTV, margin and unit economics in business analysis. These ordinary metrics can be selected as private vocabulary without implying wrongdoing.
- [Bitrix24, sales plan](https://helpdesk.bitrix24.ru/open/12027656/), accessed 2026-10-30. Product documentation places sales funnels in CRM analytics. This supports a contextual business sense while the catalog preserves unrelated physical funnels and software pipelines.
- [Skolkovo, investment round announcement](https://sk.ru/news/kama-flow-investiruet-do-1-mlrd-rublej-v-cifrovuyu-transformaciyu-gornodobyvayushego-sektora-s-pomoshyu-rezidenta-skolkovo-piklema/), published 2025-07-10. A public first-party announcement uses the investment-round vocabulary. Topic masking is a user choice even when a deal is publicly announced.

The health and employee-pay groups are product proposals with original vocabulary; no clinical or legal conclusion is derived from them. No personal correspondence was searched or imported.

## Frozen independent holdout

`Tests/Fixtures/SensitiveBusinessPrivacy/heldout-ru-v1.json` contains 120 original synthetic cases. Each group has 10 positive and 10 negative cases. The training agent was told only group identifiers and policy, not these texts or labels. Its weights and thresholds must be frozen before evaluation. Any later tuning on this corpus makes it a development set and requires a new unseen holdout.

Each case declares `enabledGroupIDs`, `expectedTopicMatch`, and `goldMaskSubstrings`. Positive gold masks cover the selected-topic sentence; six mixed-sentence cases preserve an unrelated sentence. Negative cases contain ordinary homonyms or non-topic speech. The 37 edge tags include inflection, rare forms, negation, quotation, training, mixed-language speech, missing ASR punctuation, paraphrases without catalog terms, identifiers containing term substrings, and metaphors.

Gold labels were independently authored but have not been human-adjudicated. Blinded LLM judges should be allowed to flag ambiguous labels, separately from judging candidate outputs. Report supported-topic results separately from unsupported groups. Compare literal and morphological token masking with a lexical oracle, and semantic sentence masking with this topic oracle; scoring every method against only the topic oracle would conflate intended scope with defects. ASR-like text here is synthetic and is not acoustic validation.

Validation performed for this data-only change: Swift catalog type-check; JSON decode; unique case IDs and texts; 10/10 class balance in all six groups; all gold substrings resolve in source text; source/fixture contain no em or en dashes. Native UI and full app integration are owned by the parent task.
