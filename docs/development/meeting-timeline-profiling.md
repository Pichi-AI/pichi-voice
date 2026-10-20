# Private streaming timeline investigation

`PICHI_MEETING_TIMELINE_PROFILE=1` is an explicit local profiling launch option. It creates
`Library/Caches/MeetingTimelineTrace/<run UUID>.private.jsonl` in the app container. Normal
launches create no trace. This cache is excluded from backup, uses private permissions, and
is separate from ordinary support logs, transcript export, share and meeting storage.

The file **contains unredacted model hypotheses**. Keep it in ignored private test artifacts.
Never attach it to a support report, upload it or distribute it with the application. No PCM
is written. Relaunch without the option after the bounded test; the opt-in lasts for the
launched process and does not change user settings. The first meeting's terminal processing
or failed start closes raw admission permanently for that process, so a later user meeting
cannot append hypotheses. Final IO is joined for up to two seconds; a timed-out writer
remains owned by the bounded sink and reports incomplete flushing instead of delaying the app.

Schema 1 uses caller-captured `systemUptime` seconds. Audio ranges use normalized 16 kHz
source samples or meeting-relative seconds. Each run includes its source revision. Events
cover normalized capture arrival, capture-owned VAD model load and 256 ms frame results,
unknown reasons and queue resets, non-speech coverage queries, every returned ASR hypothesis
before prefix admission, the retained final prefix, continuous diarizer input and scored
watermarks, privacy work, protected admission/publication, speaker revisions and waveform
interval replacement. Returned hypotheses are revisions, not internal decoder beam options.
The current decoder API does not expose those options. A `sealed` hypothesis indicates a
sealed physical input window; the separate finalization event identifies any retained shorter
accepted prefix. Timed words from ASR are local to their source window. Protected words and
speaker activity are meeting-relative.

Existing runtime phase spans supply wall time, process CPU deltas and physical-footprint
snapshots. CPU and memory belong to the **whole process**, including overlapping capture,
VAD, UI and tracing. They cannot establish per-model memory or exclusive CPU consumption.
Do not sum overlapping process CPU deltas or call their boundary footprint the model size.
VAD probability is the existing model's OR aggregate over eight internal 32 ms outputs, not
voiced duration. Unknown evidence stays unknown and cannot suppress recognition.

The collector admits at most 30,000 events, 16 MiB of file data, 512 queued events and about
1 MiB of queued payload. Strings and word arrays have individual bounds. The `trace_status`
record reports drops, truncation and file limits. A metadata-only stderr failure marker
reports write failure. Missing trace intervals or absent hypotheses must be reported as
missing, never interpreted as silence or proof that a model did no work. Native device frame
capture remains a separate requirement. This tracing changes no model policy or pipeline
scheduling. `Tests/run_meeting_timeline_trace_tests.sh` exercises the disabled path, private
format/permissions, event and byte caps, queue overflow and truncation accounting.
