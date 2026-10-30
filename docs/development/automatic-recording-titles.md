# Automatic titles for long recordings

`MeetingUniversalTitleEngine` implements the frozen `universal-strict-safety-v1`
classifier. It selects one of 99 universal candidates from the current transcript
using communicative-form evidence and distributed keyword matches. It does not
load a model, use earlier meetings, or add people, companies, locations or subject
names. Native diarization labels do not prove an exact participant count.

`MeetingAutomaticNaming` admits completed, automatically named recordings with an
end time, at least 30 minutes of duration and at least 1,500 readable characters.
Short recordings are not classified, and custom titles remain unchanged. A
completed partial transcript can be named from its available reading; coverage
and completeness metadata remain unchanged. Insufficient semantic evidence uses
the neutral audio-recording name in the transcript language. Additional work is
bounded by 4 MiB of text and 50,000 segments.

The adapter uses the existing transcript reading and speaker presentation. A new
processing result awaits an owned utility task before publication; cancellation
joins that task and the coordinator rechecks its existing admission. History
migration runs inside the existing store actor. It preserves profile ownership,
encryption and summary compatibility, and never opens audio or uploads data.

The optional schema-1 `automaticTitle` artifact retains the algorithm version,
candidate ID, String Catalog key, dominant transcript language, previous title and
previous default-title base.
Its backup uses the same manifest and encryption policy as the recording.
Generated titles keep the dominant language of the current transcript when the
interface language changes. Apple's local language recognizer examines at most
16 distributed samples of 1,024 Unicode scalars; no transcript is uploaded. The
catalog currently supplies Russian and English titles, with the existing English
source fallback for unsupported catalog languages. User speech and custom titles
are never translated. Automatic names omit the start date and time; history and
recording detail show the start in their separate visible metadata.
The current recording's saved localized place appears in a separate optional pin
row on the live screen, in history and in recording detail. A place never replaces
the semantic title or supplies naming evidence. Missing or concealed location
data produces no place row; rendering does not request permission or geocode.
Manual rename clears the generated artifact and default-title marker. Existing
generated titles are stable across reloads; unknown algorithm versions retain
their persisted title snapshot.

Before a bulk installation or migration, retain private exact-byte manifest
backups and hashes outside Git. The artifact's previous fields support a narrowly
scoped rollback through the existing authorized save operation. Do not replace a
current recording or a whole device container with an old backup.

Verification uses synthetic fixtures in the engine and store probes, actual
coordinator rename/failure tests, and the opt-in `MobileUniversalTitleUITests`.
The mobile UI probe requires externally staged Russian and English synthetic long
sessions and explicit `PICHI_TITLE_FIXTURE_ID`, `PICHI_TITLE_ENGLISH_FIXTURE_ID`
and `PICHI_TEST_REVISION` values. It checks exact bare titles, frozen title language
and separately visible start metadata in both interface languages and appearances.
Private evaluation corpora, original recordings, weights and device backups must
remain outside Git.
