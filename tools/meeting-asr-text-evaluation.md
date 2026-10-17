# Weak meeting text evaluation

`meeting_asr_text_eval.py` compares actual native ASR words with cached automatic
Fathom utterances. It solves a specific scoring limitation: reference utterances
crossing audio crop edges cannot be compared with partial hypothesis text without
inventing reference word times. It does not change app inference or speaker policy.

Run `python3 -m unittest discover -s tools -p test_meeting_asr_text_eval.py` for
synthetic scoring checks. The portable repository check includes these tests.

Supply a frozen corpus manifest, its native `evidence` directory and an ignored
output path. Development is the default split. Reading held-out references requires
an explicit `--allow-held-out` flag, used only after candidate freeze authorization.
Each reference hash and native audio identity must match the frozen manifest.

## Eligibility and normalization

- Exclude every reference turn marked clipped at either crop edge.
- Exclude whole turns extending inside a clip-edge guard. The primary guard is one
  second; zero and two seconds are fixed sensitivity profiles, not tuned choices.
- Concatenate consecutive eligible turns into runs before alignment. Whole-second
  utterance starts and inferred ends are not word boundaries. Do not remove words
  near every internal reference transition or trim reference sentences.
- Select actual native word units by midpoint in each complete run, in temporal
  order. Invalid geometry and non-word units are excluded and counted. Report
  boundary-crossing selected words separately. Reject overlapping reference runs.
- Normalize NFKC, case, and Russian `ё` to `е`. Keep Unicode letters, decimal digits
  and combining marks within tokens. Other characters split tokens. Do not
  transliterate, spell out numbers, or infer equivalent spoken numeric values.
- WER uses normalized tokens; CER uses their concatenation without spaces. Both
  are exact Levenshtein distances divided by the reference length. Empty reference
  denominators yield null. WER can exceed 100 percent. Operation ties prefer
  substitution, deletion, then insertion; aggregate distance does not depend on
  that choice.

The report includes micro and macro WER, CER, substitutions/deletions/insertions,
reference and hypothesis lengths, scored time, included and excluded unit counts,
reference turn exclusions, source hashes, and groups by language/speaker count.
Scoring all word text together is deliberately independent of speaker assignment.

## Interpretation

These are **weak-reference text disagreement scores**, not verified ASR accuracy,
gold WER/CER, or diarization error. Fathom may omit interruptions, mistranscribe,
translate, repeat, or omit long sections. Its coarse inferred turn ends can include
silence. Complete-run scoring avoids known crop text contamination, but cannot
repair these source defects. CTC word timestamps are approximate emission spans,
not forced alignment. The three guard profiles test crop-edge sensitivity only.

Manual reference transcription from the exact audio, with an agreed policy for
simultaneous speech, numerals and hesitations, is required before claiming actual
accuracy. Do not tune the diarization algorithm against this ASR text score.

Protected physical app output also includes privacy redactions and may have a
different window/context schedule. Do not reuse raw-native scores as physical
transcription quality. A separate product-output comparison must disclose those
redactions, eligible reference coverage and any missing word timestamps.
