# Automatic titles for long recordings

`MeetingUniversalTitleEngine` implements the frozen `universal-strict-safety-v1`
classifier. It selects one of 99 universal candidates from the current transcript
using communicative-form evidence and distributed keyword matches. It does not
load a model, use earlier meetings, or add people, companies, locations or subject
names. Native diarization labels do not prove an exact participant count.

`MeetingAutomaticNaming` admits completed, automatically named recordings with an
end time, at least 30 minutes of duration and at least 1,500 readable characters.
Short recordings and manually named records keep their existing titles. A
completed partial transcript can be named from its available reading; coverage
and completeness metadata remain unchanged. Insufficient evidence retains the
existing title. Additional work is bounded by 4 MiB of text and 50,000 segments.

The adapter uses the existing transcript reading and speaker presentation. A new
processing result awaits an owned utility task before publication; cancellation
joins that task and the coordinator rechecks its existing admission. History
migration runs inside the existing store actor. It preserves profile ownership,
encryption and summary compatibility, and never opens audio or uploads data.

The optional schema-1 `automaticTitle` artifact retains the algorithm version,
candidate ID, String Catalog key, previous title and previous default-title base.
Its backup uses the same manifest and encryption policy as the recording.
Generated interface copy follows the selected interface language. User speech
and custom titles are never translated. Existing date presentation is preserved.
Manual rename clears the generated artifact and default-title marker. Existing
generated titles are stable across reloads; unknown algorithm versions retain
their persisted title snapshot.

Before a bulk installation or migration, retain private exact-byte manifest
backups and hashes outside Git. The artifact's previous fields support a narrowly
scoped rollback through the existing authorized save operation. Do not replace a
current recording or a whole device container with an old backup.

Verification uses synthetic fixtures in the engine and store probes, actual
coordinator rename/failure tests, and the opt-in `MobileUniversalTitleUITests`.
The mobile UI probe requires an externally staged synthetic long session and
explicit `PICHI_TITLE_FIXTURE_ID` and `PICHI_TEST_REVISION` values. It uses the
ordinary history and transcript UI in both interface languages and appearances.
Private evaluation corpora, original recordings, weights and device backups must
remain outside Git.
