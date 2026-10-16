# Resuming retained meeting processing

Resuming after app termination or a device restart is available only when the meeting was
created with Save audio enabled (`audioStorageMode == .retainedFiles`). The setting is frozen
in the meeting. Changing today's setting does not opt an older strict meeting into disk storage.
Memory-only processing never reads or creates inference working-state files.

After reopening the app, the existing recovery screen offers Retry transcription. This
continues the frozen backend, model artifacts, language, privacy rules and speaker configuration.
It does not schedule background execution. iPadOS may suspend processing while the app is away.

The canonical backend records each completed 20-second ASR core. fast32 records its exact
frontend tails, speaker cache, FIFO, frame/sample cursors and open/closed speaker intervals after
each five seconds of source audio. The final pre-padding snapshot permits repeating only the
uncommitted tail. Completed tracks retain native intervals; evidence is rebuilt with the new
attempt's IDs and current validated span references, without replacing strings in old evidence.
ASR cores are cached only when the provider supplies a verified nonempty artifact fingerprint.
Adapters with an unspecified artifact identity may resume pinned diarization, but repeat ASR
instead of mixing completed text with unknown same-name weights.

Each recovery re-observes actual source bytes with the existing bounded SHA-256 observer and
binds all decoded facts, admission rules and time mappings. Attempt-derived manifest IDs are
normalized through their typed constructors for this physical-input digest only. Runtime,
artifact, owner-profile generation or policy drift rejects restoration. A shortened track after
a transient materialization failure cannot replace a complete-track snapshot.

Working ASR text and model state are an encrypted private cache, not the redacted transcript.
AES-GCM authenticates both the payload and frozen metadata. The ciphertext and separate local
key use private session storage, permissions 0600, backup exclusion and iOS file protection.
This avoids plaintext working text on disk; the same-folder key does not protect against someone
who can read the whole app sandbox. Retained audio itself also remains sensitive. The existing
A1 publication gate still runs before transcript persistence, display, search and export.

Fully completed session persistence removes the cache and key. Incomplete results can reuse
completed cores on retry. Deleting the audio or meeting removes all working state. The explicit
Start processing again action removes only inference checkpoints, including legacy progress,
then uses the existing retry operation; it preserves retained audio and the meeting. A corrupt
or incompatible checkpoint never silently changes models or publishes partial raw text.

Checks: `bash Tests/run_meeting_session_store_checkpoint_tests.sh` exercises the actual private
store, encryption/authentication, fresh-store recovery, strict gating, corruption, cancellation
and audio cleanup. `scripts/dev/test-fast32-runtime.sh` takes an existing pinned FluidAudio
checkout and verifies exact frontend/cache/output continuation without model downloads.
Native backend/recovery tests cover new-attempt ASR continuation, model drift, partial-track
materialization, explicit restart and joining cancelled processing. Actual model continuation,
both mobile builds and simulator UI verification remain separate runtime acceptance checks.
