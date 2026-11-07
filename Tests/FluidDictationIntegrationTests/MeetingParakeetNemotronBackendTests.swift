import AVFoundation
import CoreMedia
import Darwin
@testable import FluidVoice_Debug
import Foundation
import XCTest

/// Milestone E of `MEETING_TRANSCRIPTION_IMPLEMENTATION_PLAN.md`: the composite
/// Parakeet TDT v2 + Nemotron-3 backend. The runtime is faked (no CoreML here); the
/// materializer and pipeline integration tests use real WAV files on disk.
@MainActor
final class MeetingParakeetNemotronBackendTests: XCTestCase {
    func testEmissionSourceContextIsExplicitBoundedAndLegacyCompatible() throws {
        let unscoped = ASRWordTimingProvenance(basis: .tokenEmission)
        XCTAssertTrue(unscoped.isValid)
        XCTAssertFalse(unscoped.hasValidSourceContext)
        let valid = try XCTUnwrap(unscoped.scoped(to: "synthetic-window", wordIndex: 0))
        XCTAssertTrue(valid.hasValidSourceContext)
        for malformed in [
            ASRWordTimingProvenance(basis: .tokenEmission, sourceWindowID: "window"),
            .init(basis: .tokenEmission, sourceWordIndex: 0),
            .init(basis: .tokenEmission, sourceWindowID: "", sourceWordIndex: 0),
            .init(basis: .tokenEmission, sourceWindowID: " \n", sourceWordIndex: 0),
            .init(basis: .tokenEmission, sourceWindowID: String(repeating: "x", count: 513), sourceWordIndex: 0),
            .init(basis: .tokenEmission, sourceWindowID: "window", sourceWordIndex: -1),
            .init(basis: .tokenEmission, sourceWindowID: "window", sourceWordIndex: 8_192),
        ] {
            XCTAssertFalse(malformed.isValid)
            XCTAssertFalse(malformed.hasValidSourceContext)
            XCTAssertNil(malformed.scoped(to: "replacement", wordIndex: 0))
        }
        let epoch = MeetingAnalysisEpochID(trackID: UUID(), ordinal: 20 * 16_000)
        let unit = MeetingFinalTextUnit(id: "native-word", trackID: epoch.trackID, analysisEpochID: epoch,
            precision: .word, text: "A", analysisStart: 0.08, analysisEnd: 0.12,
            speaker: .unassigned, analysisSpanIDs: [], wordTimingProvenance: valid)
        let copy = unit.assigningSpeaker(.assigned(.init(analysisEpochID: epoch, label: "voice")))
        XCTAssertEqual(copy.wordTimingProvenance, valid)
        XCTAssertEqual(copy.analysisStart, unit.analysisStart)
        XCTAssertEqual(copy.analysisEnd, unit.analysisEnd)
        let data = try JSONEncoder().encode(unit)
        XCTAssertEqual(try JSONDecoder().decode(MeetingFinalTextUnit.self, from: data), unit)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "wordTimingProvenance")
        let legacy = try JSONDecoder().decode(MeetingFinalTextUnit.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.wordTimingProvenance)
    }

    func testPCMTimingProvenanceRetainsOriginalIndexThroughSortingAndStoredReattribution() throws {
        let (first, _) = self.attributionTokens()
        let epoch = first.analysisEpochID
        let marker = ASRWordTimingProvenance(basis: .tokenEmission)
        let words = [ASRWordTiming(text: "later", start: 1.44, end: 1.8, timingProvenance: marker),
                     ASRWordTiming(text: "early", start: 0.08, end: 0.12, timingProvenance: marker)]
        let units = try MeetingParakeetNemotronBackend.pcmUnits(result: .init(text: "later early"),
            words: words, epoch: epoch, duration: 2, activity: [], identityTokens: [])
        XCTAssertEqual(units.map(\.text), ["early", "later"])
        XCTAssertEqual(units.map { $0.wordTimingProvenance?.sourceWordIndex }, [1, 0])
        XCTAssertEqual(Set(units.compactMap { $0.wordTimingProvenance?.sourceWindowID }).count, 1)
        XCTAssertTrue(units.allSatisfy { $0.wordTimingProvenance?.hasValidSourceContext == true })
        let attempt = UUID()
        let batch = try MeetingTranscriptAssembler().assemblePCMWindow(attemptID: attempt, epoch: epoch,
            offset: 0, duration: 2, units: units)
        XCTAssertEqual(batch.segments.map(\.nativeWordTimingProvenance), units.map(\.wordTimingProvenance))
        let encoded = try JSONEncoder().encode(batch.segments)
        let restored = try JSONDecoder().decode([MeetingTranscriptSegment].self, from: encoded)
        XCTAssertEqual(restored, batch.segments)
        let final = try MeetingPCMRecordingAttribution.assemble(transcript: batch,
            activity: [.init(token: first, start: 0, end: 2)], epoch: epoch,
            attemptID: attempt, duration: 2, speakerNameFormat: "Speaker %d")
        XCTAssertEqual(final.segments.map(\.nativeWordTimingProvenance), batch.segments.map(\.nativeWordTimingProvenance))
        XCTAssertEqual(final.segments.map(\.nativeTiming), batch.segments.map(\.nativeTiming))
        XCTAssertEqual(final.segments.map(\.id), batch.segments.map(\.id))
        var session = self.makeSession(mode: .inRoom, tracks: [])
        session.transcriptSegments = final.segments
        session.speakers = final.speakers
        let exported = try XCTUnwrap(JSONSerialization.jsonObject(
            with: MeetingTranscriptExporter.json(for: session)) as? [String: Any])
        let rows = try XCTUnwrap(exported["segments"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 2)
        let exportedProvenance = try rows.map { row -> ASRWordTimingProvenance in
            let object = try XCTUnwrap(row["nativeWordTimingProvenance"] as? [String: Any])
            return try JSONDecoder().decode(ASRWordTimingProvenance.self,
                from: JSONSerialization.data(withJSONObject: object))
        }
        XCTAssertEqual(exportedProvenance, final.segments.compactMap(\.nativeWordTimingProvenance))
        var legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        for index in legacyObject.indices { legacyObject[index].removeValue(forKey: "nativeWordTimingProvenance") }
        let legacy = try JSONDecoder().decode([MeetingTranscriptSegment].self,
            from: JSONSerialization.data(withJSONObject: legacyObject))
        XCTAssertTrue(legacy.allSatisfy { $0.nativeWordTimingProvenance == nil })
    }

    func testOfflineFilteringAndCoreRebaseDoNotPromoteLaterEmissionToSourceWordZero() async throws {
        let marker = ASRWordTimingProvenance(basis: .tokenEmission)
        let result = try await self.replayResult(seconds: 40, responses: [
            .init(text: "invalid first", words: [
                .init(text: "invalid", start: -1, end: 0.04, timingProvenance: marker),
                .init(text: "first", start: 0.08, end: 0.12, timingProvenance: marker)]),
            .init(text: "context second", words: [
                .init(text: "context", start: 0.08, end: 0.12, timingProvenance: marker),
                .init(text: "second", start: 2.08, end: 2.12, timingProvenance: marker)]),
        ])
        let units = result.bundle.evidence.units
        XCTAssertEqual(units.map(\.text), ["first", "second"])
        XCTAssertEqual(units.map { $0.wordTimingProvenance?.sourceWordIndex }, [1, 1])
        XCTAssertEqual(Set(units.compactMap { $0.wordTimingProvenance?.sourceWindowID }).count, 2)
        XCTAssertEqual(units[0].analysisStart, 0.08, accuracy: 1e-6)
        XCTAssertEqual(units[1].analysisStart, 20.08, accuracy: 1e-6)
        XCTAssertTrue(units.allSatisfy { $0.wordTimingProvenance?.hasValidSourceContext == true })
    }

    func testRetainedNewAttemptRestoresCompletedASRCoresAndContinuousSpeakerEvidence() async throws {
        for fingerprint: String? in ["synthetic-sha256", nil] {
        let chunk = self.makePCMChunk(sequence: 0, start: 100, end: 145)
        let track = self.makeMicTrack(chunks: [chunk], eraStart: 100)
        var session = self.makeSession(mode: .inRoom, tracks: [track])
        let directory = try self.makeTempSessionDirectory()
        let pinnedASR = MeetingFinalProcessingConfiguration(asrArtifactFingerprint: fingerprint, languageCode: "en")
        let first = FakeRuntime(), materializer = FakeMaterializer()
        let backend = self.makeBackend(runtime: first, materializer: materializer)
        let request = self.makeRequest(session: session, directory: directory, configuration: pinnedASR)
        let observations: [MeetingAnalysisChunkKey: MeetingChunkObservationResult] = [
            .init(trackID: track.id, chunkID: chunk.id): self.makeObserved(chunk, duration: 45)
        ]
        let plan = try backend.plan(request)
        let manifest = try self.makeManifest(plan: plan, observations: observations)
        let epoch = try XCTUnwrap(manifest.track(track.id)?.epochs.first)
        materializer.replaySampleCounts[epoch.id] = 45 * 16_000
        first.diarizerFactory.segmentsByEpoch[epoch.id] = [.init(slotIndex: 2, start: 0, end: 45)]
        first.asrSession.responses = [.init(text: "first", words: [.init(text: "first", start: 0.5, end: 1,
            timingProvenance: .init(basis: .tokenEmission))])]
        first.asrSession.cancellationCallIndices = [1]
        do {
            _ = try await backend.execute(plan: plan, manifest: manifest, progress: { _ in })
            XCTFail("Expected interrupted second core")
        } catch is CancellationError {}
        XCTAssertEqual(first.asrSession.callSampleCounts.count, 2)
        let oldAttempt = request.attemptID
        session.processingAttempts = [] // A new process/retry has a fresh attempt identity.
        let resumedRuntime = FakeRuntime()
        resumedRuntime.asrSession.responses = [
            .init(text: "second", words: [.init(text: "second", start: 2.5, end: 3)]),
            .init(text: "third", words: [.init(text: "third", start: 2.5, end: 3)]),
        ]
        if fingerprint == nil {
            resumedRuntime.asrSession.responses.insert(.init(text: "first", words: [.init(text: "first", start: 0.5, end: 1,
                timingProvenance: .init(basis: .tokenEmission))]), at: 0)
        }
        let resumedBackend = self.makeBackend(runtime: resumedRuntime, materializer: materializer)
        let resumedRequest = self.makeRequest(session: session, directory: directory, configuration: pinnedASR)
        let resumedPlan = try resumedBackend.plan(resumedRequest)
        let resumedManifest = try self.makeManifest(plan: resumedPlan, observations: observations)
        let result = try await resumedBackend.execute(plan: resumedPlan, manifest: resumedManifest, progress: { _ in })
        guard case let .canonicalEvidence(bundle) = result else { return XCTFail("Expected canonical result") }
        XCTAssertNotEqual(bundle.evidence.attemptID, oldAttempt)
        XCTAssertEqual(bundle.evidence.attemptID, resumedRequest.attemptID)
        XCTAssertEqual(bundle.evidence.units.map(\.text), ["first", "second", "third"])
        XCTAssertEqual(bundle.evidence.units.map(\.analysisStart), [0.5, 20.5, 40.5])
        let restoredProvenance = try XCTUnwrap(bundle.evidence.units.first?.wordTimingProvenance)
        XCTAssertTrue(restoredProvenance.hasValidSourceContext)
        XCTAssertEqual(restoredProvenance.basis, .tokenEmission)
        XCTAssertEqual(restoredProvenance.sourceWordIndex, 0)
        XCTAssertEqual(restoredProvenance.sourceWindowID, "asr:\(epoch.id):0:352000")
        XCTAssertEqual(Set(bundle.evidence.units.map(\.id)).count, 3, "Completed cores cannot be duplicated")
        XCTAssertEqual(resumedRuntime.asrSession.callSampleCounts, (fingerprint == nil ? [22, 24, 7] : [24, 7]).map { $0 * 16_000 },
                       "Only a verified artifact identity authorizes reuse of completed ASR cores")
        XCTAssertTrue(resumedRuntime.diarizerFactory.createdEpochs.isEmpty, "Completed diarization is restored, never repeated")
        XCTAssertEqual(bundle.evidence.speakerActivity.map(\.token.label), ["slot-2"])
        }
    }

    func testRetainedCheckpointRejectsASRModelDriftBeforeInference() async throws {
        let chunk = self.makePCMChunk(sequence: 0, start: 100, end: 145)
        let track = self.makeMicTrack(chunks: [chunk], eraStart: 100)
        let session = self.makeSession(mode: .inRoom, tracks: [track])
        let directory = try self.makeTempSessionDirectory()
        let runtime = FakeRuntime(), materializer = FakeMaterializer()
        let backend = self.makeBackend(runtime: runtime, materializer: materializer)
        let plan = try backend.plan(self.makeRequest(session: session, directory: directory,
            configuration: .init(asrArtifactFingerprint: "original-model-sha256", languageCode: "en")))
        let observations: [MeetingAnalysisChunkKey: MeetingChunkObservationResult] = [
            .init(trackID: track.id, chunkID: chunk.id): self.makeObserved(chunk, duration: 45)
        ]
        let manifest = try self.makeManifest(plan: plan, observations: observations)
        let epoch = try XCTUnwrap(manifest.track(track.id)?.epochs.first)
        materializer.replaySampleCounts[epoch.id] = 45 * 16_000
        runtime.asrSession.cancellationCallIndices = [0]
        do { _ = try await backend.execute(plan: plan, manifest: manifest, progress: { _ in }); XCTFail("Expected interruption") }
        catch is CancellationError {}
        let replacement = FakeRuntime()
        let changed = self.makeBackend(runtime: replacement, materializer: materializer)
        let changedPlan = try changed.plan(self.makeRequest(session: session, directory: directory,
            configuration: .init(asrArtifactFingerprint: "replacement-model-sha256", languageCode: "en")))
        do {
            _ = try await changed.execute(plan: changedPlan,
                manifest: self.makeManifest(plan: changedPlan, observations: observations), progress: { _ in })
            XCTFail("Model drift must not mix completed state")
        } catch is MeetingRetainedProcessingCheckpoint.Failure {}
        XCTAssertEqual(replacement.diarizationScopeCount, 0)
        XCTAssertTrue(replacement.asrAttemptIDs.isEmpty)
    }

    func testStrictModeNeverCreatesRetainedWorkingState() async throws {
        let chunk = self.makePCMChunk(sequence: 0, start: 100, end: 105)
        let track = self.makeMicTrack(chunks: [chunk], eraStart: 100)
        var session = self.makeSession(mode: .inRoom, tracks: [track]); session.audioStorageMode = .memoryOnly
        let directory = try self.makeTempSessionDirectory()
        let runtime = FakeRuntime(), materializer = FakeMaterializer()
        let backend = self.makeBackend(runtime: runtime, materializer: materializer)
        let plan = try backend.plan(self.makeRequest(session: session, directory: directory))
        let manifest = try self.makeManifest(plan: plan, observations: [
            .init(trackID: track.id, chunkID: chunk.id): self.makeObserved(chunk, duration: 5)
        ])
        let epoch = try XCTUnwrap(manifest.track(track.id)?.epochs.first)
        materializer.replaySampleCounts[epoch.id] = 5 * 16_000
        _ = try await backend.execute(plan: plan, manifest: manifest, progress: { _ in })
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(names.contains(MeetingRetainedProcessingCheckpoint.fileName))
        XCTAssertFalse(names.contains(MeetingRetainedProcessingCheckpoint.keyFileName))
    }

    func testEightHourTrackUsesBoundedReplayAndASRWindows() async throws {
        let seconds = 8.0 * 60 * 60
        let chunk = self.makePCMChunk(sequence: 0, start: 100, end: 100 + seconds)
        let track = self.makeMicTrack(chunks: [chunk], eraStart: 100)
        let runtime = FakeRuntime()
        let materializer = FakeMaterializer()
        let backend = self.makeBackend(runtime: runtime, materializer: materializer)
        let plan = try backend.plan(self.makeRequest(session: self.makeSession(mode: .inRoom, tracks: [track]),
                                                     directory: self.makeTempSessionDirectory()))
        let manifest = try self.makeManifest(plan: plan, observations: [
            .init(trackID: track.id, chunkID: chunk.id): self.makeObserved(chunk, duration: seconds)
        ])
        let epoch = try XCTUnwrap(manifest.track(track.id)?.epochs.first)
        materializer.replaySampleCounts[epoch.id] = Int(seconds * 16_000)
        runtime.diarizerFactory.segmentsByEpoch[epoch.id] = [.init(slotIndex: 0, start: 0, end: seconds)]
        runtime.asrSession.responses = (0..<1440).map { index in
            .init(text: "word\(index)", words: [.init(text: "word\(index)", start: 2.5, end: 3)])
        }
        let outcome = try await backend.execute(plan: plan, manifest: manifest, progress: { _ in })
        guard case let .canonicalEvidence(bundle) = outcome else { return XCTFail("Expected canonical result") }
        XCTAssertEqual(runtime.diarizerFactory.createdEpochs, [epoch.id])
        XCTAssertEqual(runtime.diarizerFactory.diarizedSampleCounts, [Int(seconds * 16_000)])
        XCTAssertEqual(runtime.asrSession.callSampleCounts.count, 1440)
        XCTAssertLessThanOrEqual(runtime.asrSession.callSampleCounts.max() ?? Int.max, 24 * 16_000)
        XCTAssertLessThanOrEqual(materializer.maximumReplayRead, 24 * 16_000)
        XCTAssertTrue(materializer.materializedEpochs.isEmpty, "No whole-epoch PCM allocation is allowed")
        XCTAssertEqual(bundle.evidence.units.count, 1440)
        XCTAssertEqual(bundle.coverageReceipts.map(\.status), [.processed])
        XCTAssertGreaterThan(bundle.evidence.units.last?.analysisStart ?? 0, seconds - 30)
    }

    func testOverlappingASRContextKeepsOneBoundaryWordWithNativeTimes() async throws {
        let chunk = self.makePCMChunk(sequence: 0, start: 100, end: 145)
        let track = self.makeMicTrack(chunks: [chunk], eraStart: 100)
        let runtime = FakeRuntime()
        let materializer = FakeMaterializer()
        let backend = self.makeBackend(runtime: runtime, materializer: materializer)
        let plan = try backend.plan(self.makeRequest(session: self.makeSession(mode: .inRoom, tracks: [track]),
                                                     directory: self.makeTempSessionDirectory()))
        let manifest = try self.makeManifest(plan: plan, observations: [
            .init(trackID: track.id, chunkID: chunk.id): self.makeObserved(chunk, duration: 45)
        ])
        let epoch = try XCTUnwrap(manifest.track(track.id)?.epochs.first)
        materializer.replaySampleCounts[epoch.id] = 45 * 16_000
        runtime.diarizerFactory.segmentsByEpoch[epoch.id] = [.init(slotIndex: 0, start: 0, end: 45)]
        runtime.asrSession.responses = [
            .init(text: "left boundary", words: [.init(text: "left", start: 19.3, end: 19.8), .init(text: "boundary", start: 19.9, end: 20.5)]),
            .init(text: "boundary right", words: [.init(text: "boundary", start: 1.9, end: 2.5), .init(text: "right", start: 2.6, end: 3)]),
        ]
        let outcome = try await backend.execute(plan: plan, manifest: manifest, progress: { _ in })
        guard case let .canonicalEvidence(bundle) = outcome else { return XCTFail("Expected canonical result") }
        XCTAssertEqual(bundle.evidence.units.map(\.text), ["left", "boundary", "right"])
        let boundary = try XCTUnwrap(bundle.evidence.units.first { $0.text == "boundary" })
        XCTAssertEqual(boundary.analysisStart, 19.9, accuracy: 1e-6)
        XCTAssertEqual(boundary.analysisEnd, 20.5, accuracy: 1e-6)
    }

    private func replayResult(seconds: Double, responses: [FakeASRSession.Response],
                              speakers: [MeetingNemotronSpeakerSegment] = []) async throws
        -> (bundle: MeetingCanonicalResultBundle, runtime: FakeRuntime) {
        let chunk = self.makePCMChunk(sequence: 0, start: 100, end: 100 + seconds)
        let track = self.makeMicTrack(chunks: [chunk], eraStart: 100)
        let runtime = FakeRuntime()
        let materializer = FakeMaterializer()
        let backend = self.makeBackend(runtime: runtime, materializer: materializer)
        let plan = try backend.plan(self.makeRequest(session: self.makeSession(mode: .inRoom, tracks: [track]),
                                                     directory: self.makeTempSessionDirectory()))
        let manifest = try self.makeManifest(plan: plan, observations: [
            .init(trackID: track.id, chunkID: chunk.id): self.makeObserved(chunk, duration: seconds)
        ])
        let epoch = try XCTUnwrap(manifest.track(track.id)?.epochs.first)
        materializer.replaySampleCounts[epoch.id] = Int(seconds * 16_000)
        runtime.diarizerFactory.segmentsByEpoch[epoch.id] = speakers
        runtime.asrSession.responses = responses
        let outcome = try await backend.execute(plan: plan, manifest: manifest, progress: { _ in })
        guard case let .canonicalEvidence(bundle) = outcome else { throw MeetingParakeetNemotronRuntimeError.invalidPCMWindow }
        return (bundle, runtime)
    }

    func testInvalidWordMetadataRetainsCoreTextWithoutInventingTiming() async throws {
        for invalid in [ASRWordTiming(text: "bad", start: -1, end: 1),
                        ASRWordTiming(text: "bad", start: 100, end: 101),
                        ASRWordTiming(text: "bad", start: .nan, end: 1)] {
            let result = try await self.replayResult(seconds: 45, responses: [
                .init(text: "recovered phrase", words: [invalid]),
                .init(text: "recovered phrase", words: [invalid]),
                .init(text: "later", words: [.init(text: "later", start: 3, end: 4)]),
            ])
            XCTAssertEqual(Array(result.runtime.asrSession.callSampleCounts.prefix(3)), [22, 20, 24].map { $0 * 16_000 })
            let units = result.bundle.evidence.units
            XCTAssertEqual(units.map(\.text), ["recovered phrase", "later"])
            XCTAssertEqual(units.map(\.precision), [.utterance, .word])
            XCTAssertEqual(units[0].analysisStart, 0, accuracy: 1e-6)
            XCTAssertEqual(units[0].analysisEnd, 20, accuracy: 1e-6)
            XCTAssertEqual(units[1].analysisStart, 21, accuracy: 1e-6)
        }
    }

    func testMixedTimedAndCoarseCoresKeepEachNativeBoundaryAndSpeaker() async throws {
        let result = try await self.replayResult(seconds: 60, responses: [
            .init(text: "first", words: [.init(text: "first", start: 1, end: 2)]),
            .init(text: "coarse phrase", words: []),
            .init(text: "coarse phrase", words: [], segmentTimings: [.init(text: "coarse phrase", start: 2, end: 3)]),
            .init(text: "last", words: [.init(text: "last", start: 3, end: 4)]),
        ], speakers: [
            .init(slotIndex: 0, start: 0, end: 20), .init(slotIndex: 1, start: 20, end: 40),
            .init(slotIndex: 2, start: 40, end: 60),
        ])
        let units = result.bundle.evidence.units
        XCTAssertEqual(units.map(\.text), ["first", "coarse phrase", "last"])
        XCTAssertEqual(units.map(\.precision), [.word, .utterance, .word])
        XCTAssertEqual(units.map(\.analysisStart), [1, 22, 41])
        XCTAssertEqual(units.map(\.analysisEnd), [2, 23, 42])
        XCTAssertEqual(Set(units.map(\.id)).count, 3)
        let labels = units.compactMap { unit -> String? in
            guard case let .assigned(token) = unit.speaker else { return nil }
            return token.label
        }
        XCTAssertEqual(labels, ["slot-0", "slot-1", "slot-2"])
    }

    func testSilenceDoesNotDisableLaterOverlappingContextOrDuplicateContextOnlyWords() async throws {
        let result = try await self.replayResult(seconds: 60, responses: [
            .init(text: "", words: []),
            .init(text: "context only", words: [.init(text: "context only", start: 0.2, end: 0.8)]),
            .init(text: "last", words: [.init(text: "last", start: 3, end: 4)]),
        ])
        XCTAssertEqual(result.runtime.asrSession.callSampleCounts, [22, 24, 22].map { $0 * 16_000 })
        XCTAssertEqual(result.bundle.evidence.units.map(\.text), ["last"], "Real context words outside a core must not be copied into it")
        XCTAssertEqual(result.bundle.evidence.units.first?.analysisStart, 41)
    }

    // MARK: - Session fixtures

    private func makeChunk(
        sequence: Int,
        start: Double,
        end: Double,
        path: String = "tracks/microphone/chunk_0.caf",
        sha256: String = String(repeating: "a", count: 64),
        byteCount: Int64 = 1024
    ) -> MeetingAudioChunk {
        MeetingAudioChunk(
            id: UUID(),
            sequence: sequence,
            relativeFilePath: path,
            presentationStart: MeetingMediaTime(value: Int64((start * 1000).rounded()), timescale: 1000),
            presentationEnd: MeetingMediaTime(value: Int64((end * 1000).rounded()), timescale: 1000),
            discontinuities: [],
            sha256: sha256,
            byteCount: byteCount,
            finalizationState: .finalized
        )
    }

    private func makeObserved(
        _ chunk: MeetingAudioChunk,
        duration: Double,
        sampleRate: Double = 16_000
    ) -> MeetingChunkObservationResult {
        .observed(MeetingChunkObservedAudio(
            byteCount: chunk.captureAnalysisAsset?.byteCount ?? chunk.byteCount,
            sha256: chunk.captureAnalysisAsset?.sha256 ?? chunk.sha256,
            decoded: MeetingChunkDecodedFacts(
                sampleRate: sampleRate,
                channelCount: 1,
                frameCount: Int64((duration * sampleRate).rounded()),
                durationSeconds: duration,
                codecPriming: chunk.captureAnalysisAsset == nil
                    ? .measuredFrames(0)
                    : .notApplicable(.linearPCMFloat32CAFV1),
                processingFormatDescription: "fixture"
            )
        ))
    }

    private func makePCMChunk(sequence: Int, start: Double, end: Double) -> MeetingAudioChunk {
        let duration = end - start
        let asset = MeetingAudioAsset(
            role: .captureAnalysis,
            encoding: .linearPCMFloat32CAFV1,
            presence: .ready,
            relativeFilePath: "tracks/microphone/analysis-\(sequence).caf",
            byteCount: Int64((duration * 16_000 * 4).rounded()) + 1,
            sha256: String(repeating: "b", count: 64),
            sampleRate: 16_000,
            channelCount: 1,
            frameCount: Int64((duration * 16_000).rounded())
        )
        return MeetingAudioChunk(
            id: UUID(),
            sequence: sequence,
            relativeFilePath: "tracks/microphone/archive-\(sequence).m4a",
            presentationStart: MeetingMediaTime(value: Int64((start * 1000).rounded()), timescale: 1000),
            presentationEnd: MeetingMediaTime(value: Int64((end * 1000).rounded()), timescale: 1000),
            discontinuities: [],
            sha256: String(repeating: "a", count: 64),
            byteCount: 1,
            finalizationState: .finalized,
            audioSchemaVersion: 2,
            captureAnalysisAsset: asset
        )
    }

    private struct FixtureObserver: MeetingChunkAudioObserving {
        let results: [MeetingAnalysisChunkKey: MeetingChunkObservationResult]

        func observe(
            chunk: MeetingAudioChunk,
            trackID: MeetingAudioTrackID
        ) -> MeetingChunkObservationResult {
            self.results[MeetingAnalysisChunkKey(trackID: trackID, chunkID: chunk.id)]
                ?? .failed(.unreadable, detail: "no fixture observation")
        }
    }

    private func makeMicTrack(chunks: [MeetingAudioChunk], eraStart: Double) -> MeetingAudioTrack {
        MeetingAudioTrack(
            id: UUID(),
            kind: .microphone,
            sourceIdentifier: "microphone",
            sourceDisplayName: "microphone",
            format: nil,
            timebase: MeetingTimebaseMetadata(
                startedHostTime: 7,
                machTimebaseNumerator: 1,
                machTimebaseDenominator: 1,
                firstPresentationTime: nil
            ),
            health: .waiting,
            chunks: chunks,
            captureMethod: .voiceProcessing,
            captureEras: [MeetingCaptureEra(
                method: .voiceProcessing,
                deviceUID: "mic-a",
                deviceName: "mic-a",
                roleAtElection: .unknown,
                echoProtection: .voiceProcessed,
                startSeconds: eraStart
            )]
        )
    }

    private func makeAppTrack(chunks: [MeetingAudioChunk]) -> MeetingAudioTrack {
        MeetingAudioTrack(
            id: UUID(),
            kind: .applicationAudio,
            sourceIdentifier: "application",
            sourceDisplayName: "application",
            format: nil,
            timebase: MeetingTimebaseMetadata(
                startedHostTime: 7,
                machTimebaseNumerator: 1,
                machTimebaseDenominator: 1,
                firstPresentationTime: nil
            ),
            health: .waiting,
            chunks: chunks,
            captureMethod: .screenCaptureKit
        )
    }

    private func makeSession(
        mode: MeetingCaptureMode,
        tracks: [MeetingAudioTrack],
        languageCode: String = "en"
    ) -> MeetingSession {
        var session = MeetingSession(
            configuration: MeetingCaptureConfiguration(
                mode: mode,
                title: "Composite fixture",
                languageCode: languageCode,
                application: mode == .onlineCall
                    ? MeetingApplicationIdentity(bundleIdentifier: "fixture.app", displayName: "Fixture")
                    : nil,
                microphone: MeetingMicrophoneIdentity(captureDeviceID: "mic-a", displayName: "Mic")
            ),
            timebase: MeetingTimebaseMetadata(
                startedHostTime: 7,
                machTimebaseNumerator: 1,
                machTimebaseDenominator: 1,
                firstPresentationTime: nil
            )
        )
        session.audioTracks = tracks
        session.processingAttempts = [MeetingProcessingAttempt(
            id: UUID(),
            startedAt: Date(timeIntervalSinceNow: -30),
            completedAt: nil,
            stage: .pending,
            pipelineVersion: MeetingProcessingPipeline.pipelineVersion,
            asrProvider: nil,
            asrModel: nil,
            diarizationModel: nil,
            lastCompletedTrackID: nil,
            errorCode: nil
        )]
        return session
    }

    private func makeRequest(
        session: MeetingSession,
        directory: URL,
        configuration: MeetingFinalProcessingConfiguration = MeetingFinalProcessingConfiguration(languageCode: "en")
    ) -> MeetingBackendRequest {
        MeetingBackendRequest(
            attemptID: session.processingAttempts.last?.id ?? UUID(),
            session: session,
            sessionDirectory: directory,
            configuration: configuration
        )
    }

    private func makeBackend(
        runtime: FakeRuntime,
        materializer: FakeMaterializer = FakeMaterializer(),
        locator: any MeetingNemotronModelLocating = StubModelLocator()
    ) -> MeetingParakeetNemotronBackend {
        MeetingParakeetNemotronBackend(
            runtimeFactory: { _ in runtime },
            modelLocator: locator,
            materializer: materializer
        )
    }

    private func makeTempSessionDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("composite-backend-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        self.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeManifest(
        plan: MeetingBackendPlan,
        observations: [MeetingAnalysisChunkKey: MeetingChunkObservationResult]
    ) throws -> MeetingAnalysisManifest {
        try MeetingAnalysisManifestBuilder(
            plan: plan,
            observer: FixtureObserver(results: observations),
            analysisSampleRate: 16_000
        ).build()
    }

    /// Two mic chunks separated by a presentation gap (two epochs) plus one app chunk (one epoch).
    private struct TwoEpochFixture {
        let session: MeetingSession
        let micTrack: MeetingAudioTrack
        let appTrack: MeetingAudioTrack
        let chunks: [MeetingAudioChunk]
        let observations: [MeetingAnalysisChunkKey: MeetingChunkObservationResult]
    }

    private func makeTwoEpochFixture(mode: MeetingCaptureMode = .onlineCall) -> TwoEpochFixture {
        let micChunk0 = self.makeChunk(sequence: 0, start: 100, end: 102, path: "tracks/microphone/chunk_0.caf")
        let micChunk1 = self.makeChunk(sequence: 1, start: 105, end: 107, path: "tracks/microphone/chunk_1.caf")
        let appChunk = self.makeChunk(sequence: 0, start: 100, end: 102, path: "tracks/application/chunk_0.caf")
        let micTrack = self.makeMicTrack(chunks: [micChunk0, micChunk1], eraStart: 100)
        let appTrack = self.makeAppTrack(chunks: [appChunk])
        let session = self.makeSession(mode: mode, tracks: [micTrack, appTrack])
        var observations: [MeetingAnalysisChunkKey: MeetingChunkObservationResult] = [:]
        observations[MeetingAnalysisChunkKey(trackID: micTrack.id, chunkID: micChunk0.id)] = self.makeObserved(micChunk0, duration: 2)
        observations[MeetingAnalysisChunkKey(trackID: micTrack.id, chunkID: micChunk1.id)] = self.makeObserved(micChunk1, duration: 2)
        observations[MeetingAnalysisChunkKey(trackID: appTrack.id, chunkID: appChunk.id)] = self.makeObserved(appChunk, duration: 2)
        return TwoEpochFixture(
            session: session,
            micTrack: micTrack,
            appTrack: appTrack,
            chunks: [micChunk0, micChunk1, appChunk],
            observations: observations
        )
    }

    // MARK: - Registry selection

    func testRegistryUsesCompositeDefaultAndKeepsLegacyRegistered() throws {
        let registry = MeetingTranscriptionBackendRegistry.makeDefault()
        XCTAssertEqual(registry.defaultBackendID, .productionDefault)
        XCTAssertTrue(registry.contains(.parakeetNemotron))
        XCTAssertTrue(registry.contains(.legacyCompatibility))

        let runtime = FakeRuntime()
        let context = MeetingBackendHostContext(
            legacyExecutor: { _, _ in throw MeetingBackendError.unknownBackend(.legacyCompatibility) },
            parakeetNemotronRuntimeFactory: { _ in runtime }
        )
        let backend = try registry.makeBackend(id: .parakeetNemotron, context: context)
        XCTAssertEqual(backend.descriptor.id, .parakeetNemotron)
        XCTAssertEqual(backend.descriptor.resultContract, .canonicalEvidence)
        XCTAssertEqual(backend.descriptor.supportedFinalPrecisions, [.word, .utterance])
        XCTAssertEqual(backend.descriptor.supportedTrackKinds, Set(MeetingAudioTrackKind.allCases))
        XCTAssertEqual(backend.descriptor.supportedLanguageCodes, VoiceEngineLanguageCatalog.parakeetV3LanguageIDs)
        XCTAssertEqual(backend.descriptor.execution, .local)
        XCTAssertEqual(backend.descriptor.analysisSampleRate, 16_000)
        XCTAssertTrue(backend.echoVerdictProvider is MeetingTextOverlapEchoVerdictProvider)
        let legacy = try registry.makeBackend(id: .legacyCompatibility, context: context)
        XCTAssertNil(legacy.echoVerdictProvider)

        let selectedDefault = try registry.makeBackend(id: registry.defaultBackendID, context: context)
        XCTAssertEqual(selectedDefault.descriptor.id, .parakeetNemotron)
    }

    private func thirdProviderDescriptor() -> MeetingBackendDescriptor {
        MeetingBackendDescriptor(
            id: MeetingBackendID(rawValue: "fixture.third-provider"),
            version: "test",
            execution: .local,
            supportedLanguageCodes: ["en"],
            supportedTrackKinds: Set(MeetingAudioTrackKind.allCases),
            supportedFinalPrecisions: [.word, .utterance],
            resultContract: .canonicalEvidence,
            knownLimits: [],
            analysisSampleRate: 16_000
        )
    }

    func testThirdProviderBackendUsesInheritedRuntimeCapabilityAndFrozenHostRequest() async throws {
        let fixture = self.makeTwoEpochFixture()
        let directory = try self.makeTempSessionDirectory()
        let descriptor = self.thirdProviderDescriptor()
        let providerModelID = MeetingFinalProcessingConfiguration().asrModel
        let runtime = FakeRuntime()
        runtime.asrSession.responses = ["first", "second", "remote"].map {
            .init(text: $0, words: [.init(text: $0, start: 0.2, end: 0.6)])
        }
        final class Spy { var requests: [MeetingBackendRequest] = [] }
        let spy = Spy()
        let registry = MeetingTranscriptionBackendRegistry(defaultBackendID: descriptor.id)
        registry.register(descriptor.id) { context in
            MeetingProviderBackedBackend(
                descriptor: descriptor,
                providerModelID: providerModelID,
                runtimeFactory: context.parakeetNemotronRuntimeFactory,
                modelLocator: StubModelLocator(),
                materializer: FakeMaterializer()
            )
        }
        let pipeline = MeetingProcessingPipeline(
            asrServiceProvider: {
                XCTFail("The injected shared runtime must own this backend's ASR")
                return ASRService()
            },
            managesModelResidency: false,
            serializationGate: MeetingProcessingSerializationGate(),
            backendRegistry: registry,
            chunkObserver: FixtureObserver(results: fixture.observations),
            meetingRuntimeFactory: { request in
                spy.requests.append(request)
                return runtime
            }
        )

        let result = try await pipeline.process(
            session: fixture.session, sessionDirectory: directory, progress: { _ in }
        )

        XCTAssertEqual(spy.requests.count, 1, "A new registered backend must reuse the one host runtime factory")
        let request = try XCTUnwrap(spy.requests.first)
        XCTAssertEqual(request.attemptID, fixture.session.processingAttempts.last?.id)
        XCTAssertEqual(request.session.id, fixture.session.id)
        XCTAssertEqual(request.sessionDirectory, directory)
        XCTAssertEqual(request.configuration, MeetingFinalProcessingConfiguration(languageCode: "en"))
        XCTAssertEqual(runtime.asrConfigurations, [request.configuration])
        XCTAssertEqual(runtime.asrAttemptIDs, [request.attemptID])
        XCTAssertEqual(result.attempt.backendID, descriptor.id.rawValue)
        XCTAssertEqual(result.attempt.asrModel, providerModelID)
        XCTAssertEqual(Set(result.segments.map(\.text)), ["first", "second", "remote"])
        XCTAssertTrue(result.isComplete)
        XCTAssertNotNil(result.resultSidecarReference)
    }

    func testGenericProviderRejectsUnsupportedLanguageBeforeRuntimeOrMaterialization() throws {
        let fixture = self.makeTwoEpochFixture()
        var session = fixture.session
        session.languageCode = "ru"
        let descriptor = self.thirdProviderDescriptor()
        let runtime = FakeRuntime()
        let materializer = FakeMaterializer()
        var runtimeCreations = 0
        let backend = MeetingProviderBackedBackend(
            descriptor: descriptor,
            providerModelID: MeetingFinalProcessingConfiguration().asrModel,
            runtimeFactory: { _ in runtimeCreations += 1; return runtime },
            modelLocator: StubModelLocator(),
            materializer: materializer
        )
        XCTAssertTrue(backend.echoVerdictProvider is MeetingTextOverlapEchoVerdictProvider)

        XCTAssertThrowsError(try backend.plan(self.makeRequest(
            session: session,
            directory: self.makeTempSessionDirectory(),
            configuration: MeetingFinalProcessingConfiguration(asrModel: MeetingFinalProcessingConfiguration.defaultASRModel, languageCode: "ru")
        ))) { error in
            XCTAssertEqual(error as? MeetingBackendError, .unsupportedLanguage(backend: descriptor.id, languageCode: "ru"))
        }

        XCTAssertEqual(runtimeCreations, 0)
        XCTAssertTrue(runtime.asrConfigurations.isEmpty)
        XCTAssertEqual(runtime.diarizationScopeCount, 0)
        XCTAssertTrue(materializer.materializedEpochs.isEmpty)
    }

    func testDownstreamRegistrationExposesLanguagePolicyWithoutReplacingInheritedProviders() throws {
        let registered = "gigaam-v3-eou"
        let descriptor = try XCTUnwrap(PichiMeetingProviderFactory.registeredBackendDescriptor(for: registered))
        XCTAssertEqual(descriptor.id, .gigaam)
        XCTAssertEqual(descriptor.supportedLanguageCodes, ["ru"])
        XCTAssertEqual(PichiMeetingProviderFactory.registeredLanguageCodes(for: registered), ["ru"])
        XCTAssertEqual(PichiMeetingProviderFactory.defaultLanguageCode(for: registered), "ru")
        // Legacy v2 keeps its original default composite. Mobile v3 is an explicit
        // capability registration backed by that same original provider/runtime.
        for (modelID, language) in [("parakeet-tdt-v2", "en")] {
            XCTAssertNil(PichiMeetingProviderFactory.registeredBackendDescriptor(for: modelID))
            XCTAssertNil(PichiMeetingProviderFactory.registeredLanguageCodes(for: modelID))
            XCTAssertNil(PichiMeetingProviderFactory.defaultLanguageCode(for: modelID))
            let options = try MeetingProviderOptions.resolve(MeetingFinalProcessingConfiguration(
                asrModel: modelID, languageCode: language
            ))
            XCTAssertEqual(options.model.id, modelID)
        }
        XCTAssertEqual(PichiMeetingProviderFactory.registeredBackendDescriptor(for: "parakeet-tdt")?.id, .parakeetV3)
        XCTAssertTrue(PichiMeetingProviderFactory.registeredLanguageCodes(for: "parakeet-tdt")?.isSuperset(of: ["ru", "en", "auto"]) == true)
        XCTAssertEqual(PichiMeetingProviderFactory.defaultLanguageCode(for: "parakeet-tdt"), "auto")
        let unregistered = "fixture.unregistered-provider"
        XCTAssertNil(PichiMeetingProviderFactory.registeredBackendDescriptor(for: unregistered))
        XCTAssertNil(PichiMeetingProviderFactory.registeredLanguageCodes(for: unregistered))
        XCTAssertNil(PichiMeetingProviderFactory.defaultLanguageCode(for: unregistered))
    }

    #if DEBUG
    @MainActor private final class NativeScopeProvider: TranscriptionProvider {
        let name = "Generic native scope fixture"
        let isAvailable = true
        let supportsWordTimings = true
        var isReady = false
        var prepareCalls = 0
        var timedSampleCounts: [Int] = []
        var growingPrefixFixture = false
        var releaseCalls = 0
        func releaseResidency() async { releaseCalls += 1; isReady = false }
        func prepare(progressHandler: ((ModelPreparationProgress) -> Void)?) async throws {
            self.prepareCalls += 1
            self.isReady = true
        }
        func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
            XCTFail("The native meeting session must preserve the provider's timing capability")
            return ASRTranscriptionResult(text: "", confidence: 0)
        }
        func transcribeWithWordTimings(_ samples: [Float]) async throws -> (result: ASRTranscriptionResult, words: [ASRWordTiming]) {
            self.timedSampleCounts.append(samples.count)
            var words: [ASRWordTiming] = [.init(text: "Scoped", start: 0.1, end: 0.4), .init(text: "provider", start: 0.4, end: 0.8)]
            if growingPrefixFixture && samples.count >= 96_000 {
                words.append(.init(text: "grows", start: 0.8, end: 1.1))
            }
            return (ASRTranscriptionResult(text: words.map(\.text).joined(separator: " "), confidence: 1), words)
        }
    }

    @MainActor private final class PCMPreviewObservation {
        var batch: MeetingPCMTranscriptBatch?
        var batches: [MeetingPCMTranscriptBatch] = []
        var checkpoints: [MeetingPCMTranscriptBatch] = []
        var operation: Task<MeetingPCMTranscriptBatch, Error>?
    }

    private func progressiveSample(frames: Int, start: Int64) throws -> CMSampleBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000, channels: 1, interleaved: false))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        pcm.frameLength = AVAudioFrameCount(frames)
        let data = try XCTUnwrap(pcm.floatChannelData?[0])
        for index in 0..<frames { data[index] = 0.1 }
        return try MeetingCapturePCMConverter.sampleBuffer(buffer: pcm,
            presentationTime: CMTime(value: start, timescale: 16_000))
    }

    func testProgressiveNativeScopePublishesGrowingPrefixesAndReusesFinalSealedHypothesis() async throws {
        let fixture = try self.makeNativePCMPreviewFixture()
        addTeardownBlock { await MainActor.run { fixture.service.releaseExclusiveActivity(fixture.lease) } }
        fixture.provider.growingPrefixFixture = true
        let attempt = UUID(); let track = UUID(); let observed = PCMPreviewObservation()
        try await fixture.runtime.preparePCMResources(attemptID: attempt, configuration: fixture.configuration)
        let first = expectation(description: "First growing prefix")
        let second = expectation(description: "Second growing prefix")
        let consumer = try MeetingProcessingPipeline.makeProgressiveMemoryAudioConsumer(
            recognize: { window, _ in
                try await fixture.runtime.recognizePCM(window: window, offset: 8, trackID: track,
                    attemptID: attempt, configuration: fixture.configuration, preview: { batch in
                        await MainActor.run {
                            XCTAssertTrue(fixture.owner.isClaimed, "Growing observations share one live prepared ASR scope")
                            XCTAssertEqual(fixture.provider.releaseCalls, 0)
                            observed.batches.append(batch)
                            if observed.batches.count == 1 { first.fulfill() }
                            if observed.batches.count == 2 { second.fulfill() }
                        }
                    })
            }, checkpoint: { batch in await MainActor.run { observed.checkpoints.append(batch) } },
            failure: { _ in XCTFail("Synthetic progressive inference cannot fail") })
        addTeardownBlock { try? await consumer.finish() }
        XCTAssertTrue(consumer.enqueue(try self.progressiveSample(frames: 48_000, start: 0)))
        await fulfillment(of: [first], timeout: 3)
        XCTAssertTrue(observed.checkpoints.isEmpty, "An unsealed observation cannot enter canonical storage")
        XCTAssertTrue(consumer.enqueue(try self.progressiveSample(frames: 48_000, start: 48_000)))
        await fulfillment(of: [second], timeout: 3)
        try await consumer.finish()
        let final = try XCTUnwrap(observed.checkpoints.first)
        XCTAssertEqual(observed.checkpoints.count, 1)
        XCTAssertEqual(fixture.provider.timedSampleCounts, [48_000, 96_000], "Empty final seal must reuse the latest inference")
        XCTAssertEqual(fixture.provider.prepareCalls, 1)
        XCTAssertEqual(fixture.provider.releaseCalls, 1)
        XCTAssertFalse(fixture.owner.isClaimed)
        XCTAssertEqual(observed.batches.count, 3)
        XCTAssertEqual(observed.batches.map(\.speechObservationIsFinal), [false, false, true])
        XCTAssertTrue(observed.batches.allSatisfy { !$0.isComplete && $0.speakers.isEmpty })
        XCTAssertTrue(observed.batches.flatMap(\.segments).allSatisfy { $0.status == .provisional && $0.speakerID == nil })
        XCTAssertEqual(final.segments.map(\.id), observed.batches.last?.segments.map(\.id))
        XCTAssertEqual(observed.batches.first?.segments.map(\.text), ["Scoped", "provider"])
        XCTAssertEqual(observed.batches.last?.segments.map(\.text), ["Scoped", "provider", "grows"])
        XCTAssertEqual(final.segments.map(\.text), ["Scoped", "provider", "grows"])
        XCTAssertEqual(final.segments.map { $0.start.seconds }, [8.1, 8.4, 8.8])
        XCTAssertTrue(final.isComplete)
        XCTAssertTrue(final.segments.allSatisfy { $0.status == .final })
    }

    func testProgressiveNativeObserverRefusalDrainsScopeWithoutCanonicalCheckpoint() async throws {
        let fixture = try self.makeNativePCMPreviewFixture()
        addTeardownBlock { await MainActor.run { fixture.service.releaseExclusiveActivity(fixture.lease) } }
        let attempt = UUID(); let marker = CocoaError(.userCancelled)
        try await fixture.runtime.preparePCMResources(attemptID: attempt, configuration: fixture.configuration)
        let consumer = try MeetingProcessingPipeline.makeProgressiveMemoryAudioConsumer(
            recognize: { window, offset in
                try await fixture.runtime.recognizePCM(window: window, offset: offset, trackID: UUID(),
                    attemptID: attempt, configuration: fixture.configuration, preview: { _ in throw marker })
            }, checkpoint: { _ in XCTFail("Refused preview cannot publish a canonical checkpoint") }, failure: { _ in })
        addTeardownBlock { try? await consumer.finish() }
        XCTAssertTrue(consumer.enqueue(try self.progressiveSample(frames: 48_000, start: 0)))
        do { try await consumer.finish(); XCTFail("Observer failure must terminate the consumer") }
        catch { XCTAssertEqual(error as? CocoaError, marker) }
        XCTAssertEqual(fixture.provider.timedSampleCounts, [48_000])
        XCTAssertEqual(fixture.provider.releaseCalls, 1)
        XCTAssertFalse(fixture.owner.isClaimed)
    }

    func testProgressiveNativeCancellationJoinsObserverAndRejectsConcurrentWindow() async throws {
        let fixture = try self.makeNativePCMPreviewFixture()
        addTeardownBlock { await MainActor.run { fixture.service.releaseExclusiveActivity(fixture.lease) } }
        let attempt = UUID(); let track = UUID(); let latch = Latch(); let observed = PCMPreviewObservation()
        try await fixture.runtime.preparePCMResources(attemptID: attempt, configuration: fixture.configuration)
        let entered = expectation(description: "Cancellation-deaf observer entered")
        let consumer = try MeetingProcessingPipeline.makeProgressiveMemoryAudioConsumer(
            recognize: { window, offset in
                let operation = Task {
                    try await fixture.runtime.recognizePCM(window: window, offset: offset, trackID: track,
                        attemptID: attempt, configuration: fixture.configuration,
                        preview: { _ in entered.fulfill(); await latch.wait() })
                }
                await MainActor.run { observed.operation = operation }
                return try await operation.value
            }, checkpoint: { _ in XCTFail("Cancelled progressive window cannot publish") }, failure: { _ in })
        addTeardownBlock {
            await latch.open()
            await MainActor.run { observed.operation?.cancel() }
            try? await consumer.finish()
        }
        XCTAssertTrue(consumer.enqueue(try self.progressiveSample(frames: 48_000, start: 0)))
        await fulfillment(of: [entered], timeout: 3)
        try XCTUnwrap(observed.operation).cancel()
        XCTAssertTrue(fixture.owner.isClaimed)
        XCTAssertEqual(fixture.provider.releaseCalls, 0, "Cancellation cannot unload while the observer is still running")
        do {
            _ = try await fixture.runtime.recognizePCM(samples: [0.1], offset: 1, trackID: track,
                attemptID: attempt, configuration: fixture.configuration)
            XCTFail("Cancelled progressive callback still owns the inference window")
        } catch { XCTAssertEqual(error as? MeetingParakeetNemotronRuntimeError, .concurrentPCMWindow) }
        await latch.open()
        do { try await consumer.finish(); XCTFail("Joined cancellation cannot publish") }
        catch is CancellationError { }
        XCTAssertEqual(fixture.provider.timedSampleCounts, [48_000])
        XCTAssertEqual(fixture.provider.releaseCalls, 1)
        XCTAssertFalse(fixture.owner.isClaimed)
        _ = try await fixture.runtime.recognizePCM(samples: [Float](repeating: 0.1, count: 16_000), offset: 1, trackID: track,
            attemptID: attempt, configuration: fixture.configuration)
        XCTAssertEqual(fixture.provider.prepareCalls, 2, "A fresh window is admitted only after cancellation joins")
    }

    func testProgressiveNativePreparedScopeKeepsArtifactPinWhilePrefixesGrow() async throws {
        let fixture = try self.makeNativePCMPreviewFixture()
        addTeardownBlock { await MainActor.run { fixture.service.releaseExclusiveActivity(fixture.lease) } }
        let attempt = UUID(); let entered = expectation(description: "Pinned scope entered")
        try await fixture.runtime.preparePCMResources(attemptID: attempt, configuration: fixture.configuration)
        let consumer = try MeetingProcessingPipeline.makeProgressiveMemoryAudioConsumer(
            recognize: { window, offset in
                try await fixture.runtime.recognizePCM(window: window, offset: offset, trackID: UUID(),
                    attemptID: attempt, configuration: fixture.configuration, preview: { batch in if !batch.speechObservationIsFinal { entered.fulfill() } })
            }, checkpoint: { _ in }, failure: { _ in XCTFail("Pinned original configuration remains valid") })
        addTeardownBlock { try? await consumer.finish() }
        XCTAssertTrue(consumer.enqueue(try self.progressiveSample(frames: 48_000, start: 0)))
        await fulfillment(of: [entered], timeout: 3)
        let changed = MeetingFinalProcessingConfiguration(asrModel: fixture.configuration.asrModel,
            asrArtifactFingerprint: "replacement-not-admitted", languageCode: fixture.configuration.languageCode,
            speakerLabelsEnabled: fixture.configuration.speakerLabelsEnabled)
        do {
            _ = try await fixture.runtime.recognizePCM(samples: [0.1], offset: 1, trackID: UUID(),
                attemptID: attempt, configuration: changed)
            XCTFail("A mutable artifact selection cannot enter the owned window")
        } catch MeetingModelResidencyError.staleGrant { }
        try await consumer.finish()
        XCTAssertEqual(fixture.provider.prepareCalls, 1)
        XCTAssertEqual(fixture.provider.timedSampleCounts, [48_000])
        XCTAssertEqual(fixture.provider.releaseCalls, 1)
    }


    private func makeNativePCMPreviewFixture() throws -> (service: ASRService, lease: ASRActivityLease,
        provider: NativeScopeProvider, owner: MeetingASRPreparationOwner,
        runtime: MeetingParakeetNemotronRuntime, configuration: MeetingFinalProcessingConfiguration) {
        let service = ASRService(meetingModelResidency: MeetingModelResidencyCoordinator())
        let lease = try service.acquireExclusiveActivity(.meeting)
        let provider = NativeScopeProvider()
        let owner = MeetingASRPreparationOwner(isActiveLease: { $0 == lease }, isUserDownloadInProgress: { false },
            retireDictationResources: { _ in }, makeProvider: { _ in provider },
            prepareProvider: { prepared, _, progress in try await prepared.prepare(progressHandler: progress) },
            drainExecutor: { _ in })
        service.meetingASRPreparationOwnerForTesting = owner
        let configuration = MeetingFinalProcessingConfiguration(asrModel: "gigaam-v3-eou",
            asrArtifactFingerprint: "synthetic-preview-artifact", languageCode: "ru", speakerLabelsEnabled: false)
        return (service, lease, provider, owner,
            MeetingParakeetNemotronRuntime(asrServiceProvider: { service }, modelLocator: StubModelLocator()), configuration)
    }

    func testNativePCMPreviewAfterASRDrainReusesWordTimesAndOneInference() async throws {
        let fixture = try self.makeNativePCMPreviewFixture()
        defer { fixture.service.releaseExclusiveActivity(fixture.lease) }
        let attempt = UUID(); let track = UUID()
        try await fixture.runtime.preparePCMResources(attemptID: attempt, configuration: fixture.configuration)
        let observed = PCMPreviewObservation()
        let result = try await fixture.runtime.recognizePCM(samples: [Float](repeating: 0, count: 16_000),
            offset: 8, trackID: track, attemptID: attempt, configuration: fixture.configuration,
            preview: { batch in
                await MainActor.run {
                    XCTAssertFalse(fixture.owner.isClaimed, "ASR weights must be drained before preview or speaker phases")
                    XCTAssertEqual(fixture.provider.releaseCalls, 1)
                    observed.batch = batch
                }
            })
        let preview = try XCTUnwrap(observed.batch)
        XCTAssertFalse(preview.isComplete)
        XCTAssertTrue(preview.speakers.isEmpty)
        XCTAssertTrue(preview.segments.allSatisfy { $0.speakerID == nil && $0.attributionState == .unassigned && $0.status == .provisional })
        XCTAssertEqual(preview.segments.map(\.text), ["Scoped", "provider"])
        XCTAssertEqual(preview.segments.map { $0.start.seconds }, [8.1, 8.4])
        XCTAssertEqual(preview.segments.map(\.id), result.segments.map(\.id))
        XCTAssertEqual(preview.segments.map(\.text), result.segments.map(\.text))
        XCTAssertTrue(result.isComplete)
        XCTAssertTrue(result.segments.allSatisfy { $0.status == .final })
        XCTAssertEqual(fixture.provider.prepareCalls, 1)
        XCTAssertEqual(fixture.provider.timedSampleCounts, [16_000])
    }

    func testNativePCMObserverRefusalPropagatesAfterOneDrainedASRPass() async throws {
        let fixture = try self.makeNativePCMPreviewFixture()
        defer { fixture.service.releaseExclusiveActivity(fixture.lease) }
        let attempt = UUID(); let marker = CocoaError(.userCancelled)
        try await fixture.runtime.preparePCMResources(attemptID: attempt, configuration: fixture.configuration)
        do {
            _ = try await fixture.runtime.recognizePCM(samples: [Float](repeating: 0, count: 16_000),
                offset: 0, trackID: UUID(), attemptID: attempt, configuration: fixture.configuration,
                preview: { _ in throw marker })
            XCTFail("A refused display observation cannot produce canonical output")
        } catch { XCTAssertEqual(error as? CocoaError, marker) }
        XCTAssertEqual(fixture.provider.timedSampleCounts, [16_000])
        XCTAssertEqual(fixture.provider.releaseCalls, 1)
        XCTAssertFalse(fixture.owner.isClaimed)
    }

    func testNativePCMPreviewCancellationJoinsObserverBeforeReleasingWindow() async throws {
        let fixture = try self.makeNativePCMPreviewFixture()
        defer { fixture.service.releaseExclusiveActivity(fixture.lease) }
        let attempt = UUID(); let track = UUID(); let latch = Latch()
        try await fixture.runtime.preparePCMResources(attemptID: attempt, configuration: fixture.configuration)
        let reached = expectation(description: "Preview reached after ASR")
        let operation = Task {
            try await fixture.runtime.recognizePCM(samples: [Float](repeating: 0, count: 16_000),
                offset: 0, trackID: track, attemptID: attempt, configuration: fixture.configuration,
                preview: { _ in reached.fulfill(); await latch.wait() })
        }
        await fulfillment(of: [reached], timeout: 2)
        operation.cancel()
        do {
            _ = try await fixture.runtime.recognizePCM(samples: [Float](repeating: 0, count: 16_000),
                offset: 1, trackID: track, attemptID: attempt, configuration: fixture.configuration)
            XCTFail("Cancelled observer must still own its window until it returns")
        } catch { XCTAssertEqual(error as? MeetingParakeetNemotronRuntimeError, .concurrentPCMWindow) }
        await latch.open()
        do { _ = try await operation.value; XCTFail("Cancelled observation cannot produce canonical output") }
        catch is CancellationError { }
        XCTAssertEqual(fixture.provider.timedSampleCounts, [16_000])
        XCTAssertFalse(fixture.owner.isClaimed)
        _ = try await fixture.runtime.recognizePCM(samples: [Float](repeating: 0, count: 16_000),
            offset: 1, trackID: track, attemptID: attempt, configuration: fixture.configuration)
        XCTAssertEqual(fixture.provider.timedSampleCounts, [16_000, 16_000], "Fresh window can run after the cancellation joined")
    }

    /// Deliberately has no architecture guard: generic ASR must also work in the Intel host,
    /// while the injected owner/provider keep this test outside CoreML and real model caches.
    func testNativeRuntimeUsesGenericASRScopeWithFrozenArtifactConfigurationOnEveryArchitecture() async throws {
        let service = ASRService(meetingModelResidency: MeetingModelResidencyCoordinator())
        let lease = try service.acquireExclusiveActivity(.meeting)
        defer { service.releaseExclusiveActivity(lease) }
        let provider = NativeScopeProvider()
        var factoryConfigurations: [MeetingFinalProcessingConfiguration] = []
        var prepareConfigurations: [MeetingFinalProcessingConfiguration] = []
        var drainCalls = 0
        let owner = MeetingASRPreparationOwner(
            isActiveLease: { $0 == lease },
            isUserDownloadInProgress: { false },
            retireDictationResources: { _ in },
            makeProvider: { configuration in
                factoryConfigurations.append(configuration)
                return provider
            },
            prepareProvider: { prepared, configuration, progress in
                XCTAssertTrue(prepared as AnyObject === provider)
                prepareConfigurations.append(configuration)
                try await prepared.prepare(progressHandler: progress)
            },
            drainExecutor: { _ in drainCalls += 1 }
        )
        service.meetingASRPreparationOwnerForTesting = owner
        let configuration = MeetingFinalProcessingConfiguration(
            asrModel: "gigaam-v3-eou",
            asrArtifactFingerprint: "synthetic-frozen-artifact-sha256",
            asrArtifactDirectory: URL(fileURLWithPath: "/fixture/never-read-model-artifacts"),
            languageCode: "ru",
            diarizationFingerprint: "fixture-disabled-diarization"
        )
        let attemptID = UUID()
        let runtime = MeetingParakeetNemotronRuntime(
            asrServiceProvider: { service }, modelLocator: StubModelLocator()
        )

        _ = try await runtime.withPreparedASR(attemptID: attemptID, configuration: configuration) { session in
            let output = try await session.transcribeWithTimings([Float](repeating: 0, count: 16_000))
            XCTAssertEqual(output.result.text, "Scoped provider")
            XCTAssertEqual(output.words.map(\.text), ["Scoped", "provider"])
            XCTAssertEqual(output.words.first?.start, 0.1)
            return MeetingParakeetPhaseResult()
        }

        XCTAssertEqual(factoryConfigurations, [configuration])
        XCTAssertEqual(prepareConfigurations, [configuration])
        XCTAssertEqual(provider.prepareCalls, 1)
        XCTAssertEqual(provider.timedSampleCounts, [16_000])
        XCTAssertEqual(drainCalls, 1)
        XCTAssertFalse(owner.isClaimed)
        XCTAssertFalse(owner.isDraining)
        XCTAssertNil(owner.currentClaimToken)
    }
    #endif

    func testGigaAMTranscriptOnlyUsesRealWordTimesAndCoverageWithoutInventedSpeakers() async throws {
        let fixture = self.makeTwoEpochFixture()
        var session = fixture.session
        session.languageCode = "ru"
        let runtime = FakeRuntime()
        let backend = MeetingProviderBackedBackend(
            descriptor: try XCTUnwrap(PichiMeetingProviderFactory.registeredBackendDescriptor(for: "gigaam-v3-eou")),
            providerModelID: "gigaam-v3-eou",
            runtimeFactory: { _ in runtime },
            modelLocator: StubModelLocator(),
            materializer: FakeMaterializer()
        )
        let configuration = MeetingFinalProcessingConfiguration(
            asrModel: "gigaam-v3-eou", languageCode: "ru",
            diarizationFingerprint: PichiMeetingProviderFactory.transcriptOnlyDiarizationFingerprint
        )
        let plan = try backend.plan(self.makeRequest(
            session: session, directory: self.makeTempSessionDirectory(), configuration: configuration
        ))
        let manifest = try self.makeManifest(plan: plan, observations: fixture.observations)
        runtime.asrSession.responses = ["Привет", "Договорились", "Пятница"].map {
            .init(text: $0, words: [.init(text: $0, start: 0.2, end: 0.6)])
        }
        let outcome = try await backend.execute(plan: plan, manifest: manifest, progress: { _ in })
        guard case let .canonicalEvidence(bundle) = outcome else { return XCTFail("Expected canonical evidence") }
        XCTAssertEqual(bundle.evidence.backendID, .gigaam)
        XCTAssertEqual(bundle.evidence.units.map(\.text), ["Привет", "Договорились", "Пятница"])
        XCTAssertTrue(bundle.evidence.units.allSatisfy { $0.precision == .word && $0.speaker == .unassigned })
        XCTAssertEqual(bundle.evidence.units.first?.analysisStart, 0.2)
        XCTAssertEqual(bundle.evidence.units.first?.analysisEnd, 0.6)
        XCTAssertTrue(bundle.evidence.speakerActivity.isEmpty)
        XCTAssertEqual(runtime.diarizationScopeCount, 0)
        XCTAssertEqual(runtime.asrConfigurations, [configuration])
        XCTAssertEqual(bundle.coverageReceipts.count, 3)
        XCTAssertTrue(bundle.coverageReceipts.allSatisfy { $0.status == .processed })
    }

    func testGigaAMMissingSpeakerModelDoesNotPreventTranscriptionAndUntimedTextStaysUtterance() async throws {
        let fixture = self.makeTwoEpochFixture(mode: .inRoom)
        var session = fixture.session
        session.languageCode = "ru"
        let locator = StubModelLocator()
        locator.error = MeetingNemotronModelReadinessError.modelNotInstalled(path: "/fixture/missing")
        let runtime = FakeRuntime()
        let backend = MeetingProviderBackedBackend(
            descriptor: try XCTUnwrap(PichiMeetingProviderFactory.registeredBackendDescriptor(for: "gigaam-v3-eou")),
            providerModelID: "gigaam-v3-eou",runtimeFactory: { _ in runtime }, modelLocator: locator, materializer: FakeMaterializer())
        let configuration = MeetingFinalProcessingConfiguration(asrModel: "gigaam-v3-eou", languageCode: "ru")
        let plan = try backend.plan(self.makeRequest(session: session, directory: self.makeTempSessionDirectory(), configuration: configuration))
        let manifest = try self.makeManifest(plan: plan, observations: fixture.observations)
        runtime.asrSession.responses = [.init(text: "Обсудим проект", words: []), .init(text: "Следующий шаг", words: []), .init(text: "Итоги", words: [])]
        let outcome = try await backend.execute(plan: plan, manifest: manifest, progress: { _ in })
        guard case let .canonicalEvidence(bundle) = outcome else { return XCTFail("Expected canonical evidence") }
        XCTAssertFalse(bundle.evidence.units.isEmpty)
        XCTAssertTrue(bundle.evidence.units.allSatisfy { $0.precision == .utterance && $0.speaker == .unassigned })
        XCTAssertEqual(runtime.diarizationScopeCount, 0)
        XCTAssertEqual(runtime.asrConfigurations, [configuration])
    }

    #if arch(arm64)
    func testStreamingProviderPlanRequiresModelAndFreezesTheExactRequest() throws {
        let fixture = self.makeTwoEpochFixture(mode: .inRoom)
        var session = fixture.session
        session.languageCode = "ru"
        session.speakerProcessingMode = .streaming
        let locator = StubModelLocator()
        let descriptor = try XCTUnwrap(PichiMeetingProviderFactory.registeredBackendDescriptor(for: "gigaam-v3-eou"))
        let configuration = MeetingFinalProcessingConfiguration(asrModel: "gigaam-v3-eou", languageCode: "ru",
            diarizationFingerprint: MeetingNemotronModelProfile.experimentalFast128FP16CPU.streamingImplementationFingerprint,
            speakerProcessingMode: .streaming)
        let request = self.makeRequest(session: session, directory: try self.makeTempSessionDirectory(), configuration: configuration)
        let backend = MeetingProviderBackedBackend(descriptor: descriptor, providerModelID: "gigaam-v3-eou",
            runtimeFactory: { _ in XCTFail("Planning must not create a runtime"); return FakeRuntime() },
            modelLocator: locator, materializer: FakeMaterializer())
        let plan = try backend.plan(request)
        locator.error = MeetingNemotronModelReadinessError.modelNotInstalled(path: "/fixture/replaced")
        XCTAssertEqual(try backend.plan(request).request, plan.request,
                       "Repeated planning reuses the frozen plan instead of selecting a replacement artifact")
        let changedRequest = MeetingBackendRequest(attemptID: UUID(), session: session,
            sessionDirectory: request.sessionDirectory, configuration: configuration)
        XCTAssertThrowsError(try backend.plan(changedRequest)) {
            XCTAssertEqual($0 as? MeetingBackendError, .hostCapabilityRequestMismatch(backend: descriptor.id))
        }
        let missing = MeetingProviderBackedBackend(descriptor: descriptor, providerModelID: "gigaam-v3-eou",
            runtimeFactory: { _ in XCTFail("Missing required model must fail before runtime creation"); return FakeRuntime() },
            modelLocator: locator, materializer: FakeMaterializer())
        XCTAssertThrowsError(try missing.plan(request)) {
            guard let error = $0 as? MeetingNemotronModelReadinessError, case .modelNotInstalled = error else {
                return XCTFail("Streaming cannot silently continue without its requested model")
            }
        }
    }
    #endif

    func testGigaAMRefusesAnotherASRModelOrLanguageInsteadOfRelabelingIt() throws {
        let fixture = self.makeTwoEpochFixture()
        let backend = MeetingProviderBackedBackend(
            descriptor: try XCTUnwrap(PichiMeetingProviderFactory.registeredBackendDescriptor(for: "gigaam-v3-eou")),
            providerModelID: "gigaam-v3-eou",runtimeFactory: { _ in FakeRuntime() })
        XCTAssertThrowsError(try backend.plan(self.makeRequest(session: fixture.session, directory: self.makeTempSessionDirectory()))) { error in
            XCTAssertEqual(error as? MeetingProviderOptionsError, .unsupportedASRModel("parakeet-tdt-v2"))
        }
        let englishConfiguration = MeetingFinalProcessingConfiguration(asrModel: "gigaam-v3-eou", languageCode: "en")
        XCTAssertThrowsError(try backend.plan(self.makeRequest(session: fixture.session, directory: self.makeTempSessionDirectory(), configuration: englishConfiguration))) { error in
            XCTAssertEqual(error as? MeetingBackendError, .unsupportedLanguage(backend: .gigaam, languageCode: "en"))
        }
    }

    func testGigaAMPipelinePinsRussianModelAndPersistsBackendProvenance() async throws {
        let fixture = self.makeTwoEpochFixture()
        var session = fixture.session
        session.languageCode = "ru"
        let runtime = FakeRuntime()
        runtime.asrSession.responses = ["Запишем", "Решение", "Задачу"].map {
            .init(text: $0, words: [.init(text: $0, start: 0.2, end: 0.6)])
        }
        let registry = MeetingTranscriptionBackendRegistry(defaultBackendID: .gigaam)
        let descriptor = try XCTUnwrap(PichiMeetingProviderFactory.registeredBackendDescriptor(for: "gigaam-v3-eou"))
        registry.register(.gigaam) { context in
            MeetingProviderBackedBackend(descriptor: descriptor, providerModelID: "gigaam-v3-eou", runtimeFactory: context.parakeetNemotronRuntimeFactory, modelLocator: StubModelLocator(), materializer: FakeMaterializer())
        }
        let pipeline = MeetingProcessingPipeline(
            asrServiceProvider: { XCTFail("Fake runtime must not prepare a real ASR service"); return ASRService() },
            managesModelResidency: false,
            serializationGate: MeetingProcessingSerializationGate(),
            backendRegistry: registry,
            chunkObserver: FixtureObserver(results: fixture.observations),
            meetingRuntimeFactory: { _ in runtime }
        )
        let result = try await pipeline.process(session: session, sessionDirectory: self.makeTempSessionDirectory(), progress: { _ in })
        XCTAssertEqual(result.attempt.backendID, MeetingBackendID.gigaam.rawValue)
        XCTAssertEqual(result.attempt.asrModel, "gigaam-v3-eou")
        XCTAssertEqual(result.attempt.languageCode, "ru")
        XCTAssertEqual(runtime.asrConfigurations.first?.asrModel, "gigaam-v3-eou")
        XCTAssertEqual(runtime.asrConfigurations.first?.languageCode, "ru")
        XCTAssertNotNil(result.resultSidecarReference)
        XCTAssertTrue(result.isComplete)
    }

    // MARK: - Canonical turn merge (chronological fold)

    private func canonicalSegment(
        id: UUID = UUID(),
        trackID: UUID,
        start: Double,
        end: Double,
        speakerID: UUID?,
        text: String,
        overlap: MeetingTranscriptOverlap = .none,
        status: MeetingTranscriptStatus = .final,
        completeness: MeetingTranscriptCompleteness = .complete,
        isLikelyEcho: Bool? = nil
    ) -> MeetingTranscriptSegment {
        MeetingTranscriptSegment(
            id: id,
            start: MeetingMediaTime(value: Int64((start * 1000).rounded()), timescale: 1000),
            end: MeetingMediaTime(value: Int64((end * 1000).rounded()), timescale: 1000),
            sourceTrackID: trackID,
            speakerID: speakerID,
            text: text,
            revision: 0,
            status: status,
            overlap: overlap,
            completeness: completeness,
            isLikelyEcho: isLikelyEcho
        )
    }

    func testCanonicalProductPublicationMergesWordEvidenceIntoTurns() {
        let trackID = UUID()
        let speakerID = UUID()
        let input = [
            self.canonicalSegment(trackID: trackID, start: 0, end: 0.2, speakerID: speakerID, text: "Hello"),
            self.canonicalSegment(trackID: trackID, start: 0.21, end: 0.25, speakerID: speakerID, text: ","),
            self.canonicalSegment(trackID: trackID, start: 0.3, end: 0.6, speakerID: speakerID, text: "world"),
            self.canonicalSegment(trackID: trackID, start: 0.4, end: 0.7, speakerID: UUID(), text: "Other"),
        ]

        let first = MeetingProcessingPipeline.mergeCanonicalSegments(input)
        let second = MeetingProcessingPipeline.mergeCanonicalSegments(input)

        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(first.first { $0.speakerID == speakerID }?.text, "Hello, world")
        XCTAssertEqual(first.map(\.id), second.map(\.id), "merged turn IDs are deterministic")
    }

    func testCanonicalMergeKeepsABAAsThreeTurnsInsteadOfBridgingAcrossB() {
        let trackID = UUID()
        let speakerA = UUID()
        let speakerB = UUID()
        // A ends at 1.0, B runs 1.2-1.5, A resumes 1.6-2.0. The two A segments are within the
        // 3s gap/30s duration bounds of each other, but B sits chronologically between them on
        // the same track, so they must not bridge across it.
        let input = [
            self.canonicalSegment(trackID: trackID, start: 0, end: 1.0, speakerID: speakerA, text: "First"),
            self.canonicalSegment(trackID: trackID, start: 1.2, end: 1.5, speakerID: speakerB, text: "Interject"),
            self.canonicalSegment(trackID: trackID, start: 1.6, end: 2.0, speakerID: speakerA, text: "Second"),
        ]

        let turns = MeetingProcessingPipeline.mergeCanonicalSegments(input)

        XCTAssertEqual(turns.count, 3)
        XCTAssertEqual(turns.map(\.text), ["First", "Interject", "Second"])
        XCTAssertEqual(turns.map(\.speakerID), [speakerA, speakerB, speakerA])
    }

    func testCanonicalMergePreservesUncertainNativeMembersAcrossSpeakerAndTrackBoundaries() {
        let mic = UUID(), application = UUID(), speaker = UUID()
        var assigned = self.canonicalSegment(trackID: mic, start: 0, end: 1, speakerID: speaker, text: "anchor")
        var uncertain = self.canonicalSegment(trackID: mic, start: 1, end: 1.2, speakerID: nil, text: "tail", overlap: .ambiguous)
        var other = self.canonicalSegment(trackID: application, start: 1.2, end: 2, speakerID: nil, text: "other")
        assigned.nativePrecision = .word
        uncertain.nativePrecision = .word
        uncertain.attributionState = .timingUncertain
        other.nativePrecision = .word
        let input = [assigned, uncertain, other]
        let output = MeetingProcessingPipeline.mergeCanonicalSegments(input)
        XCTAssertEqual(output, input, "Readable continuity must not rewrite native IDs, overlap, uncertainty or source tracks")
    }

    func testCanonicalMergeCombinesAdjacentSameKeySegments() {
        let trackID = UUID()
        let speakerA = UUID()
        let input = [
            self.canonicalSegment(trackID: trackID, start: 0, end: 1.0, speakerID: speakerA, text: "First"),
            self.canonicalSegment(trackID: trackID, start: 1.5, end: 2.0, speakerID: speakerA, text: "Second"),
        ]

        let turns = MeetingProcessingPipeline.mergeCanonicalSegments(input)

        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns.first?.text, "First Second")
        XCTAssertEqual(turns.first?.end.seconds ?? -1, 2.0, accuracy: 0.0001)
    }

    func testCanonicalMergeRespectsMaximumGapBoundary() {
        let trackID = UUID()
        let speakerA = UUID()
        let gap = MeetingProcessingPipeline.canonicalTurnMergeGapSeconds
        let withinBound = [
            self.canonicalSegment(trackID: trackID, start: 0, end: 1.0, speakerID: speakerA, text: "First"),
            self.canonicalSegment(
                trackID: trackID, start: 1.0 + gap, end: 1.0 + gap + 0.5, speakerID: speakerA, text: "Second"
            ),
        ]
        let beyondBound = [
            self.canonicalSegment(trackID: trackID, start: 0, end: 1.0, speakerID: speakerA, text: "First"),
            self.canonicalSegment(
                trackID: trackID,
                start: 1.0 + gap + 0.01,
                end: 1.0 + gap + 0.51,
                speakerID: speakerA,
                text: "Second"
            ),
        ]

        XCTAssertEqual(
            MeetingProcessingPipeline.mergeCanonicalSegments(withinBound).count,
            1,
            "a gap exactly at the named maximum still merges"
        )
        XCTAssertEqual(
            MeetingProcessingPipeline.mergeCanonicalSegments(beyondBound).count,
            2,
            "a gap past the named maximum starts a new turn"
        )
    }

    func testCanonicalMergeRespectsMaximumDurationBoundary() {
        let trackID = UUID()
        let speakerA = UUID()
        let maxDuration = MeetingProcessingPipeline.canonicalTurnMaximumDurationSeconds
        let withinBound = [
            self.canonicalSegment(trackID: trackID, start: 0, end: 1.0, speakerID: speakerA, text: "First"),
            self.canonicalSegment(
                trackID: trackID, start: 1.5, end: maxDuration, speakerID: speakerA, text: "Second"
            ),
        ]
        let beyondBound = [
            self.canonicalSegment(trackID: trackID, start: 0, end: 1.0, speakerID: speakerA, text: "First"),
            self.canonicalSegment(
                trackID: trackID, start: 1.5, end: maxDuration + 0.01, speakerID: speakerA, text: "Second"
            ),
        ]

        XCTAssertEqual(
            MeetingProcessingPipeline.mergeCanonicalSegments(withinBound).count,
            1,
            "a combined duration exactly at the named maximum still merges"
        )
        XCTAssertEqual(
            MeetingProcessingPipeline.mergeCanonicalSegments(beyondBound).count,
            2,
            "a combined duration past the named maximum starts a new turn even with no gap"
        )
    }

    func testCanonicalMergeOrdersTurnsDeterministicallyAcrossTracks() {
        let trackA = UUID()
        let trackB = UUID()
        // Two tracks whose turns interleave in time; publication must be sorted globally by
        // (start, end, sourceTrackID, id), independent of input order. Each segment on a track
        // gets a distinct speaker so none of them merge with each other — this test is about
        // publication order, not turn merging.
        let shuffled = [
            self.canonicalSegment(trackID: trackB, start: 0.5, end: 1.0, speakerID: UUID(), text: "B-second"),
            self.canonicalSegment(trackID: trackA, start: 0, end: 0.4, speakerID: UUID(), text: "A-first"),
            self.canonicalSegment(trackID: trackA, start: 1.2, end: 1.6, speakerID: UUID(), text: "A-second"),
            self.canonicalSegment(trackID: trackB, start: 0, end: 0.3, speakerID: UUID(), text: "B-first"),
        ]

        let first = MeetingProcessingPipeline.mergeCanonicalSegments(shuffled)
        let second = MeetingProcessingPipeline.mergeCanonicalSegments(shuffled.shuffled())
        let expectedIDs = shuffled.sorted {
            ($0.start, $0.end, $0.sourceTrackID.uuidString, $0.id.uuidString)
                < ($1.start, $1.end, $1.sourceTrackID.uuidString, $1.id.uuidString)
        }.map(\.id)

        XCTAssertEqual(first.map(\.id), expectedIDs, "global order uses the documented stable sort key")
        XCTAssertEqual(first.map(\.id), second.map(\.id), "turn IDs are deterministic regardless of input order")
    }

    func testCanonicalMergeNeverCombinesAcrossTracksEvenWithSameSpeakerID() {
        let trackA = UUID()
        let trackB = UUID()
        let speakerID = UUID()
        let turns = MeetingProcessingPipeline.mergeCanonicalSegments([
            self.canonicalSegment(trackID: trackA, start: 0, end: 1, speakerID: speakerID, text: "A"),
            self.canonicalSegment(trackID: trackB, start: 1, end: 2, speakerID: speakerID, text: "B"),
        ])

        XCTAssertEqual(turns.count, 2, "track provenance is a hard merge boundary")
        XCTAssertEqual(Set(turns.map(\.sourceTrackID)), [trackA, trackB])
    }

    // MARK: - Plan validation

    func testPlanRejectsMissingModelUnsupportedLanguageAndUnsupportedOptions() async throws {
        let fixture = self.makeTwoEpochFixture()
        let directory = try self.makeTempSessionDirectory()

        let missingLocator = StubModelLocator(
            error: MeetingNemotronModelReadinessError.modelNotInstalled(path: "/tmp/none.mlpackage")
        )
        let unreadyBackend = self.makeBackend(runtime: FakeRuntime(), locator: missingLocator)
        XCTAssertThrowsError(try unreadyBackend.plan(self.makeRequest(session: fixture.session, directory: directory))) {
            XCTAssertEqual(
                $0 as? MeetingNemotronModelReadinessError,
                .modelNotInstalled(path: "/tmp/none.mlpackage")
            )
        }

        let unsupported = self.makeSession(
            mode: .inRoom,
            tracks: [self.makeMicTrack(chunks: [self.makeChunk(sequence: 0, start: 0, end: 1)], eraStart: 0)],
            languageCode: "zh"
        )
        let backend = self.makeBackend(runtime: FakeRuntime())
        XCTAssertThrowsError(try backend.plan(self.makeRequest(session: unsupported, directory: directory))) {
            XCTAssertEqual(
                $0 as? MeetingBackendError,
                .unsupportedLanguage(backend: .parakeetNemotron, languageCode: "zh")
            )
        }

        var boosted = MeetingFinalProcessingConfiguration(languageCode: "en")
        boosted = MeetingFinalProcessingConfiguration(
            asrModel: boosted.asrModel,
            languageCode: boosted.languageCode,
            vocabularyBoostingEnabled: true,
            pronunciationMatchingEnabled: boosted.pronunciationMatchingEnabled,
            customDictionaryRewritingEnabled: boosted.customDictionaryRewritingEnabled,
            experimentalUnifiedFinalEnabled: boosted.experimentalUnifiedFinalEnabled,
            diarizationFingerprint: boosted.diarizationFingerprint,
            pipelineVersion: boosted.pipelineVersion
        )
        XCTAssertThrowsError(try backend.plan(self.makeRequest(
            session: fixture.session,
            directory: directory,
            configuration: boosted
        ))) {
            XCTAssertEqual($0 as? MeetingProviderOptionsError, .unsupportedFeature("vocabularyBoosting"))
        }

        let plan = try backend.plan(self.makeRequest(session: fixture.session, directory: directory))
        XCTAssertEqual(plan.resultContract, .canonicalEvidence)
        XCTAssertEqual(plan.declaredFinalPrecisions, [.word, .utterance])
        XCTAssertEqual(Set(plan.chunkIDsByTrackID.keys), [fixture.micTrack.id, fixture.appTrack.id])
    }

    func testSelectedProReachesTheFrozenRuntimeForEnglishAndGerman() async throws {
        for (language, model) in [("en", "fluid-parakeet-pro"), ("de", "fluid-parakeet-pro")] {
            let fixture = self.makeTwoEpochFixture()
            var session = fixture.session
            session.languageCode = language
            let runtime = FakeRuntime()
            let backend = self.makeBackend(runtime: runtime)
            let configuration = MeetingFinalProcessingConfiguration(preferredASRModel: .fluidParakeetPro, languageCode: language)
            let request = try self.makeRequest(session: session, directory: self.makeTempSessionDirectory(), configuration: configuration)
            let plan = try backend.plan(request)
            let manifest = try self.makeManifest(plan: plan, observations: fixture.observations)
            runtime.asrSession.responses = (0..<3).map { _ in
                .init(text: "Hello", words: [.init(text: "Hello", start: 0.2, end: 0.4)])
            }
            let outcome = try await backend.execute(plan: plan, manifest: manifest, progress: { _ in })
            guard case let .canonicalEvidence(bundle) = outcome else { return XCTFail("Expected canonical evidence") }
            XCTAssertEqual(configuration.asrModel, model)
            XCTAssertEqual(runtime.asrConfigurations, [configuration])
            XCTAssertEqual(bundle.evidence.units.map(\.text), ["Hello", "Hello", "Hello"])
            XCTAssertTrue(bundle.coverageReceipts.allSatisfy { $0.status == .processed })
        }
    }

    func testMultilingualPlanAndExecutionKeepV3LanguageAndWordEvidence() async throws {
        let fixture = self.makeTwoEpochFixture()
        var session = fixture.session
        session.languageCode = "de"
        let runtime = FakeRuntime()
        let backend = self.makeBackend(runtime: runtime)
        let configuration = MeetingFinalProcessingConfiguration(languageCode: "de")
        let request = try self.makeRequest(session: session, directory: self.makeTempSessionDirectory(), configuration: configuration)
        let plan = try backend.plan(request)
        let manifest = try self.makeManifest(plan: plan, observations: fixture.observations)
        runtime.asrSession.responses = [
            .init(text: "Guten", words: [.init(text: "Guten", start: 0.2, end: 0.4)]),
            .init(text: "Morgen", words: [.init(text: "Morgen", start: 0.2, end: 0.4)]),
            .init(text: "Hallo", words: [.init(text: "Hallo", start: 0.2, end: 0.4)]),
        ]
        let outcome = try await backend.execute(plan: plan, manifest: manifest, progress: { _ in })
        guard case let .canonicalEvidence(bundle) = outcome else { return XCTFail("Expected canonical evidence") }
        XCTAssertEqual(runtime.asrConfigurations, [configuration])
        XCTAssertEqual(configuration.asrModel, "parakeet-tdt")
        XCTAssertEqual(bundle.evidence.units.map(\.text), ["Guten", "Morgen", "Hallo"])
        XCTAssertTrue(bundle.coverageReceipts.allSatisfy { $0.status == .processed })
        XCTAssertEqual(runtime.diarizationScopeCount, 1)
        XCTAssertEqual(session.languageCode, "de")
        XCTAssertThrowsError(try backend.plan(self.makeRequest(session: session, directory: request.sessionDirectory)))
    }

    func testExecuteRechecksTheExactArtifactFrozenDuringPlan() async throws {
        let fixture = self.makeTwoEpochFixture()
        let locator = StubModelLocator()
        let runtime = FakeRuntime()
        let backend = self.makeBackend(runtime: runtime, locator: locator)
        let plan = try backend.plan(self.makeRequest(
            session: fixture.session,
            directory: self.makeTempSessionDirectory()
        ))
        let manifest = try self.makeManifest(plan: plan, observations: fixture.observations)
        locator.error = MeetingNemotronModelReadinessError.artifactChanged(
            path: StubModelLocator.artifact.packageURL.path
        )

        await XCTAssertAsyncThrowsError(
            try await backend.execute(plan: plan, manifest: manifest, progress: { _ in })
        ) { error in
            XCTAssertEqual(
                error as? MeetingNemotronModelReadinessError,
                .artifactChanged(path: StubModelLocator.artifact.packageURL.path)
            )
        }
        XCTAssertEqual(runtime.diarizationScopeCount, 0)
    }

    // MARK: - Host request binding

    /// A fixture backend that asks the host for a runtime against a rewritten request.
    private final class RuntimeStealingBackend: MeetingTranscriptionBackend {
        let descriptor = MeetingBackendDescriptor(
            id: MeetingBackendID(rawValue: "fixture.runtime-stealer"),
            version: "test",
            execution: .local,
            supportedLanguageCodes: ["en"],
            supportedTrackKinds: Set(MeetingAudioTrackKind.allCases),
            supportedFinalPrecisions: [.word],
            resultContract: .canonicalEvidence,
            knownLimits: []
        )
        private let factory: MeetingParakeetNemotronRuntimeFactory

        init(factory: @escaping MeetingParakeetNemotronRuntimeFactory) {
            self.factory = factory
        }

        func plan(_ request: MeetingBackendRequest) throws -> MeetingBackendPlan {
            MeetingBackendPlan(request: request, descriptor: self.descriptor)
        }

        func execute(
            plan: MeetingBackendPlan,
            manifest _: MeetingAnalysisManifest?,
            progress _: @escaping @MainActor (MeetingProcessingStage) -> Void
        ) async throws -> MeetingBackendOutcome {
            let rewritten = MeetingBackendRequest(
                attemptID: UUID(),
                session: plan.request.session,
                sessionDirectory: plan.request.sessionDirectory,
                configuration: plan.request.configuration
            )
            _ = try self.factory(rewritten)
            throw MeetingBackendError.unknownBackend(self.descriptor.id)
        }
    }

    func testHostBindsRuntimeFactoryToTheFrozenRequest() async throws {
        let fixture = self.makeTwoEpochFixture()
        let directory = try self.makeTempSessionDirectory()
        let openAttemptID = try XCTUnwrap(fixture.session.processingAttempts.last?.id)

        final class RuntimeSpy {
            var requests: [MeetingBackendRequest] = []
        }
        let spy = RuntimeSpy()
        let runtime = FakeRuntime()

        let stealerID = MeetingBackendID(rawValue: "fixture.runtime-stealer")
        let registry = MeetingTranscriptionBackendRegistry(defaultBackendID: stealerID)
        registry.register(stealerID) { context in
            RuntimeStealingBackend(factory: context.parakeetNemotronRuntimeFactory)
        }
        let stealingPipeline = MeetingProcessingPipeline(
            asrServiceProvider: {
                XCTFail("Canonical dispatch must not reach ASR readiness")
                return ASRService()
            },
            managesModelResidency: false,
            serializationGate: MeetingProcessingSerializationGate(),
            backendRegistry: registry,
            chunkObserver: FixtureObserver(results: fixture.observations),
            meetingRuntimeFactory: { request in
                spy.requests.append(request)
                return runtime
            }
        )
        await XCTAssertAsyncThrowsError(
            try await stealingPipeline.process(session: fixture.session, sessionDirectory: directory) { _ in }
        ) { error in
            XCTAssertEqual(
                error as? MeetingBackendError,
                .hostCapabilityRequestMismatch(backend: stealerID)
            )
        }
        XCTAssertTrue(spy.requests.isEmpty, "a mismatched request must be refused before the factory runs")

        // And the composite backend, which passes its frozen plan's request, gets the runtime.
        let expectedConfiguration = try await PichiMeetingProviderFactory.frozenConfiguration(
            backendID: .parakeetNemotron,
            languageCode: "en",
            preferredASRModel: .parakeetTDTv2
        )
        let materializer = FakeMaterializer()
        let compositeRegistry = MeetingTranscriptionBackendRegistry(defaultBackendID: .parakeetNemotron)
        compositeRegistry.register(.parakeetNemotron) { context in
            MeetingParakeetNemotronBackend(
                runtimeFactory: context.parakeetNemotronRuntimeFactory,
                modelLocator: StubModelLocator(),
                materializer: materializer
            )
        }
        let pipeline = MeetingProcessingPipeline(
            asrServiceProvider: {
                XCTFail("Canonical dispatch must not reach ASR readiness")
                return ASRService()
            },
            managesModelResidency: false,
            serializationGate: MeetingProcessingSerializationGate(),
            backendRegistry: compositeRegistry,
            chunkObserver: FixtureObserver(results: fixture.observations),
            meetingRuntimeFactory: { request in
                spy.requests.append(request)
                return runtime
            },
            preferredASRModelProvider: { .parakeetTDTv2 }
        )
        runtime.asrSession.responses = [
            .init(text: "", words: []), .init(text: "", words: []), .init(text: "", words: []),
        ]
        let result = try await pipeline.process(
            session: fixture.session,
            sessionDirectory: directory,
            progress: { _ in }
        )
        XCTAssertEqual(spy.requests.count, 1)
        XCTAssertEqual(spy.requests.first?.attemptID, openAttemptID)
        XCTAssertEqual(spy.requests.first?.session.id, fixture.session.id)
        XCTAssertEqual(spy.requests.first?.sessionDirectory, directory)
        XCTAssertEqual(spy.requests.first?.configuration, expectedConfiguration)
        XCTAssertEqual(result.attempt.backendID, MeetingBackendID.parakeetNemotron.rawValue)
    }

    func testCompositeProcessingPreparesDiarizationModelBeforePlanning() async throws {
        let fixture = self.makeTwoEpochFixture()
        let directory = try self.makeTempSessionDirectory()
        struct DownloadFailed: Error {}
        final class Spy {
            var preparations = 0
            var runtimes = 0
        }
        let spy = Spy()
        // Planning would throw `modelNotInstalled`; seeing the download error instead proves the
        // model is prepared before planning, and a failed preparation stops the attempt.
        let registry = MeetingTranscriptionBackendRegistry(defaultBackendID: .parakeetNemotron)
        registry.register(.parakeetNemotron) { context in
            MeetingParakeetNemotronBackend(
                runtimeFactory: context.parakeetNemotronRuntimeFactory,
                modelLocator: StubModelLocator(error: MeetingNemotronModelReadinessError.modelNotInstalled(path: "/tmp/missing")),
                materializer: FakeMaterializer()
            )
        }
        let pipeline = MeetingProcessingPipeline(
            asrServiceProvider: {
                XCTFail("Canonical dispatch must not reach ASR readiness")
                return ASRService()
            },
            managesModelResidency: false,
            serializationGate: MeetingProcessingSerializationGate(),
            backendRegistry: registry,
            chunkObserver: FixtureObserver(results: fixture.observations),
            meetingRuntimeFactory: { _ in
                spy.runtimes += 1
                return FakeRuntime()
            },
            prepareDiarizationModel: {
                spy.preparations += 1
                throw DownloadFailed()
            }
        )
        await XCTAssertAsyncThrowsError(
            try await pipeline.process(session: fixture.session, sessionDirectory: directory) { _ in }
        ) { error in
            XCTAssertTrue(error is DownloadFailed, "expected the download error, got \(error)")
        }
        XCTAssertEqual(spy.preparations, 1)
        XCTAssertEqual(spy.runtimes, 0, "no model runtime may be created without the model")
    }

    // MARK: - Epoch isolation and unit assignment

    func testV4RetainedRetryRechecksShortRivalInsteadOfReusingOwnerConfirmation() async throws {
        try await self.assertRetainedOwnerRetry(
            fingerprint: MeetingNemotronModelProfile.experimentalFast128FP16CPU.streamingImplementationFingerprint,
            initialRivalMatchesOwner: false, retryEvidence: .ambiguous,
            expectedInitialOwner: true, expectedRetryOwner: false, expectedRetryEncoderCalls: 1)
    }

    func testV3RetainedRetryPreservesCachedOwnerDecisionWithoutReencoding() async throws {
        try await self.assertRetainedOwnerRetry(
            fingerprint: MeetingNemotronModelProfile.experimentalFast128FP16CPU.ownerV3StreamingImplementationFingerprint,
            initialRivalMatchesOwner: false, retryEvidence: .ambiguous,
            expectedInitialOwner: true, expectedRetryOwner: true, expectedRetryEncoderCalls: 0)
    }

    func testV4RetainedNegativeDecisionDoesNotSuppressNewValidEvidence() async throws {
        try await self.assertRetainedOwnerRetry(
            fingerprint: MeetingNemotronModelProfile.experimentalFast128FP16CPU.streamingImplementationFingerprint,
            initialRivalMatchesOwner: true, retryEvidence: .ownerAndDistantRival,
            expectedInitialOwner: false, expectedRetryOwner: true, expectedRetryEncoderCalls: 1)
    }

    func testV4RetainedRetryMissingOrFailedEncoderEvidenceCannotReuseOwnerConfirmation() async throws {
        for evidence: RetainedOwnerRetryEvidence in [.missingProfiles, .encoderFailure] {
            try await self.assertRetainedOwnerRetry(
                fingerprint: MeetingNemotronModelProfile.experimentalFast128FP16CPU.streamingImplementationFingerprint,
                initialRivalMatchesOwner: false, retryEvidence: evidence,
                expectedInitialOwner: true, expectedRetryOwner: false, expectedRetryEncoderCalls: 1)
        }
    }

    func testV4RetainedRetryMissingCompetingTrackCannotPromoteSurvivingOwner() async throws {
        try await self.assertRetainedOwnerRetryWithIncompleteRival(optionalReadDefect: nil)
    }

    func testV4RetainedRetryPartialEncoderRivalCannotPromoteSurvivingOwner() async throws {
        let profile = MeetingNemotronModelProfile.experimentalFast128FP16CPU
        for fingerprint in [profile.ownerV4StreamingImplementationFingerprint, profile.streamingImplementationFingerprint] {
            for evidence: RetainedOwnerRetryEvidence in [.missingRival, .duplicateRival, .invalidRival, .foreignRival] {
                try await self.assertRetainedOwnerRetry(fingerprint: fingerprint,
                    initialRivalMatchesOwner: true, retryEvidence: evidence,
                    expectedInitialOwner: false, expectedRetryOwner: false, expectedRetryEncoderCalls: 1)
            }
        }
    }

    func testV4RetainedRetryOptionalRivalReadFailureKeepsAnonymousTranscriptWithoutPromotion() async throws {
        for defect: FakeMaterializer.OptionalReadDefect in [.unreadable, .truncated, .nonFinite] {
            try await self.assertRetainedOwnerRetryWithIncompleteRival(optionalReadDefect: defect)
        }
    }

    private func assertRetainedOwnerRetryWithIncompleteRival(
        optionalReadDefect: FakeMaterializer.OptionalReadDefect?,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let ownerChunk = self.makePCMChunk(sequence: 0, start: 100, end: 112)
        let rivalChunk = self.makePCMChunk(sequence: 1, start: 100, end: 112)
        let ownerTrack = self.makeMicTrack(chunks: [ownerChunk], eraStart: 100)
        let rivalTrack = self.makeAppTrack(chunks: [rivalChunk])
        var session = self.makeSession(mode: .onlineCall, tracks: [ownerTrack, rivalTrack])
        session.speakerProcessingMode = .streaming
        let directory = try self.makeTempSessionDirectory()
        let configuration = MeetingFinalProcessingConfiguration(asrArtifactFingerprint: "synthetic-sha256",
            languageCode: "en",
            diarizationFingerprint: MeetingNemotronModelProfile.experimentalFast128FP16CPU.streamingImplementationFingerprint,
            speakerProcessingMode: .streaming)
        let observations: [MeetingAnalysisChunkKey: MeetingChunkObservationResult] = [
            .init(trackID: ownerTrack.id, chunkID: ownerChunk.id): self.makeObserved(ownerChunk, duration: 12),
            .init(trackID: rivalTrack.id, chunkID: rivalChunk.id): self.makeObserved(rivalChunk, duration: 12),
        ]
        var embedding = [Float](repeating: 0, count: 256); embedding[0] = 1
        let owner = MeetingOwnerVoiceProfileSnapshot(metadata: .init(generation: UUID(), enrolledAt: Date()),
            encoderFingerprint: MeetingOwnerVoiceProfileStore.encoderFingerprint, embeddings: [embedding, embedding])
        let locator = StubModelLocator(artifact: .init(
            packageURL: URL(fileURLWithPath: "/tmp/synthetic-fast128.nemotronbundle"),
            totalByteCount: 1, fileCount: 1, manifestSHA256: "synthetic", entryMetadataSHA256: "synthetic",
            profile: .experimentalFast128FP16CPU))
        let original = FakeRuntime(), materializer = FakeMaterializer()
        materializer.sampleAmplitude = 0.1; materializer.alternatingSamplePolarity = true
        original.ownerVoiceProfileSnapshot = owner
        let backend = self.makeBackend(runtime: original, materializer: materializer, locator: locator)
        let plan = try backend.plan(self.makeRequest(session: session, directory: directory, configuration: configuration))
        let manifest = try self.makeManifest(plan: plan, observations: observations)
        let ownerEpoch = try XCTUnwrap(manifest.track(ownerTrack.id)?.epochs.first, file: file, line: line)
        let rivalEpoch = try XCTUnwrap(manifest.track(rivalTrack.id)?.epochs.first, file: file, line: line)
        let ownerToken = MeetingBackendSpeakerToken(analysisEpochID: ownerEpoch.id, label: "slot-0")
        let rivalToken = MeetingBackendSpeakerToken(analysisEpochID: rivalEpoch.id, label: "slot-0")
        for epoch in [ownerEpoch, rivalEpoch] {
            original.diarizerFactory.segmentsByEpoch[epoch.id] = [.init(slotIndex: 0, start: 0, end: 12)]
        }
        original.voiceProfiles = [ownerToken, rivalToken].map { .init(token: $0, embeddings: [embedding, embedding]) }
        original.asrSession.responses = (0..<2).map { _ in
            .init(text: "speech", words: [.init(text: "speech", start: 0.5, end: 1)])
        }
        let initial = try await backend.execute(plan: plan, manifest: manifest, progress: { _ in })
        guard case let .canonicalEvidence(initialBundle) = initial else {
            return XCTFail("Expected canonical result", file: file, line: line)
        }
        XCTAssertTrue(initialBundle.confirmedLocalUserTokens.isEmpty, "Both complete candidates are ambiguous", file: file, line: line)
        XCTAssertEqual(original.voiceSampleCalls.count, 1, file: file, line: line)
        XCTAssertEqual(original.voiceSampleCalls.first?.map(\.clipFrames), [[80_000, 80_000], [80_000, 80_000]],
                       file: file, line: line)
        if let optionalReadDefect {
            materializer.optionalReadDefects[rivalEpoch.id] = optionalReadDefect
        } else {
            materializer.failingEpochs = [rivalEpoch.id]
        }
        session.processingAttempts = []
        let resumed = FakeRuntime(); resumed.ownerVoiceProfileSnapshot = owner
        resumed.voiceProfiles = [.init(token: ownerToken, embeddings: [embedding, embedding])]
        let retry = self.makeBackend(runtime: resumed, materializer: materializer, locator: locator)
        let retryPlan = try retry.plan(self.makeRequest(session: session, directory: directory, configuration: configuration))
        let result = try await retry.execute(plan: retryPlan,
            manifest: self.makeManifest(plan: retryPlan, observations: observations), progress: { _ in })
        guard case let .canonicalEvidence(bundle) = result else {
            return XCTFail("Expected canonical retry result", file: file, line: line)
        }
        XCTAssertTrue(bundle.confirmedLocalUserTokens.isEmpty,
                      "Missing competitor evidence cannot manufacture a unique owner", file: file, line: line)
        XCTAssertTrue(resumed.voiceSampleCalls.isEmpty,
                      "V4 must abstain before scoring an incomplete competitor set", file: file, line: line)
        XCTAssertTrue(resumed.diarizerFactory.createdEpochs.isEmpty,
                      "Surviving complete tracks reuse their independently pinned diarization", file: file, line: line)
        XCTAssertTrue(resumed.asrSession.callSampleCounts.isEmpty,
                      "Completed native ASR remains reusable despite incomplete optional identity evidence", file: file, line: line)
        let surviving = bundle.evidence.units.filter { $0.trackID == ownerTrack.id }
        XCTAssertEqual(surviving.map(\.text), ["speech"], file: file, line: line)
        XCTAssertEqual(surviving.map(\.speaker), [.assigned(ownerToken)], file: file, line: line)
        XCTAssertEqual(surviving.map(\.analysisStart), [0.5], file: file, line: line)
        if optionalReadDefect != nil {
            XCTAssertEqual(bundle.evidence.units.map(\.text), initialBundle.evidence.units.map(\.text),
                           "Optional owner reread failure cannot discard anonymous ASR", file: file, line: line)
            XCTAssertEqual(bundle.evidence.units.map(\.trackID), initialBundle.evidence.units.map(\.trackID), file: file, line: line)
            XCTAssertEqual(bundle.evidence.units.map(\.analysisStart), initialBundle.evidence.units.map(\.analysisStart), file: file, line: line)
            XCTAssertEqual(bundle.evidence.units.map(\.analysisEnd), initialBundle.evidence.units.map(\.analysisEnd), file: file, line: line)
            XCTAssertEqual(bundle.evidence.units.map(\.speaker), initialBundle.evidence.units.map(\.speaker), file: file, line: line)
            XCTAssertEqual(bundle.evidence.speakerActivity, initialBundle.evidence.speakerActivity,
                           "Optional owner reread failure cannot discard anonymous diarization", file: file, line: line)
        } else {
            XCTAssertEqual(bundle.evidence.units.count, 1, file: file, line: line)
        }
    }

    private enum RetainedOwnerRetryEvidence {
        case ambiguous, ownerAndDistantRival, missingProfiles, encoderFailure
        case missingRival, duplicateRival, invalidRival, foreignRival
    }

    /// The real backend/verifier operate on generated non-silent PCM. Only inference output
    /// is faked: a mature owner and a shorter eligible scoring rival share the same pinned
    /// physical input on retry. No checkpoint format, model or private profile is fabricated.
    private func assertRetainedOwnerRetry(
        fingerprint: String, initialRivalMatchesOwner: Bool, retryEvidence: RetainedOwnerRetryEvidence,
        expectedInitialOwner: Bool, expectedRetryOwner: Bool, expectedRetryEncoderCalls: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let chunk = self.makePCMChunk(sequence: 0, start: 100, end: 120)
        let track = self.makeMicTrack(chunks: [chunk], eraStart: 100)
        var session = self.makeSession(mode: .inRoom, tracks: [track])
        session.speakerProcessingMode = .streaming
        let directory = try self.makeTempSessionDirectory()
        let configuration = MeetingFinalProcessingConfiguration(asrArtifactFingerprint: "synthetic-sha256",
            languageCode: "en", diarizationFingerprint: fingerprint, speakerProcessingMode: .streaming)
        let observations: [MeetingAnalysisChunkKey: MeetingChunkObservationResult] = [
            .init(trackID: track.id, chunkID: chunk.id): self.makeObserved(chunk, duration: 20),
        ]
        var ownerEmbedding = [Float](repeating: 0, count: 256); ownerEmbedding[0] = 1
        var distantEmbedding = [Float](repeating: 0, count: 256); distantEmbedding[1] = 1
        let owner = MeetingOwnerVoiceProfileSnapshot(metadata: .init(generation: UUID(), enrolledAt: Date()),
            encoderFingerprint: MeetingOwnerVoiceProfileStore.encoderFingerprint,
            embeddings: [ownerEmbedding, ownerEmbedding])
        let locator = StubModelLocator(artifact: .init(
            packageURL: URL(fileURLWithPath: "/tmp/synthetic-fast128.nemotronbundle"),
            totalByteCount: 1, fileCount: 1, manifestSHA256: "synthetic", entryMetadataSHA256: "synthetic",
            profile: .experimentalFast128FP16CPU))
        let original = FakeRuntime(), materializer = FakeMaterializer()
        materializer.sampleAmplitude = 0.1; materializer.alternatingSamplePolarity = true
        original.ownerVoiceProfileSnapshot = owner
        let backend = self.makeBackend(runtime: original, materializer: materializer, locator: locator)
        let plan = try backend.plan(self.makeRequest(session: session, directory: directory, configuration: configuration))
        let manifest = try self.makeManifest(plan: plan, observations: observations)
        let epoch = try XCTUnwrap(manifest.track(track.id)?.epochs.first, file: file, line: line)
        let ownerToken = MeetingBackendSpeakerToken(analysisEpochID: epoch.id, label: "slot-0")
        let rivalToken = MeetingBackendSpeakerToken(analysisEpochID: epoch.id, label: "slot-1")
        func profiles(rivalMatchesOwner: Bool) -> [MeetingSpeakerVoiceProfile] {
            let rival = rivalMatchesOwner ? ownerEmbedding : distantEmbedding
            return [.init(token: ownerToken, embeddings: [ownerEmbedding, ownerEmbedding]),
                    .init(token: rivalToken, embeddings: [rival, rival])]
        }
        original.diarizerFactory.segmentsByEpoch[epoch.id] = [
            .init(slotIndex: 0, start: 0, end: 12), .init(slotIndex: 1, start: 12, end: 20),
        ]
        original.voiceProfiles = profiles(rivalMatchesOwner: initialRivalMatchesOwner)
        original.asrSession.responses = [.init(text: "first second", words: [
            .init(text: "first", start: 0.5, end: 1), .init(text: "second", start: 12.5, end: 13),
        ])]
        let initial = try await backend.execute(plan: plan, manifest: manifest, progress: { _ in })
        guard case let .canonicalEvidence(initialBundle) = initial else {
            return XCTFail("Expected canonical result", file: file, line: line)
        }
        XCTAssertEqual(initialBundle.confirmedLocalUserTokens, expectedInitialOwner ? [ownerToken] : [], file: file, line: line)
        XCTAssertEqual(original.voiceSampleCalls.count, 1, file: file, line: line)
        let encodedInputs = try XCTUnwrap(original.voiceSampleCalls.first, file: file, line: line)
        XCTAssertEqual(encodedInputs.first { $0.token == ownerToken }?.clipFrames, [80_000, 80_000], file: file, line: line)
        let rivalFrames = try XCTUnwrap(encodedInputs.first { $0.token == rivalToken }?.clipFrames, file: file, line: line)
        XCTAssertEqual(rivalFrames.count, 2, file: file, line: line)
        XCTAssertTrue(rivalFrames.allSatisfy { (48_000..<80_000).contains($0) },
                      "Short rivals must still reach scoring before full-winner eligibility", file: file, line: line)

        session.processingAttempts = []
        let resumed = FakeRuntime(); resumed.ownerVoiceProfileSnapshot = owner
        switch retryEvidence {
        case .ambiguous: resumed.voiceProfiles = profiles(rivalMatchesOwner: true)
        case .ownerAndDistantRival: resumed.voiceProfiles = profiles(rivalMatchesOwner: false)
        case .missingProfiles: resumed.voiceProfiles = []
        case .encoderFailure: resumed.voiceError = MeetingOwnerVoiceProfileError.invalidAudio
        case .missingRival: resumed.voiceProfiles = Array(profiles(rivalMatchesOwner: true).prefix(1))
        case .duplicateRival:
            resumed.voiceProfiles = profiles(rivalMatchesOwner: true)
            resumed.voiceProfiles.append(resumed.voiceProfiles[1])
        case .invalidRival:
            resumed.voiceProfiles = [profiles(rivalMatchesOwner: true)[0], .init(token: rivalToken, embeddings: [[0]])]
        case .foreignRival:
            resumed.voiceProfiles = [profiles(rivalMatchesOwner: true)[0],
                .init(token: .init(analysisEpochID: epoch.id, label: "foreign"), embeddings: [ownerEmbedding, ownerEmbedding])]
        }
        let retry = self.makeBackend(runtime: resumed, materializer: materializer, locator: locator)
        let retryRequest = self.makeRequest(session: session, directory: directory, configuration: configuration)
        let retryPlan = try retry.plan(retryRequest)
        let result = try await retry.execute(plan: retryPlan,
            manifest: self.makeManifest(plan: retryPlan, observations: observations), progress: { _ in })
        guard case let .canonicalEvidence(bundle) = result else {
            return XCTFail("Expected canonical retry result", file: file, line: line)
        }
        XCTAssertNotEqual(retryRequest.attemptID, plan.attemptID, file: file, line: line)
        XCTAssertEqual(bundle.confirmedLocalUserTokens, expectedRetryOwner ? [ownerToken] : [], file: file, line: line)
        XCTAssertEqual(resumed.voiceSampleCalls.count, expectedRetryEncoderCalls, file: file, line: line)
        if expectedRetryEncoderCalls > 0 {
            XCTAssertEqual(resumed.voiceSampleCalls, original.voiceSampleCalls,
                           "V4 recollects the same actual excerpts with the complete competitor set", file: file, line: line)
        }
        XCTAssertTrue(resumed.diarizerFactory.createdEpochs.isEmpty,
                      "Independently pinned completed diarization must remain reusable", file: file, line: line)
        XCTAssertTrue(resumed.asrSession.callSampleCounts.isEmpty,
                      "Completed native ASR must not repeat for owner re-verification", file: file, line: line)
        XCTAssertEqual(bundle.evidence.units.map(\.text), initialBundle.evidence.units.map(\.text), file: file, line: line)
        XCTAssertEqual(bundle.evidence.units.map(\.analysisStart), initialBundle.evidence.units.map(\.analysisStart), file: file, line: line)
        XCTAssertEqual(bundle.evidence.speakerActivity, initialBundle.evidence.speakerActivity, file: file, line: line)
    }

    func testShortenedTrackCannotInheritCachedOwnerConfirmationFromReassignedSlot() async throws {
        let firstChunk = self.makePCMChunk(sequence: 0, start: 100, end: 108)
        let secondChunk = self.makePCMChunk(sequence: 1, start: 111, end: 119)
        let track = self.makeMicTrack(chunks: [firstChunk, secondChunk], eraStart: 100)
        var session = self.makeSession(mode: .inRoom, tracks: [track])
        let directory = try self.makeTempSessionDirectory()
        let configuration = MeetingFinalProcessingConfiguration(asrArtifactFingerprint: "synthetic-sha256", languageCode: "en")
        let observations: [MeetingAnalysisChunkKey: MeetingChunkObservationResult] = [
            .init(trackID: track.id, chunkID: firstChunk.id): self.makeObserved(firstChunk, duration: 8),
            .init(trackID: track.id, chunkID: secondChunk.id): self.makeObserved(secondChunk, duration: 8),
        ]
        var embedding = [Float](repeating: 0, count: 256); embedding[0] = 1
        let owner = MeetingOwnerVoiceProfileSnapshot(metadata: .init(generation: UUID(), enrolledAt: Date()),
            encoderFingerprint: MeetingOwnerVoiceProfileStore.encoderFingerprint, embeddings: [embedding, embedding])
        let original = FakeRuntime(), materializer = FakeMaterializer()
        materializer.sampleAmplitude = 0.1
        original.ownerVoiceProfileSnapshot = owner
        let backend = self.makeBackend(runtime: original, materializer: materializer)
        let plan = try backend.plan(self.makeRequest(session: session, directory: directory, configuration: configuration))
        let manifest = try self.makeManifest(plan: plan, observations: observations)
        let epochs = try XCTUnwrap(manifest.track(track.id)?.epochs)
        XCTAssertEqual(epochs.count, 2)
        original.diarizerFactory.segmentsByEpoch[epochs[0].id] = [
            .init(slotIndex: 0, start: 0, end: 8),
            .init(slotIndex: 0, start: 8.5, end: 12.5), .init(slotIndex: 1, start: 12.5, end: 16.5),
        ]
        original.voiceProfiles = [.init(token: .init(analysisEpochID: epochs[0].id, label: "slot-0"),
                                        embeddings: [embedding, embedding])]
        original.asrSession.responses = [
            .init(text: "owner", words: [.init(text: "owner", start: 0.5, end: 1)]),
            .init(text: "other", words: [.init(text: "other", start: 6, end: 6.5)]),
        ]
        let initial = try await backend.execute(plan: plan, manifest: manifest, progress: { _ in })
        guard case let .canonicalEvidence(initialBundle) = initial else { return XCTFail("Expected canonical result") }
        let formerlyOwnedSlot = MeetingBackendSpeakerToken(analysisEpochID: epochs[1].id, label: "slot-0")
        XCTAssertTrue(initialBundle.confirmedLocalUserTokens.contains(formerlyOwnedSlot), "The full original stream confirmed this slot as the owner")

        // Simulate termination before the coordinator's completed-session save, then a
        // transient read failure for the first epoch. The shortened stream swaps the slots.
        session.processingAttempts = []
        materializer.failingEpochs = [epochs[0].id]
        let resumed = FakeRuntime(); resumed.ownerVoiceProfileSnapshot = owner
        resumed.diarizerFactory.segmentsByEpoch[epochs[1].id] = [
            .init(slotIndex: 1, start: 0, end: 4), .init(slotIndex: 0, start: 4, end: 8),
        ]
        let retry = self.makeBackend(runtime: resumed, materializer: materializer)
        let retryPlan = try retry.plan(self.makeRequest(session: session, directory: directory, configuration: configuration))
        let result = try await retry.execute(plan: retryPlan,
            manifest: self.makeManifest(plan: retryPlan, observations: observations), progress: { _ in })
        guard case let .canonicalEvidence(bundle) = result else { return XCTFail("Expected canonical result") }
        let other = try XCTUnwrap(bundle.evidence.units.first { $0.text == "other" })
        XCTAssertEqual(other.speaker, .assigned(formerlyOwnedSlot), "The raw slot label can be reused for a different voice")
        XCTAssertFalse(bundle.confirmedLocalUserTokens.contains(formerlyOwnedSlot), "A freshly assigned slot cannot inherit cached owner identity")
        XCTAssertTrue(bundle.confirmedLocalUserTokens.isEmpty)
        XCTAssertEqual(resumed.diarizerFactory.createdEpochs, [epochs[1].id])
        XCTAssertTrue(resumed.asrSession.callSampleCounts.isEmpty, "Verified native ASR cores remain reusable independently of speaker identity")
    }

    func testTransientMissingEpochCannotCacheShortenedContinuousTrack() async throws {
        let fixture = self.makeTwoEpochFixture()
        let directory = try self.makeTempSessionDirectory()
        let pinnedASR = MeetingFinalProcessingConfiguration(asrArtifactFingerprint: "synthetic-sha256", languageCode: "en")
        let initial = FakeRuntime(), materializer = FakeMaterializer()
        let firstBackend = self.makeBackend(runtime: initial, materializer: materializer)
        let firstPlan = try firstBackend.plan(self.makeRequest(session: fixture.session, directory: directory, configuration: pinnedASR))
        let firstManifest = try self.makeManifest(plan: firstPlan, observations: fixture.observations)
        let epochs = try XCTUnwrap(firstManifest.track(fixture.micTrack.id)?.epochs)
        materializer.failingEpochs = [epochs[1].id]
        initial.diarizerFactory.segmentsByEpoch[epochs[0].id] = [.init(slotIndex: 0, start: 0, end: 2)]
        initial.asrSession.responses = [
            .init(text: "first", words: [.init(text: "first", start: 0.2, end: 0.4)]),
            .init(text: "remote", words: [.init(text: "remote", start: 0.2, end: 0.4)]),
        ]
        _ = try await firstBackend.execute(plan: firstPlan, manifest: firstManifest, progress: { _ in })
        materializer.failingEpochs = []
        let resumed = FakeRuntime()
        resumed.diarizerFactory.segmentsByEpoch[epochs[0].id] = [
            .init(slotIndex: 0, start: 0, end: 2), .init(slotIndex: 1, start: 2.5, end: 4.5),
        ]
        resumed.asrSession.responses = [.init(text: "second", words: [.init(text: "second", start: 0.2, end: 0.4)])]
        let secondBackend = self.makeBackend(runtime: resumed, materializer: materializer)
        let secondPlan = try secondBackend.plan(self.makeRequest(session: fixture.session, directory: directory, configuration: pinnedASR))
        let result = try await secondBackend.execute(plan: secondPlan,
            manifest: self.makeManifest(plan: secondPlan, observations: fixture.observations), progress: { _ in })
        guard case let .canonicalEvidence(bundle) = result else { return XCTFail("Expected canonical result") }
        XCTAssertEqual(resumed.diarizerFactory.createdEpochs, [epochs[0].id], "The shortened first track was not a valid complete-track checkpoint")
        XCTAssertEqual(resumed.asrSession.callSampleCounts.count, 1, "Already completed epoch ASR still resumes without repetition")
        let second = try XCTUnwrap(bundle.evidence.units.first { $0.text == "second" })
        XCTAssertEqual(second.speaker, .assigned(.init(analysisEpochID: epochs[1].id, label: "slot-1")))
    }

    private func plannedManifest(
        fixture: TwoEpochFixture,
        runtime: FakeRuntime,
        materializer: FakeMaterializer = FakeMaterializer()
    ) async throws -> (backend: MeetingParakeetNemotronBackend, plan: MeetingBackendPlan, manifest: MeetingAnalysisManifest) {
        let directory = try self.makeTempSessionDirectory()
        let backend = self.makeBackend(runtime: runtime, materializer: materializer)
        let plan = try backend.plan(self.makeRequest(session: fixture.session, directory: directory))
        let manifest = try self.makeManifest(plan: plan, observations: fixture.observations)
        return (backend, plan, manifest)
    }

    private func executeComposite(
        fixture: TwoEpochFixture,
        runtime: FakeRuntime,
        materializer: FakeMaterializer = FakeMaterializer()
    ) async throws -> (bundle: MeetingCanonicalResultBundle, manifest: MeetingAnalysisManifest, plan: MeetingBackendPlan) {
        let (backend, plan, manifest) = try await self.plannedManifest(
            fixture: fixture, runtime: runtime, materializer: materializer
        )
        let outcome = try await backend.execute(plan: plan, manifest: manifest, progress: { _ in })
        guard case let .canonicalEvidence(bundle) = outcome else {
            XCTFail("composite must return canonical evidence")
            throw MeetingBackendError.outcomeContractMismatch(backend: .parakeetNemotron, declared: .canonicalEvidence)
        }
        return (bundle, manifest, plan)
    }

    func testOneDiarizerStatePerTrackKeepsSlotsAcrossEpochs() async throws {
        let fixture = self.makeTwoEpochFixture()
        let runtime = FakeRuntime()
        runtime.voiceError = NSError(domain: "voice-model-test", code: 1)
        let (backend, plan, manifest) = try await self.plannedManifest(fixture: fixture, runtime: runtime)
        let micEpochs = try XCTUnwrap(manifest.track(fixture.micTrack.id)?.epochs)
        let appEpochs = try XCTUnwrap(manifest.track(fixture.appTrack.id)?.epochs)
        XCTAssertEqual(micEpochs.count, 2, "the 3-second chunk gap must reset the mic epoch")
        XCTAssertEqual(appEpochs.count, 1)

        // One stream per track: mic epoch 0 (2 s), 0.5 s of joining silence, mic epoch 1 (2 s).
        runtime.diarizerFactory.segmentsByEpoch = [
            micEpochs[0].id: [
                MeetingNemotronSpeakerSegment(slotIndex: 0, start: 0.2, end: 1.0),
                MeetingNemotronSpeakerSegment(slotIndex: 0, start: 2.5, end: 3.5),
            ],
            appEpochs[0].id: [MeetingNemotronSpeakerSegment(slotIndex: 0, start: 0.0, end: 2.0)],
        ]
        runtime.asrSession.responses = [
            .init(text: "hello", words: [ASRWordTiming(text: "hello", start: 0.3, end: 0.6)]),
            .init(text: "world", words: [ASRWordTiming(text: "world", start: 0.1, end: 0.5)]),
            .init(text: "remote", words: [ASRWordTiming(text: "remote", start: 0.5, end: 1.0)]),
        ]
        let outcome = try await backend.execute(plan: plan, manifest: manifest, progress: { _ in })
        guard case let .canonicalEvidence(bundle) = outcome else {
            XCTFail("composite must return canonical evidence")
            throw MeetingBackendError.outcomeContractMismatch(backend: .parakeetNemotron, declared: .canonicalEvidence)
        }

        XCTAssertEqual(
            runtime.diarizerFactory.createdEpochs,
            [micEpochs[0].id, appEpochs[0].id],
            "one diarizer state per track, keyed by its first epoch"
        )
        XCTAssertEqual(
            runtime.diarizerFactory.diarizedSampleCounts,
            [2 * 16_000 + 8000 + 2 * 16_000, 2 * 16_000],
            "a track's epochs are diarized as one stream joined by 0.5 s of silence"
        )
        XCTAssertEqual(runtime.diarizationScopeCount, 1, "one Nemotron residency per attempt")
        XCTAssertEqual(runtime.asrAttemptIDs.count, 1, "the voice encoder is not needed and never runs")
        XCTAssertEqual(runtime.asrSession.callSampleCounts.count, 3)
        XCTAssertTrue(bundle.coverageReceipts.allSatisfy { $0.status == .processed })

        let unitsByText = Dictionary(bundle.evidence.units.map { ($0.text, $0) }, uniquingKeysWith: { first, _ in first })
        guard case let .assigned(helloToken) = try XCTUnwrap(unitsByText["hello"]).speaker,
              case let .assigned(worldToken) = try XCTUnwrap(unitsByText["world"]).speaker,
              case let .assigned(remoteToken) = try XCTUnwrap(unitsByText["remote"]).speaker
        else {
            return XCTFail("every word overlaps one slot")
        }
        XCTAssertEqual(helloToken, .init(analysisEpochID: micEpochs[0].id, label: "slot-0"))
        XCTAssertEqual(
            worldToken,
            .init(analysisEpochID: micEpochs[1].id, label: "slot-0"),
            "a segment after the join maps back into the second epoch's own time"
        )
        XCTAssertEqual(remoteToken, .init(analysisEpochID: appEpochs[0].id, label: "slot-0"))
        XCTAssertTrue(bundle.evidence.speakerSlotsContinueAcrossEpochs)
        XCTAssertTrue(bundle.evidence.voiceProfiles.isEmpty)

        let verdicts = try await MeetingTextOverlapEchoVerdictProvider().echoVerdicts(
            for: bundle.evidence,
            manifest: manifest,
            plan: plan
        )
        let assembled = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: bundle.evidence,
            coverageReceipts: bundle.coverageReceipts,
            echoVerdicts: verdicts
        ))
        let speakerByText = Dictionary(
            assembled.segments.map { ($0.text, $0.speakerID) }, uniquingKeysWith: { first, _ in first }
        )
        XCTAssertNotNil(speakerByText["hello"] ?? nil)
        XCTAssertEqual(speakerByText["hello"], speakerByText["world"], "the same voice keeps one name across the reset")
        XCTAssertNotEqual(speakerByText["hello"], speakerByText["remote"], "tracks never merge")
        XCTAssertEqual(assembled.speakers.filter { $0.trackKind == .microphone }.count, 1)
        XCTAssertEqual(assembled.speakers.filter { $0.trackKind == .applicationAudio }.count, 1)
        XCTAssertEqual(assembled.sidecar.speakerIdentityLinks.count, 1)
    }

    func testASRPaddingPreservesInputAndDoesNotInventEmptyAudio() {
        let short: [Float] = [0.25, -0.5, 0.75]
        let padded = MeetingParakeetNemotronBackend.asrInput(short)
        XCTAssertEqual(Array(padded.prefix(short.count)), short)
        XCTAssertEqual(padded.count, 16_000)
        XCTAssertTrue(padded.dropFirst(short.count).allSatisfy { $0 == 0 })
        XCTAssertEqual(short, [0.25, -0.5, 0.75])
        XCTAssertTrue(MeetingParakeetNemotronBackend.asrInput([]).isEmpty)
        for count in [16_000, 16_001] {
            let input = [Float](repeating: 0.25, count: count)
            XCTAssertEqual(MeetingParakeetNemotronBackend.asrInput(input), input)
        }
    }

    func testWordsEntirelyInPaddingDoNotReturnAsUntimedText() async throws {
        let duration = 0.05
        let chunk = self.makePCMChunk(sequence: 0, start: 100, end: 100 + duration)
        let track = self.makeMicTrack(chunks: [chunk], eraStart: 100)
        let session = self.makeSession(mode: .inRoom, tracks: [track])
        let runtime = FakeRuntime()
        runtime.asrSession.minimumSampleCount = 16_000
        runtime.asrSession.responses = [
            .init(text: "phantom word", words: [
                ASRWordTiming(text: "phantom", start: 0.6, end: 0.7),
                ASRWordTiming(text: "word", start: 0.7, end: 0.8),
            ]),
        ]
        let backend = self.makeBackend(runtime: runtime, materializer: FakeMaterializer())
        let plan = try backend.plan(self.makeRequest(session: session, directory: self.makeTempSessionDirectory()))
        let manifest = try self.makeManifest(plan: plan, observations: [
            MeetingAnalysisChunkKey(trackID: track.id, chunkID: chunk.id): self.makeObserved(chunk, duration: duration),
        ])
        let outcome = try await backend.execute(plan: plan, manifest: manifest, progress: { _ in })
        guard case let .canonicalEvidence(bundle) = outcome else { return XCTFail("Expected canonical evidence") }
        XCTAssertEqual(runtime.asrSession.callSampleCounts, [16_000])
        XCTAssertTrue(bundle.coverageReceipts.allSatisfy { $0.status == .processed })
        XCTAssertTrue(bundle.evidence.units.isEmpty, "Rejected timed words must never be reintroduced as a whole-clip utterance")
    }

    func testSubsecondEpochPadsInferenceWithoutExtendingTranscriptCoverage() async throws {
        let duration = 0.05
        let chunk = self.makePCMChunk(sequence: 0, start: 100, end: 100 + duration)
        let track = self.makeMicTrack(chunks: [chunk], eraStart: 100)
        let session = self.makeSession(mode: .inRoom, tracks: [track])
        let runtime = FakeRuntime()
        runtime.asrSession.minimumSampleCount = 16_000
        runtime.asrSession.responses = [
            .init(text: "short padding", words: [
                ASRWordTiming(text: "short", start: 0.005, end: 0.035),
                ASRWordTiming(text: "padding", start: 0.6, end: 0.7),
            ]),
        ]
        let backend = self.makeBackend(runtime: runtime, materializer: FakeMaterializer())
        let plan = try backend.plan(self.makeRequest(session: session, directory: self.makeTempSessionDirectory()))
        let manifest = try self.makeManifest(plan: plan, observations: [
            MeetingAnalysisChunkKey(trackID: track.id, chunkID: chunk.id): self.makeObserved(chunk, duration: duration),
        ])
        let outcome = try await backend.execute(plan: plan, manifest: manifest, progress: { _ in })
        guard case let .canonicalEvidence(bundle) = outcome else { return XCTFail("Expected canonical evidence") }
        XCTAssertEqual(runtime.asrSession.callSampleCounts, [16_000])
        XCTAssertTrue(bundle.coverageReceipts.allSatisfy { $0.status == .processed })
        XCTAssertEqual(bundle.evidence.units.map(\.text), ["short"])
        XCTAssertTrue(bundle.coverageReceipts.allSatisfy { $0.analysisEnd <= 0.050_001 })
    }

    func testPCMFirstEpochMaterializesOnceForBothModelPhases() async throws {
        let chunk = self.makePCMChunk(sequence: 0, start: 100, end: 101)
        let track = self.makeMicTrack(chunks: [chunk], eraStart: 100)
        let session = self.makeSession(mode: .inRoom, tracks: [track])
        let runtime = FakeRuntime()
        let materializer = FakeMaterializer()
        let backend = self.makeBackend(runtime: runtime, materializer: materializer)
        let plan = try backend.plan(self.makeRequest(
            session: session,
            directory: self.makeTempSessionDirectory()
        ))
        let manifest = try self.makeManifest(plan: plan, observations: [
            MeetingAnalysisChunkKey(trackID: track.id, chunkID: chunk.id): self.makeObserved(chunk, duration: 1),
        ])
        let epoch = try XCTUnwrap(manifest.track(track.id)?.epochs.first)
        runtime.diarizerFactory.segmentsByEpoch[epoch.id] = [
            MeetingNemotronSpeakerSegment(slotIndex: 0, start: 0.1, end: 0.4),
        ]
        runtime.asrSession.responses = [
            .init(text: "pcm", words: [ASRWordTiming(text: "pcm", start: 0.2, end: 0.3)]),
        ]
        let outcome = try await backend.execute(plan: plan, manifest: manifest, progress: { _ in })
        guard case let .canonicalEvidence(bundle) = outcome else {
            return XCTFail("composite must return canonical evidence")
        }
        XCTAssertEqual(materializer.materializedEpochs, [epoch.id], "PCM is materialized once and shared")
        XCTAssertEqual(runtime.asrSession.callSampleCounts, [16_000])
        XCTAssertEqual(bundle.evidence.units.map(\.text), ["pcm"])
    }

    func testRecordedEpochPreservesNativeUtteranceTimesAndSpeakerTransition() async throws {
        let chunk = self.makeChunk(sequence: 0, start: 100, end: 104)
        let track = self.makeMicTrack(chunks: [chunk], eraStart: 100)
        let session = self.makeSession(mode: .inRoom, tracks: [track])
        let runtime = FakeRuntime()
        let backend = self.makeBackend(runtime: runtime)
        let plan = try backend.plan(self.makeRequest(session: session, directory: self.makeTempSessionDirectory()))
        let manifest = try self.makeManifest(plan: plan, observations: [
            MeetingAnalysisChunkKey(trackID: track.id, chunkID: chunk.id): self.makeObserved(chunk, duration: 4)
        ])
        let epoch = try XCTUnwrap(manifest.track(track.id)?.epochs.first)
        runtime.diarizerFactory.segmentsByEpoch[epoch.id] = [
            .init(slotIndex: 0, start: 0, end: 2), .init(slotIndex: 1, start: 2, end: 4)
        ]
        runtime.asrSession.responses = [.init(text: "Первая фраза. Second phrase.", words: [], segmentTimings: [
            .init(text: "Первая фраза.", start: 0.2, end: 1.8), .init(text: " Second phrase.", start: 2.1, end: 3.8)
        ])]
        let outcome = try await backend.execute(plan: plan, manifest: manifest, progress: { _ in })
        guard case let .canonicalEvidence(bundle) = outcome else { return XCTFail("Expected canonical evidence") }
        XCTAssertEqual(bundle.evidence.units.map(\.text), ["Первая фраза.", "Second phrase."])
        XCTAssertEqual(bundle.evidence.units.map(\.precision), [.utterance, .utterance])
        XCTAssertEqual(bundle.evidence.units.map(\.analysisStart), [epoch.analysisInterval.start + 0.2, epoch.analysisInterval.start + 2.1])
        XCTAssertEqual(bundle.evidence.units.map(\.analysisEnd), [epoch.analysisInterval.start + 1.8, epoch.analysisInterval.start + 3.8])
        XCTAssertEqual(bundle.evidence.units.map(\.speaker), [
            .assigned(.init(analysisEpochID: epoch.id, label: "slot-0")),
            .assigned(.init(analysisEpochID: epoch.id, label: "slot-1"))
        ])
        XCTAssertTrue(bundle.evidence.units.allSatisfy { !$0.analysisSpanIDs.isEmpty })
        XCTAssertTrue(bundle.coverageReceipts.allSatisfy { $0.status == .processed })
    }

    func testWordSlotAmbiguityAndUnassigned() async throws {
        let chunk = self.makeChunk(sequence: 0, start: 100, end: 104)
        let track = self.makeMicTrack(chunks: [chunk], eraStart: 100)
        let session = self.makeSession(mode: .inRoom, tracks: [track])
        let directory = try self.makeTempSessionDirectory()
        let runtime = FakeRuntime()
        let backend = self.makeBackend(runtime: runtime)
        let request = self.makeRequest(session: session, directory: directory)
        let plan = try backend.plan(request)
        let manifest = try self.makeManifest(
            plan: plan,
            observations: [MeetingAnalysisChunkKey(trackID: track.id, chunkID: chunk.id): self.makeObserved(chunk, duration: 4)]
        )
        let epoch = try XCTUnwrap(manifest.track(track.id)?.epochs.first)
        runtime.diarizerFactory.segmentsByEpoch = [
            epoch.id: [
                MeetingNemotronSpeakerSegment(slotIndex: 0, start: 0.0, end: 2.0),
                MeetingNemotronSpeakerSegment(slotIndex: 1, start: 1.0, end: 3.0),
            ],
        ]
        runtime.asrSession.responses = [
            .init(text: "a b c", words: [
                ASRWordTiming(text: "a", start: 0.2, end: 0.6),
                ASRWordTiming(text: "b", start: 1.2, end: 1.6),
                ASRWordTiming(text: "c", start: 3.2, end: 3.6),
            ]),
        ]

        let outcome = try await backend.execute(plan: plan, manifest: manifest, progress: { _ in })
        guard case let .canonicalEvidence(bundle) = outcome else {
            return XCTFail("composite must return canonical evidence")
        }
        let unitsByText = Dictionary(bundle.evidence.units.map { ($0.text, $0) }, uniquingKeysWith: { first, _ in first })

        guard case let .assigned(tokenA) = try XCTUnwrap(unitsByText["a"]).speaker else {
            return XCTFail("word a overlaps only slot 0")
        }
        XCTAssertEqual(tokenA.label, "slot-0")

        guard case let .ambiguous(tokensB) = try XCTUnwrap(unitsByText["b"]).speaker else {
            return XCTFail("Raw backend evidence must preserve two voices without a context guess")
        }
        XCTAssertEqual(tokensB.map(\.label), ["slot-0", "slot-1"])

        guard case .unassigned = try XCTUnwrap(unitsByText["c"]).speaker else {
            return XCTFail("word c overlaps no activity")
        }

        // Presentation may resolve only through the shared audited policy; native ambiguity remains.
        let assembly = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: bundle.evidence,
            coverageReceipts: bundle.coverageReceipts,
            speakerAttributionPolicy: .init(enableProvisionalSpeakerIdentities: true)
        ))
        XCTAssertEqual(assembly.segments.map(\.text), ["a", "b"])
        XCTAssertEqual(assembly.speakers.count, 2, "The ambiguous fragment gets its own preliminary reading identity")
        XCTAssertEqual(assembly.segments[1].speakerIdentityIsProvisional, true)
        XCTAssertNotEqual(assembly.segments[0].speakerID, assembly.segments[1].speakerID)
        let resolved = try XCTUnwrap(assembly.sidecar.dispositions.first { $0.unitID == unitsByText["b"]?.id })
        XCTAssertEqual(resolved.disposition, .ambiguousUnassigned)
        let outside = try XCTUnwrap(assembly.sidecar.dispositions.first { $0.unitID == unitsByText["c"]?.id })
        XCTAssertEqual(outside.disposition, .outsideActivity)
    }

    /// These are the actual final-word/previous-word times returned by TDT and Nemotron for
    /// eight Samantha/Daniel sentences plus a saved meeting endpoint with Float32 rounding.
    func testKnownSentenceEndingsSurviveBackendAssemblyAndTurnMerge() async throws {
        let timings: [(anchor: Double, start: Double, end: Double, activityEnd: Double)] = [
            (1.20, 1.52, 2.16, 1.4_399_999_380_111_694),
            (1.28, 1.60, 2.24, 1.5_199_999_809_265_137),
            (1.04, 1.36, 2.00, 1.2_799_999_713_897_705),
            (1.12, 1.44, 2.08, 1.3_600_000_143_051_147),
            (1.28, 1.60, 2.00, 1.6_799_999_475_479_126),
            (1.44, 1.76, 2.80, 1.7_599_999_904_632_568),
            (1.20, 1.52, 2.16, 1.4_399_999_380_111_694),
            (1.20, 1.52, 2.16, 1.4_399_999_380_111_694),
            (18.96, 19.28, 19.60, 19.19_999_885_559_082),
        ]
        for (kind, mode) in [
            (MeetingAudioTrackKind.microphone, MeetingCaptureMode.inRoom),
            (.microphone, .onlineCall), (.applicationAudio, .onlineCall),
        ] {
            for timing in timings {
                let duration = max(4, timing.end + 1)
                let chunk = self.makeChunk(sequence: 0, start: 0, end: duration)
                let track = kind == .microphone
                    ? self.makeMicTrack(chunks: [chunk], eraStart: 0)
                    : self.makeAppTrack(chunks: [chunk])
                let session = self.makeSession(mode: mode, tracks: [track])
                let runtime = FakeRuntime()
                let backend = self.makeBackend(runtime: runtime, materializer: FakeMaterializer())
                let plan = try backend.plan(self.makeRequest(
                    session: session, directory: self.makeTempSessionDirectory()
                ))
                let manifest = try self.makeManifest(plan: plan, observations: [
                    MeetingAnalysisChunkKey(trackID: track.id, chunkID: chunk.id): self.makeObserved(chunk, duration: duration),
                ])
                let epoch = try XCTUnwrap(manifest.track(track.id)?.epochs.first)
                runtime.diarizerFactory.segmentsByEpoch = [epoch.id: [
                    MeetingNemotronSpeakerSegment(slotIndex: 0, start: 0, end: timing.activityEnd),
                ]]
                runtime.asrSession.responses = [.init(text: "been there?", words: [
                    ASRWordTiming(text: "been", start: timing.anchor, end: timing.start),
                    ASRWordTiming(text: "there?", start: timing.start, end: timing.end),
                ])]
                let outcome = try await backend.execute(plan: plan, manifest: manifest, progress: { _ in })
                guard case let .canonicalEvidence(bundle) = outcome else { return XCTFail("missing evidence") }
                let verdicts = try await MeetingTextOverlapEchoVerdictProvider().echoVerdicts(
                    for: bundle.evidence, manifest: manifest, plan: plan
                )
                let result = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
                    plan: plan,
                    manifest: manifest,
                    evidence: bundle.evidence,
                    coverageReceipts: bundle.coverageReceipts,
                    echoVerdicts: verdicts
                ))
                XCTAssertEqual(result.segments.map(\.text), ["been", "there?"])
                XCTAssertEqual(result.segments.first?.attributionState, .assigned)
                let tail = try XCTUnwrap(bundle.evidence.units.last)
                let expectedNative: MeetingBackendSpeakerAssignment = timing.activityEnd - timing.start
                    > MeetingAnalysisManifestSchema.mappingToleranceSeconds
                    ? .assigned(.init(analysisEpochID: epoch.id, label: "slot-0")) : .unassigned
                XCTAssertEqual(tail.speaker, expectedNative,
                    "An ending with direct acoustic overlap stays assigned; boundary retention does not invent evidence")
                XCTAssertEqual(result.segments.last?.nativeSpeakerAssignment, tail.speaker)
                XCTAssertEqual(result.sidecar.dispositions.map(\.disposition), [.emitted, .emitted])
                XCTAssertEqual(tail.analysisStart, timing.start, accuracy: 0.000_001)
                XCTAssertEqual(tail.analysisEnd, timing.end, accuracy: 0.000_001)
                let merged = MeetingProcessingPipeline.mergeCanonicalSegments(result.segments)
                XCTAssertEqual(merged.map(\.text), ["been", "there?"])
                XCTAssertEqual(merged.map(\.id), result.segments.map(\.id))
            }
        }
    }

    func testNearbyCompetingVoiceKeepsRecoveredEndingUnknown() async throws {
        let chunk = self.makeChunk(sequence: 0, start: 0, end: 4)
        let track = self.makeMicTrack(chunks: [chunk], eraStart: 0)
        let runtime = FakeRuntime()
        let backend = self.makeBackend(runtime: runtime)
        let plan = try backend.plan(self.makeRequest(
            session: self.makeSession(mode: .inRoom, tracks: [track]),
            directory: self.makeTempSessionDirectory()
        ))
        let manifest = try self.makeManifest(plan: plan, observations: [
            MeetingAnalysisChunkKey(trackID: track.id, chunkID: chunk.id): self.makeObserved(chunk, duration: 4),
        ])
        let epoch = try XCTUnwrap(manifest.track(track.id)?.epochs.first)
        runtime.diarizerFactory.segmentsByEpoch = [epoch.id: [
            MeetingNemotronSpeakerSegment(slotIndex: 0, start: 0, end: 1.44),
            MeetingNemotronSpeakerSegment(slotIndex: 1, start: 1.47, end: 1.50),
        ]]
        runtime.asrSession.responses = [.init(text: "been there?", words: [
            ASRWordTiming(text: "been", start: 1.2, end: 1.52),
            ASRWordTiming(text: "there?", start: 1.52, end: 2.16),
        ])]
        let outcome = try await backend.execute(plan: plan, manifest: manifest, progress: { _ in })
        guard case let .canonicalEvidence(bundle) = outcome else { return XCTFail("missing evidence") }
        XCTAssertEqual(bundle.evidence.units.last?.speaker, .unassigned)
        let result = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: bundle.evidence,
            coverageReceipts: bundle.coverageReceipts
        ))
        XCTAssertEqual(result.segments.map(\.text), ["been", "there?"])
        XCTAssertNotNil(result.segments.first?.speakerID)
        XCTAssertEqual(result.segments.last?.nativeSpeakerAssignment, .unassigned,
            "Readable context must not manufacture an acoustic assignment for the competing tail")
    }

    func testCoverageUnionDoesNotDoubleCountDuplicateSpeakerIntervals() {
        let (slot0, slot1) = self.attributionTokens()
        let activity = [
            MeetingBackendSpeakerActivity(token: slot0, start: 0, end: 0.4),
            MeetingBackendSpeakerActivity(token: slot0, start: 0, end: 0.4),
            MeetingBackendSpeakerActivity(token: slot1, start: 0, end: 0.1),
        ]

        guard case let .ambiguous(tokens) = MeetingParakeetNemotronBackend.assignment(
            start: 0, end: 1, activity: activity, allowDominance: true
        ) else { return XCTFail("unioned 40% versus 10% coverage must not become an 80% dominant assignment") }
        XCTAssertEqual(tokens.map(\.label), ["slot-0", "slot-1"])
    }

    func testShortMaterialCandidatesSurviveSilentEnvelopePadding() {
        let (slot0, slot1) = self.attributionTokens()
        let decision = MeetingParakeetNemotronBackend.assignment(
            start: 0,
            end: 1,
            activity: [
                MeetingBackendSpeakerActivity(token: slot0, start: 0, end: 0.08),
                MeetingBackendSpeakerActivity(token: slot1, start: 0.92, end: 1),
            ],
            allowDominance: true
        )
        guard case .ambiguous = decision else { return XCTFail("Silence must not raise the candidate support threshold") }
    }

    func testSoleAboveFloorCandidateAssigns() {
        let (slot0, slot1) = self.attributionTokens()
        let decision = MeetingParakeetNemotronBackend.assignment(
            start: 0,
            end: 1,
            activity: [
                MeetingBackendSpeakerActivity(token: slot0, start: 0, end: 0.2),
                MeetingBackendSpeakerActivity(token: slot1, start: 0.96, end: 1),
            ],
            allowDominance: true
        )
        guard case let .assigned(token) = decision else { return XCTFail("the sole significant speaker must assign") }
        XCTAssertEqual(token, slot0)
    }

    func testShortWordDoesNotDiscardEightyMillisecondRunnerUp() {
        let (slot0, slot1) = self.attributionTokens()
        let decision = MeetingParakeetNemotronBackend.assignment(
            start: 0,
            end: 0.15,
            activity: [
                MeetingBackendSpeakerActivity(token: slot0, start: 0, end: 0.15),
                MeetingBackendSpeakerActivity(token: slot1, start: 0.07, end: 0.15),
            ],
            allowDominance: true
        )
        guard case let .ambiguous(tokens) = decision else {
            return XCTFail("80ms is material evidence inside a 150ms word")
        }
        XCTAssertEqual(tokens.map(\.label), ["slot-0", "slot-1"])
    }

    func testSixtyFortyAndFullOverlapRemainAmbiguousWithDeterministicOrder() {
        let (slot0, slot1) = self.attributionTokens()
        for activity in [
            [
                MeetingBackendSpeakerActivity(token: slot0, start: 0, end: 0.6),
                MeetingBackendSpeakerActivity(token: slot1, start: 0.6, end: 1),
            ],
            [
                MeetingBackendSpeakerActivity(token: slot1, start: 0, end: 1),
                MeetingBackendSpeakerActivity(token: slot0, start: 0, end: 1),
            ],
        ] {
            guard case let .ambiguous(tokens) = MeetingParakeetNemotronBackend.assignment(
                start: 0, end: 1, activity: activity, allowDominance: true
            ) else { return XCTFail("material two-speaker coverage must remain ambiguous") }
            XCTAssertEqual(tokens.map(\.label), ["slot-0", "slot-1"])
        }
    }

    func testClearLeaderAndExactDominanceBoundaryAssign() {
        let (slot0, slot1) = self.attributionTokens()
        for leaderEnd in [0.8, 0.5] {
            let runnerEnd = leaderEnd == 0.5 ? 0.1 : 0.15
            let decision = MeetingParakeetNemotronBackend.assignment(
                start: 0,
                end: 1,
                activity: [
                    MeetingBackendSpeakerActivity(token: slot0, start: 0, end: leaderEnd),
                    MeetingBackendSpeakerActivity(token: slot1, start: 0, end: runnerEnd),
                ],
                allowDominance: true
            )
            guard case let .assigned(token) = decision else {
                return XCTFail("coverage at or beyond every named dominance boundary must assign")
            }
            XCTAssertEqual(token, slot0)
        }
    }

    func testClearPluralityBelowHalfRemainsConservativelyAmbiguous() {
        let (slot0, slot1) = self.attributionTokens()
        let decision = MeetingParakeetNemotronBackend.assignment(
            start: 0,
            end: 1,
            activity: [
                MeetingBackendSpeakerActivity(token: slot0, start: 0, end: 0.45),
                MeetingBackendSpeakerActivity(token: slot1, start: 0, end: 0.10),
            ],
            allowDominance: true
        )
        guard case let .ambiguous(tokens) = decision else {
            return XCTFail("a plurality below the explicit 50% coverage floor must not become confident")
        }
        XCTAssertEqual(tokens.map(\.label), ["slot-0", "slot-1"])
    }

    func testUtteranceFallbackNeverUsesDominanceAcrossTwoSignificantSpeakers() {
        let (slot0, slot1) = self.attributionTokens()
        let decision = MeetingParakeetNemotronBackend.assignment(
            start: 0,
            end: 1,
            activity: [
                MeetingBackendSpeakerActivity(token: slot0, start: 0, end: 0.8),
                MeetingBackendSpeakerActivity(token: slot1, start: 0, end: 0.15),
            ],
            allowDominance: false
        )
        guard case let .ambiguous(tokens) = decision else {
            return XCTFail("epoch-covering utterance timing is too coarse for dominance")
        }
        XCTAssertEqual(tokens.map(\.label), ["slot-0", "slot-1"])
    }

    func testPCMRawAssignmentsNeverCascadeInferredHandoffAnchors() throws {
        let (slot0, slot1) = self.attributionTokens()
        let units = try MeetingParakeetNemotronBackend.pcmUnits(
            result: .init(text: "first mixed another"),
            words: [.init(text: "first", start: 0, end: 0.5),
                    .init(text: "mixed", start: 1, end: 1.4),
                    .init(text: "another", start: 1.4, end: 1.8)],
            epoch: slot0.analysisEpochID, duration: 2,
            activity: [.init(token: slot0, start: 0, end: 2), .init(token: slot1, start: 1, end: 2)],
            identityTokens: [slot0, slot1])
        XCTAssertEqual(units[0].speaker, .assigned(slot0))
        XCTAssertEqual(units[1].speaker, .ambiguous([slot0, slot1]))
        XCTAssertEqual(units[2].speaker, .ambiguous([slot0, slot1]))
    }

    func testAcousticDecisionIsInvariantWhenOnlySilenceExtendsWordEnvelope() {
        let (slot0, slot1) = self.attributionTokens()
        let activity: [MeetingBackendSpeakerActivity] = [
            .init(token: slot0, start: 0, end: 0.3), .init(token: slot1, start: 0.2, end: 0.3)]
        let decisions = [0.4, 0.6, 0.8].map {
            MeetingParakeetNemotronBackend.assignment(start: 0, end: $0, activity: activity, allowDominance: true)
        }
        XCTAssertTrue(decisions.allSatisfy { $0 == decisions[0] })
        XCTAssertEqual(decisions[0], .ambiguous([slot0, slot1]))
    }

    func testPCMIndexedBatchPreserves8192NativeWordsAndHonorsFrozenPolicy() throws {
        let (first, second) = self.attributionTokens()
        let count = 8_192
        var words: [ASRWordTiming] = []
        words.reserveCapacity(count)
        for index in 0..<count {
            let start = Double(index * 2)
            let end = start + 1
            words.append(ASRWordTiming(text: "native-\(index)", start: start, end: end))
        }
        var activity: [MeetingBackendSpeakerActivity] = []
        activity.reserveCapacity(count * 2)
        for index in 0..<count {
            let start = Double(index * 2)
            let boundary = start + 1
            let end = start + 2
            activity.append(MeetingBackendSpeakerActivity(token: first, start: start, end: boundary))
            activity.append(MeetingBackendSpeakerActivity(token: second, start: boundary, end: end))
        }
        let units = try MeetingParakeetNemotronBackend.pcmUnits(result: .init(text: "Native words"),
            words: words, epoch: first.analysisEpochID, duration: Double(count * 2),
            activity: activity, identityTokens: [first, second])
        XCTAssertEqual(units.count, count)
        XCTAssertEqual(units.map(\.text), words.map(\.text))
        XCTAssertEqual(units.map(\.analysisStart), words.map(\.start))
        XCTAssertEqual(units.map(\.analysisEnd), words.map(\.end))
        XCTAssertEqual(Set(units.map(\.id)).count, count)
        XCTAssertTrue(units.allSatisfy { $0.precision == .word && $0.speaker == .assigned(first) })
        let mixedActivity: [MeetingBackendSpeakerActivity] = [
            .init(token: first, start: 0, end: 1), .init(token: second, start: 0.2, end: 0.3)]
        func classify(_ policy: MeetingSpeakerAttributionPolicy) throws -> MeetingBackendSpeakerAssignment {
            try XCTUnwrap(MeetingParakeetNemotronBackend.pcmUnits(result: .init(text: "word"),
                words: [.init(text: "word", start: 0, end: 1)], epoch: first.analysisEpochID,
                duration: 1, activity: mixedActivity, identityTokens: [first, second],
                speakerAttributionPolicy: policy).first?.speaker)
        }
        XCTAssertEqual(try classify(.standard), .assigned(first))
        XCTAssertEqual(try classify(.init(enableDominance: false)), .ambiguous([first, second]))
    }

    private func attributionTokens() -> (MeetingBackendSpeakerToken, MeetingBackendSpeakerToken) {
        let epoch = MeetingAnalysisEpochID(trackID: UUID(), ordinal: 0)
        return (
            MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "slot-0"),
            MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "slot-1")
        )
    }

    func testProviderAndDiarizerTimesMapThroughActualSpanSampleRanges() async throws {
        let chunk0 = self.makeChunk(sequence: 0, start: 100, end: 101, path: "tracks/microphone/chunk_0.caf")
        let chunk1 = self.makeChunk(sequence: 1, start: 101, end: 102, path: "tracks/microphone/chunk_1.caf")
        let track = self.makeMicTrack(chunks: [chunk0, chunk1], eraStart: 100)
        let session = self.makeSession(mode: .inRoom, tracks: [track])
        let runtime = FakeRuntime()
        let materializer = FakeMaterializer()
        let backend = self.makeBackend(runtime: runtime, materializer: materializer)
        let plan = try backend.plan(self.makeRequest(
            session: session,
            directory: self.makeTempSessionDirectory()
        ))
        let manifest = try self.makeManifest(plan: plan, observations: [
            MeetingAnalysisChunkKey(trackID: track.id, chunkID: chunk0.id): self.makeObserved(chunk0, duration: 1),
            MeetingAnalysisChunkKey(trackID: track.id, chunkID: chunk1.id): self.makeObserved(chunk1, duration: 1),
        ])
        let trackManifest = try XCTUnwrap(manifest.track(track.id))
        let epoch = try XCTUnwrap(trackManifest.epochs.first)
        XCTAssertEqual(epoch.spanIDs.count, 2)

        // Deliberately make the first one-second manifest span occupy only 0.5 seconds of the
        // materialized buffer. A local time of 0.6 seconds must therefore map into span 2.
        materializer.customSpanSampleCounts[epoch.id] = [8000, 16_000]
        runtime.diarizerFactory.segmentsByEpoch[epoch.id] = [
            MeetingNemotronSpeakerSegment(slotIndex: 3, start: 0.55, end: 0.75),
        ]
        runtime.asrSession.responses = [
            .init(text: "mapped", words: [ASRWordTiming(text: "mapped", start: 0.6, end: 0.7)]),
        ]

        let outcome = try await backend.execute(plan: plan, manifest: manifest, progress: { _ in })
        guard case let .canonicalEvidence(bundle) = outcome else {
            return XCTFail("composite must return canonical evidence")
        }
        let unit = try XCTUnwrap(bundle.evidence.units.first)
        XCTAssertEqual(unit.analysisStart, 1.1, accuracy: 1e-6)
        XCTAssertEqual(unit.analysisEnd, 1.2, accuracy: 1e-6)
        XCTAssertEqual(unit.analysisSpanIDs, [epoch.spanIDs[1]])
        guard case let .assigned(token) = unit.speaker else {
            return XCTFail("mapped diarizer activity should assign the word")
        }
        XCTAssertEqual(token.label, "slot-3")
    }

    // MARK: - Receipts and partial failure

    func testEpochFailureMarksItsSpansFailedAndContinues() async throws {
        let fixture = self.makeTwoEpochFixture()
        let runtime = FakeRuntime()
        runtime.diarizerFactory.segmentsByEpoch = [:]
        runtime.asrSession.responses = [
            .init(text: "fine", words: [ASRWordTiming(text: "fine", start: 0.2, end: 0.4)]),
            .init(text: "ignored", words: [ASRWordTiming(text: "ignored", start: 0.2, end: 0.4)]),
            .init(text: "remote", words: [ASRWordTiming(text: "remote", start: 0.2, end: 0.4)]),
        ]
        runtime.asrSession.failingCallIndices = [1]

        let (bundle, manifest, plan) = try await self.executeComposite(fixture: fixture, runtime: runtime)
        let micEpochs = try XCTUnwrap(manifest.track(fixture.micTrack.id)?.epochs)
        let appEpochs = try XCTUnwrap(manifest.track(fixture.appTrack.id)?.epochs)

        let receiptsBySpan = Dictionary(
            bundle.coverageReceipts.map { ($0.spanID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        XCTAssertEqual(bundle.coverageReceipts.count, manifest.allSpans.count, "every admissible span is tiled")
        for span in manifest.allSpans {
            let receipt = try XCTUnwrap(receiptsBySpan[span.id])
            XCTAssertEqual(receipt.analysisStart, span.analysisInterval.start, accuracy: 1e-9)
            XCTAssertEqual(receipt.analysisEnd, span.analysisInterval.end, accuracy: 1e-9)
            if span.analysisEpochID == micEpochs[1].id {
                XCTAssertEqual(receipt.status, .failed)
                XCTAssertEqual(receipt.reasonCode, "asrFailed")
            } else {
                XCTAssertEqual(receipt.status, .processed)
            }
        }
        XCTAssertEqual(Set(bundle.evidence.units.map(\.analysisEpochID)), [micEpochs[0].id, appEpochs[0].id])

        // The partial bundle still assembles; the failed epoch becomes visible coverage gaps.
        let verdicts = try await MeetingTextOverlapEchoVerdictProvider().echoVerdicts(
            for: bundle.evidence,
            manifest: manifest,
            plan: plan
        )
        let assembly = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: bundle.evidence,
            coverageReceipts: bundle.coverageReceipts,
            echoVerdicts: verdicts
        ))
        XCTAssertFalse(assembly.isComplete)
        XCTAssertEqual(assembly.coverageGaps.filter { $0.reason == .processingFailed }.count, 1)
    }

    func testDiarizationFailureSkipsASRForThatTrackOnly() async throws {
        let fixture = self.makeTwoEpochFixture()
        let runtime = FakeRuntime()
        let directory = try self.makeTempSessionDirectory()
        let backend = self.makeBackend(runtime: runtime)
        let request = self.makeRequest(session: fixture.session, directory: directory)
        let plan = try backend.plan(request)
        let manifest = try self.makeManifest(plan: plan, observations: fixture.observations)
        let micEpochs = try XCTUnwrap(manifest.track(fixture.micTrack.id)?.epochs)
        // The mic track is one diarizer stream, so its failure covers both of its epochs.
        runtime.diarizerFactory.failingEpochs = [micEpochs[0].id]
        runtime.asrSession.responses = [
            .init(text: "remote", words: [ASRWordTiming(text: "remote", start: 0.1, end: 0.3)]),
        ]

        let outcome = try await backend.execute(plan: plan, manifest: manifest, progress: { _ in })
        guard case let .canonicalEvidence(bundle) = outcome else {
            return XCTFail("composite must return canonical evidence")
        }
        XCTAssertEqual(runtime.asrSession.callSampleCounts.count, 1, "only the healthy track is transcribed")
        let failedReceipts = bundle.coverageReceipts.filter { $0.status == .failed }
        XCTAssertEqual(Set(failedReceipts.map(\.spanID)), Set(micEpochs.flatMap(\.spanIDs)))
        XCTAssertTrue(failedReceipts.allSatisfy { $0.reasonCode == "diarizationFailed" })
        XCTAssertEqual(Set(bundle.evidence.units.map(\.text)), ["remote"])
    }

    // MARK: - Utterance fallback

    func testTextWithoutWordTimingsEmitsOneEpochCoveringUtterance() async throws {
        let chunk = self.makeChunk(sequence: 0, start: 100, end: 103)
        let track = self.makeMicTrack(chunks: [chunk], eraStart: 100)
        let session = self.makeSession(mode: .inRoom, tracks: [track])
        let directory = try self.makeTempSessionDirectory()
        let runtime = FakeRuntime()
        let backend = self.makeBackend(runtime: runtime)
        let request = self.makeRequest(session: session, directory: directory)
        let plan = try backend.plan(request)
        let manifest = try self.makeManifest(
            plan: plan,
            observations: [MeetingAnalysisChunkKey(trackID: track.id, chunkID: chunk.id): self.makeObserved(chunk, duration: 3)]
        )
        let epoch = try XCTUnwrap(manifest.track(track.id)?.epochs.first)
        runtime.diarizerFactory.segmentsByEpoch = [
            epoch.id: [MeetingNemotronSpeakerSegment(slotIndex: 2, start: 0.0, end: 3.0)],
        ]
        runtime.asrSession.responses = [.init(text: "hello there", words: [])]

        let outcome = try await backend.execute(plan: plan, manifest: manifest, progress: { _ in })
        guard case let .canonicalEvidence(bundle) = outcome else {
            return XCTFail("composite must return canonical evidence")
        }
        let unit = try XCTUnwrap(bundle.evidence.units.first)
        XCTAssertEqual(bundle.evidence.units.count, 1)
        XCTAssertEqual(unit.precision, .utterance)
        XCTAssertEqual(unit.analysisStart, epoch.analysisInterval.start, accuracy: 1e-9)
        XCTAssertEqual(unit.analysisEnd, epoch.analysisInterval.end, accuracy: 1e-9)
        XCTAssertEqual(unit.analysisSpanIDs, epoch.spanIDs)
        guard case let .assigned(token) = unit.speaker else {
            return XCTFail("the epoch-covering utterance takes the epoch's activity")
        }
        XCTAssertEqual(token.label, "slot-2")

        // Assembly accepts it as-is: no synthetic words exist.
        _ = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: bundle.evidence,
            coverageReceipts: bundle.coverageReceipts
        ))
    }

    func testProcessedEpochWithNoTextIsValid() async throws {
        let fixture = self.makeTwoEpochFixture()
        let runtime = FakeRuntime()
        runtime.asrSession.responses = [
            .init(text: "  ", words: []), .init(text: "", words: []), .init(text: "", words: []),
        ]
        let (bundle, manifest, _) = try await self.executeComposite(fixture: fixture, runtime: runtime)
        XCTAssertTrue(bundle.evidence.units.isEmpty)
        XCTAssertEqual(bundle.coverageReceipts.count, manifest.allSpans.count)
        XCTAssertTrue(bundle.coverageReceipts.allSatisfy { $0.status == .processed })
    }

    // MARK: - Cancellation

    func testCancellationPropagatesOutOfExecute() async throws {
        let fixture = self.makeTwoEpochFixture()
        let runtime = FakeRuntime()
        let latch = Latch()
        runtime.asrSession.latch = latch
        let entered = LockedFlag()
        runtime.asrSession.onCall = { entered.set() }

        let directory = try self.makeTempSessionDirectory()
        let backend = self.makeBackend(runtime: runtime)
        let request = self.makeRequest(session: fixture.session, directory: directory)
        let plan = try backend.plan(request)
        let manifest = try self.makeManifest(plan: plan, observations: fixture.observations)

        let task = Task { @MainActor in
            try await backend.execute(plan: plan, manifest: manifest, progress: { _ in })
        }
        let deadline = Date().addingTimeInterval(5)
        while !entered.value, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(entered.value, "the ASR phase must have started")
        task.cancel()
        await latch.open()
        await XCTAssertAsyncThrowsError(try await task.value) { error in
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
    }

    func testProviderCancellationIsNotAFailedReceipt() async throws {
        let fixture = self.makeTwoEpochFixture()
        let runtime = FakeRuntime()
        runtime.asrSession.responses = [
            .init(text: "fine", words: [ASRWordTiming(text: "fine", start: 0.2, end: 0.4)]),
        ]
        runtime.asrSession.cancellationCallIndices = [1]

        let directory = try self.makeTempSessionDirectory()
        let backend = self.makeBackend(runtime: runtime)
        let request = self.makeRequest(session: fixture.session, directory: directory)
        let plan = try backend.plan(request)
        let manifest = try self.makeManifest(plan: plan, observations: fixture.observations)
        await XCTAssertAsyncThrowsError(
            try await backend.execute(plan: plan, manifest: manifest, progress: { _ in })
        ) { error in
            XCTAssertTrue(error is CancellationError, "cancellation propagates; got \(error)")
        }
    }

    // MARK: - Helpers
}

// MARK: - Fakes

private actor Latch {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if self.isOpen { return }
        await withCheckedContinuation { self.waiters.append($0) }
    }

    func open() {
        self.isOpen = true
        let parked = self.waiters
        self.waiters.removeAll()
        for continuation in parked {
            continuation.resume()
        }
    }
}

private final nonisolated class FakeDiarizerFactory: MeetingNemotronDiarizerFactory, @unchecked Sendable {
    struct Session: MeetingNemotronDiarizerSession {
        let factory: FakeDiarizerFactory
        let segments: [MeetingNemotronSpeakerSegment]
        func diarize(source: any MeetingPCMReplaySource) async throws -> [MeetingNemotronSpeakerSegment] {
            var total = 0
            try await source.replay { total += $0.count }
            self.factory.diarizedSampleCounts.append(total)
            return self.segments
        }
        func diarize(samples: [Float]) async throws -> [MeetingNemotronSpeakerSegment] {
            self.factory.diarizedSampleCounts.append(samples.count)
            return self.segments
        }
    }

    var segmentsByEpoch: [MeetingAnalysisEpochID: [MeetingNemotronSpeakerSegment]] = [:]
    var failingEpochs: Set<MeetingAnalysisEpochID> = []
    private(set) var createdEpochs: [MeetingAnalysisEpochID] = []
    private(set) var diarizedSampleCounts: [Int] = []

    func makeDiarizer(epoch: MeetingAnalysisEpochID) async throws -> any MeetingNemotronDiarizerSession {
        self.createdEpochs.append(epoch)
        if self.failingEpochs.contains(epoch) {
            throw MeetingEpochMaterializationError.unreadable(spanID: "fake-diarizer-failure")
        }
        return Session(factory: self, segments: self.segmentsByEpoch[epoch] ?? [])
    }
}

private final nonisolated class FakeASRSession: MeetingParakeetASRSession, @unchecked Sendable {
    struct Response {
        let text: String
        let words: [ASRWordTiming]
        var segmentTimings: [ASRSegmentTiming] = []
    }

    var responses: [Response] = []
    var failingCallIndices: Set<Int> = []
    var minimumSampleCount = 0
    var cancellationCallIndices: Set<Int> = []
    var latch: Latch?
    var onCall: (() -> Void)?
    private(set) var callSampleCounts: [Int] = []

    func transcribeWithTimings(
        _ samples: [Float]
    ) async throws -> (result: ASRTranscriptionResult, words: [ASRWordTiming]) {
        let index = self.callSampleCounts.count
        self.callSampleCounts.append(samples.count)
        self.onCall?()
        if let latch { await latch.wait() }
        if self.cancellationCallIndices.contains(index) { throw CancellationError() }
        if self.failingCallIndices.contains(index) || samples.count < self.minimumSampleCount {
            throw MeetingEpochMaterializationError.unreadable(spanID: "fake-asr-failure")
        }
        let response = index < self.responses.count ? self.responses[index] : Response(text: "", words: [])
        return (ASRTranscriptionResult(text: response.text, segmentTimings: response.segmentTimings), response.words)
    }
}

private final nonisolated class FakeRuntime: MeetingParakeetNemotronRunning, @unchecked Sendable {
    nonisolated struct VoiceSampleInput: Equatable, Sendable {
        let token: MeetingBackendSpeakerToken
        let clipFrames: [Int]
    }
    let diarizerFactory = FakeDiarizerFactory()
    let asrSession = FakeASRSession()
    var voiceProfiles: [MeetingSpeakerVoiceProfile] = []
    var voiceError: Error?
    var ownerVoiceProfileSnapshot: MeetingOwnerVoiceProfileSnapshot?
    private(set) var diarizationScopeCount = 0
    private(set) var asrAttemptIDs: [UUID] = []
    private(set) var asrConfigurations: [MeetingFinalProcessingConfiguration] = []
    private(set) var voiceSampleCalls: [[VoiceSampleInput]] = []

    func speakerVoiceProfiles(samples: [MeetingSpeakerVoiceSamples]) async throws -> [MeetingSpeakerVoiceProfile] {
        self.voiceSampleCalls.append(samples.map { .init(token: $0.token, clipFrames: $0.clips.map(\.count)) })
        if let voiceError { throw voiceError }
        return self.voiceProfiles
    }

    func withNemotronDiarization(
        artifact _: MeetingNemotronModelArtifact,
        _ body: nonisolated(nonsending) @escaping @Sendable (any MeetingNemotronDiarizerFactory) async throws -> MeetingNemotronPhaseResult
    ) async throws -> MeetingNemotronPhaseResult {
        self.diarizationScopeCount += 1
        return try await body(self.diarizerFactory)
    }

    func withPreparedASR(
        attemptID: UUID,
        configuration: MeetingFinalProcessingConfiguration,
        body: nonisolated(nonsending) @escaping @Sendable (any MeetingParakeetASRSession) async throws -> MeetingParakeetPhaseResult
    ) async throws -> MeetingParakeetPhaseResult {
        self.asrAttemptIDs.append(attemptID)
        self.asrConfigurations.append(configuration)
        return try await body(self.asrSession)
    }
}

private final nonisolated class FakeMaterializer: MeetingEpochAudioMaterializing, @unchecked Sendable {
    nonisolated enum OptionalReadDefect: Sendable { case unreadable, truncated, nonFinite }
    var failingEpochs: Set<MeetingAnalysisEpochID> = []
    var optionalReadDefects: [MeetingAnalysisEpochID: OptionalReadDefect] = [:]
    var customSpanSampleCounts: [MeetingAnalysisEpochID: [Int]] = [:]
    var replaySampleCounts: [MeetingAnalysisEpochID: Int] = [:]
    var sampleAmplitude: Float = 0
    var alternatingSamplePolarity = false
    private(set) var maximumReplayRead = 0

    struct GeneratedSource: MeetingPCMReplaySource {
        let totalSampleCount: Int
        let owner: FakeMaterializer
        func readSamples(in range: Range<Int>) async throws -> [Float] {
            try Task.checkCancellation()
            guard range.lowerBound >= 0, range.upperBound <= self.totalSampleCount,
                  range.count <= 24 * 16_000 else { throw MeetingParakeetNemotronRuntimeError.invalidPCMWindow }
            self.owner.maximumReplayRead = max(self.owner.maximumReplayRead, range.count)
            return [Float](repeating: 0.1, count: range.count)
        }
    }

    func makeReplay(epoch: MeetingAnalysisEpochRecord, track: MeetingAnalysisTrackManifest,
                    manifest: MeetingAnalysisManifest, sessionDirectory: URL) async throws -> MeetingEpochAudioReplay {
        if let count = self.replaySampleCounts[epoch.id] {
            return .init(source: GeneratedSource(totalSampleCount: count, owner: self), sampleRate: 16_000,
                         spanSamples: [.init(spanID: epoch.spanIDs[0], sampleRange: 0..<count)])
        }
        let value = try await self.materialize(epoch: epoch, track: track, manifest: manifest, sessionDirectory: sessionDirectory)
        return .init(source: SmallSource(samples: value.samples, optionalReadDefect: self.optionalReadDefects[epoch.id]),
                     sampleRate: value.sampleRate, spanSamples: value.spanSamples)
    }

    struct SmallSource: MeetingPCMReplaySource {
        let samples: [Float]
        let optionalReadDefect: OptionalReadDefect?
        var totalSampleCount: Int { self.samples.count }
        func readSamples(in range: Range<Int>) async throws -> [Float] {
            // Diarizer/ASR replay starts on whole-second boundaries. Clean owner excerpts
            // start after 160ms edge exclusion, providing a model-free optional reread seam.
            if range.lowerBound % 16_000 != 0, let optionalReadDefect {
                switch optionalReadDefect {
                case .unreadable: throw MeetingParakeetNemotronRuntimeError.invalidPCMWindow
                case .truncated: return []
                case .nonFinite: return [Float](repeating: .nan, count: range.count)
                }
            }
            return Array(self.samples[range])
        }
    }

    private(set) var materializedEpochs: [MeetingAnalysisEpochID] = []

    func materialize(
        epoch: MeetingAnalysisEpochRecord,
        track: MeetingAnalysisTrackManifest,
        manifest _: MeetingAnalysisManifest,
        sessionDirectory _: URL
    ) async throws -> MeetingMaterializedEpoch {
        self.materializedEpochs.append(epoch.id)
        if self.failingEpochs.contains(epoch.id) {
            throw MeetingEpochMaterializationError.unreadable(spanID: epoch.spanIDs.first ?? "?")
        }
        var cursor = 0
        var ranges: [MeetingMaterializedSpanSamples] = []
        for (index, spanID) in epoch.spanIDs.enumerated() {
            guard let span = track.spans.first(where: { $0.id == spanID }) else { continue }
            let count: Int
            if let configured = self.customSpanSampleCounts[epoch.id], configured.indices.contains(index) {
                count = max(1, configured[index])
            } else {
                count = max(1, Int((span.analysisInterval.duration * 16_000).rounded()))
            }
            ranges.append(MeetingMaterializedSpanSamples(spanID: spanID, sampleRange: cursor..<(cursor + count)))
            cursor += count
        }
        return MeetingMaterializedEpoch(
            epochID: epoch.id,
            samples: self.alternatingSamplePolarity
                ? (0..<cursor).map { $0 % 320 < 160 ? self.sampleAmplitude : -self.sampleAmplitude }
                : [Float](repeating: self.sampleAmplitude, count: cursor),
            sampleRate: 16_000,
            spanSamples: ranges
        )
    }
}

private final nonisolated class StubModelLocator: MeetingNemotronModelLocating, @unchecked Sendable {
    var error: (any Error)?
    private let selectedArtifact: MeetingNemotronModelArtifact
    static let artifact = MeetingNemotronModelArtifact(
        packageURL: URL(fileURLWithPath: "/tmp/stub-nemotron.mlpackage"),
        totalByteCount: 1,
        fileCount: 1,
        manifestSHA256: "stub",
        entryMetadataSHA256: "stub"
    )

    init(error: (any Error)? = nil, artifact: MeetingNemotronModelArtifact = StubModelLocator.artifact) {
        self.error = error
        self.selectedArtifact = artifact
    }

    func locate() throws -> MeetingNemotronModelArtifact {
        if let error { throw error }
        return self.selectedArtifact
    }

    func recheck(_ artifact: MeetingNemotronModelArtifact) throws -> MeetingNemotronModelArtifact {
        if let error { throw error }
        return artifact
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool {
        self.lock.withLock { self.flag }
    }

    func set() {
        self.lock.withLock { self.flag = true }
    }
}

/// Small async assert helper so throwing closures read like XCTAssertThrowsError.
private func XCTAssertAsyncThrowsError<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error to be thrown. \(message)", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

// The transport, stream controller, protected attribution state and final pipeline are real.
// Only native ASR/diarization and application resource participants are synthetic here.
@MainActor
extension MeetingParakeetNemotronBackendTests {
    func testInRoomStreamingUsesMeasuredCoverageAcrossAResumedSource() async throws {
        let fixture = try self.onlinePipelineFixture(service: OnlinePipelineService(), runtime: OnlinePipelineRuntime(), mode: .inRoom)
        fixture.publication.collectBatches = true
        let track = fixture.session.audioTracks[0]
        let consumer = try await fixture.pipeline.memoryConsumer(for: fixture.session.id, track: track, eventHandler: { _ in })
        for index in 0..<8 {
            let frame = 600 * 16_000 + index * 8_000 + (index >= 4 ? 3 * 16_000 : 0)
            XCTAssertTrue(consumer.enqueue(try Self.onlinePCM(frames: 8_000, startFrame: frame)))
        }
        try await consumer.finish()
        let coverage = fixture.publication.receivedBatches.flatMap(\.protectedSourceIntervals)
        XCTAssertFalse(coverage.isEmpty)
        XCTAssertTrue(coverage.allSatisfy { $0.upperBound <= 2 + 0.000_001 || $0.lowerBound >= 5 - 0.000_001 })
        XCTAssertEqual(try XCTUnwrap(coverage.last?.upperBound), 7, accuracy: 0.000_001)
        XCTAssertTrue(try XCTUnwrap(fixture.attempt.sourceTimelines[track.id]).hasGaps)
    }

    func testProtectedIntervalPublicationContinuesAfterGapsForBothSources() async throws {
        let fixture = try self.onlinePipelineFixture(service: OnlinePipelineService(), runtime: OnlinePipelineRuntime())
        fixture.publication.collectBatches = true
        defer { fixture.publication.beforeApply = nil }
        for track in fixture.session.audioTracks {
            let timeline = try MeetingPCMSourceTimeline(originSeconds: 100)
            try timeline.record(sourceStartSample: 0, frameCount: 16_000, presentationTime: 110)
            try timeline.record(sourceStartSample: 16_000, frameCount: 16_000, presentationTime: 113)
            fixture.attempt.sourceTimelines[track.id] = timeline
        }
        for track in fixture.session.audioTracks {
            var first = MeetingPCMTranscriptBatch(segments: [])
            first.sourceTrack = track
            first.protectedSourceThroughSample = 16_000
            fixture.publication.beforeApply = { batch in
                XCTAssertEqual(batch.protectedSourceIntervals, [10..<11])
                XCTAssertNil(batch.protectedSourceThroughSample)
                XCTAssertEqual(try fixture.attempt.projectedBatch(first).protectedSourceIntervals, [10..<11],
                               "A checkpoint cannot acknowledge its own source before publication joins")
            }
            try await fixture.attempt.publish(first)
            fixture.publication.beforeApply = nil
            XCTAssertTrue(try fixture.attempt.projectedBatch(first).protectedSourceIntervals.isEmpty)
            var next = first
            next.protectedSourceThroughSample = 32_000
            XCTAssertEqual(try fixture.attempt.projectedBatch(next).protectedSourceIntervals, [13..<14])
            try await fixture.attempt.publish(next)
        }
        XCTAssertEqual(fixture.publication.receivedBatches.count, 4, "Coverage-only empty ASR windows still reach the real publication boundary")
        XCTAssertTrue(fixture.publication.receivedBatches.allSatisfy { $0.segments.isEmpty })
        let encoded = String(decoding: try JSONEncoder().encode(fixture.publication.session), as: UTF8.self)
        XCTAssertFalse(encoded.contains("protectedSourceIntervals"), "Ephemeral source acknowledgement never becomes stored transcript data")
    }

    func testFailedProtectedIntervalCheckpointCanRetryTheSameMeasuredAudio() async throws {
        let fixture = try self.onlinePipelineFixture(service: OnlinePipelineService(), runtime: OnlinePipelineRuntime())
        fixture.publication.collectBatches = true
        defer { fixture.publication.beforeApply = nil }
        let track = fixture.session.audioTracks[0]
        let timeline = try MeetingPCMSourceTimeline(originSeconds: 0)
        try timeline.record(sourceStartSample: 0, frameCount: 16_000, presentationTime: 0)
        try timeline.record(sourceStartSample: 16_000, frameCount: 16_000, presentationTime: 4)
        fixture.attempt.sourceTimelines[track.id] = timeline
        var batch = MeetingPCMTranscriptBatch(segments: [])
        batch.sourceTrack = track
        batch.protectedSourceThroughSample = 32_000
        fixture.publication.beforeApply = { _ in throw CancellationError() }
        do { try await fixture.attempt.publish(batch); XCTFail("The synthetic checkpoint is cancelled") }
        catch { XCTAssertTrue(error is CancellationError) }
        fixture.publication.beforeApply = nil
        XCTAssertEqual(try fixture.attempt.projectedBatch(batch).protectedSourceIntervals, [0..<1, 4..<5])
        try await fixture.attempt.publish(batch)
        XCTAssertTrue(try fixture.attempt.projectedBatch(batch).protectedSourceIntervals.isEmpty)
        XCTAssertEqual(fixture.publication.receivedBatches.count, 1)
    }

    func testRetainedOnlineStreamingPlaybackPreservesItsPersistedClockOrigin() throws {
        let chunk = self.makePCMChunk(sequence: 0, start: 102, end: 108)
        let track = self.makeMicTrack(chunks: [chunk], eraStart: 0)
        var session = self.makeSession(mode: .onlineCall, tracks: [track])
        session.transcriptTimeDomain = .meetingRelative
        session.transcriptPresentationOrigin = .init(value: 100, timescale: 1)
        let segment = MeetingTranscriptSegment(id: UUID(), start: .init(value: 3, timescale: 1),
            end: .init(value: 4, timescale: 1), sourceTrackID: track.id, speakerID: nil,
            text: "synthetic retained words", revision: 0, status: .final, overlap: .none, completeness: .complete)
        let restored = try JSONDecoder().decode(MeetingSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(MeetingAnalysisManifest.presentationOrigin(of: restored), 100)
        let directory = try self.makeTempSessionDirectory()
        let slices = try MeetingSegmentPlaybackPlan.slices(session: restored, segment: segment, directory: directory)
        XCTAssertEqual(slices.count, 1)
        XCTAssertEqual(slices.first?.start, 1)
        XCTAssertEqual(slices.first?.end, 2)
        var legacy = restored
        legacy.transcriptPresentationOrigin = nil
        XCTAssertEqual(MeetingAnalysisManifest.presentationOrigin(of: legacy), 102,
            "Earlier stored recordings retain their original minimum-chunk clock")
    }

    func testOnlineStreamingPhysicalClockNativeEnvelopePassesTheActualStore() async throws {
        let fixture = try self.onlinePipelineFixture(service: OnlinePipelineService(), runtime: OnlinePipelineRuntime())
        let store = MeetingSessionStore(rootDirectory: fixture.directory)
        fixture.publication.persistentStore = store
        try await store.create(fixture.publication.session)
        let tracks = fixture.session.audioTracks
        let consumers = try await tracks.asyncOnlineMap { track in
            try await fixture.pipeline.memoryConsumer(for: fixture.session.id, track: track, eventHandler: { _ in })
        }
        for index in 0..<42 {
            for source in consumers.indices {
                let prefix = source == 0 ? 2 * 16_000 : 4 * 16_000
                XCTAssertTrue(consumers[source].enqueue(try Self.onlinePCM(frames: 8_000, startFrame: prefix + index * 8_000)))
            }
        }
        try await Self.onlineWait { fixture.publication.session.transcriptSegments.count >= 80 }
        async let first: Void = consumers[0].finish()
        async let second: Void = consumers[1].finish()
        _ = try await (first, second)
        let result = try await fixture.pipeline.process(session: fixture.publication.session,
            sessionDirectory: fixture.directory, progress: { _ in })
        var completed = fixture.publication.session
        completed.state = .completed
        completed.transcriptSegments = result.segments
        completed.speakers = result.speakers
        try await store.save(completed)
        let loaded = try await store.load(id: completed.id)
        let restored = try XCTUnwrap(loaded)
        XCTAssertEqual(restored.transcriptSegments.count, 84)
        for (source, track) in tracks.enumerated() {
            let words = restored.transcriptSegments.filter { $0.sourceTrackID == track.id }
            XCTAssertEqual(try XCTUnwrap(words.first?.nativeTiming?.start), source == 0 ? 2 : 4, accuracy: 0.000_001)
            for word in words {
                XCTAssertEqual(try XCTUnwrap(word.nativeTiming?.start), word.start.seconds, accuracy: 0.000_001)
                XCTAssertEqual(try XCTUnwrap(word.nativeTiming?.end), word.end.seconds, accuracy: 0.000_001)
                XCTAssertEqual(word.nativeSpeakerAssignment?.tokens.first?.analysisEpochID.trackID, track.id)
            }
        }
    }

    func testOnlineStreamingRetiresSourceSpansAfterProtectedPublication() async throws {
        let service = OnlinePipelineService(), runtime = OnlinePipelineRuntime()
        let fixture = try self.onlinePipelineFixture(service: service, runtime: runtime)
        let tracks = fixture.session.audioTracks
        let consumers = try await tracks.asyncOnlineMap { track in
            try await fixture.pipeline.memoryConsumer(for: fixture.session.id, track: track, eventHandler: { _ in })
        }
        for index in 0..<180 {
            for consumer in consumers {
                // Half a second of real samples followed by half a second without source PCM.
                XCTAssertTrue(consumer.enqueue(try Self.onlinePCM(frames: 8_000, startFrame: index * 16_000)))
            }
            if index % 20 == 19 {
                try await Self.onlineWait { fixture.publication.session.transcriptSegments.count >= (index - 1) * 2 }
            }
        }
        try await Self.onlineWait { fixture.publication.session.transcriptSegments.count >= 350 }
        let policy = try XCTUnwrap(fixture.attempt.request.configuration.speakerAttributionPolicy)
        let tail = try MeetingStreamingProtectedWordTail(attemptID: fixture.attempt.request.attemptID,
            epoch: .init(trackID: tracks[0].id, ordinal: 0), speakerNameFormat: "Speaker %lld", policy: policy)
        // Two attribution horizons (pending words and their left context), interruption
        // preroll and the preceding 20-second ASR window. Each source island carries 0.5s
        // of compact audio; four terminal/in-flight islands cover the joined checkpoint.
        let boundedSeconds = 2 * tail.policyLookahead + policy.maximumBriefInterruptionSeconds
            + policy.maximumBriefInterruptionGapSeconds + 20
        let maximumRetainedIslands = Int(ceil(boundedSeconds / 0.5)) + 4
        XCTAssertLessThan(maximumRetainedIslands, 180, "Retirement must not retain the entire recording")
        for track in tracks {
            let timeline = try XCTUnwrap(fixture.attempt.sourceTimelines[track.id])
            XCTAssertLessThanOrEqual(timeline.retainedSpanCount, maximumRetainedIslands,
                "Joined protected publication retires islands outside the frozen attribution horizon")
            XCTAssertTrue(timeline.hasGaps)
        }
        async let first: Void = consumers[0].finish()
        async let second: Void = consumers[1].finish()
        _ = try await (first, second)
        let result = try await fixture.pipeline.process(session: fixture.publication.session,
            sessionDirectory: fixture.directory, progress: { _ in })
        XCTAssertEqual(result.segments.count, 360)
        XCTAssertTrue(result.isComplete)
    }

    func testOnlineStreamingPipelineAccumulatesBothSourcesAndFinishesWithoutReplay() async throws {
        let service = OnlinePipelineService()
        let runtime = OnlinePipelineRuntime()
        let fixture = try self.onlinePipelineFixture(service: service, runtime: runtime)
        let microphone = try await fixture.pipeline.memoryConsumer(for: fixture.session.id,
            track: fixture.session.audioTracks[0], eventHandler: { _ in })
        let application = try await fixture.pipeline.memoryConsumer(for: fixture.session.id,
            track: fixture.session.audioTracks[1], eventHandler: { _ in })
        for index in 0..<42 {
            XCTAssertTrue(microphone.enqueue(try Self.onlinePCM(frames: 8_000, startFrame: index * 8_000)))
            XCTAssertTrue(application.enqueue(try Self.onlinePCM(frames: 8_000, startFrame: index * 8_000)))
        }
        try await Self.onlineWait { fixture.publication.session.transcriptSegments.count >= 80 }
        XCTAssertEqual(fixture.publication.previewSources, Set([.microphone, .applicationAudio]),
                       "Each physical source publishes through its own preview route")
        XCTAssertEqual(service.residencyEntries, 1)
        XCTAssertEqual(service.residencyExits, 0, "Both continuous sources still own the same prepared resource stack")
        XCTAssertEqual(runtime.evidence.count("scope-open"), 1)
        XCTAssertEqual(Set(fixture.publication.session.transcriptSegments.map(\.sourceTrackID)),
                       Set(fixture.session.audioTracks.map(\.id)))
        XCTAssertEqual(Set(fixture.publication.session.transcriptSegments.compactMap(\.speakerID)).count, 4,
                       "Two native voices in each source remain four source-scoped participants")
        XCTAssertEqual(fixture.attempt.archive.totalSampleCount, 0, "Streaming cannot hide a full-audio RAM replay")
        async let stopMicrophone: Void = microphone.finish()
        async let stopApplication: Void = application.finish()
        _ = try await (stopMicrophone, stopApplication)
        XCTAssertEqual(service.residencyExits, 1, "Both Stop tails joined model handback before final publication")
        let result = try await fixture.pipeline.process(session: fixture.publication.session,
            sessionDirectory: fixture.directory, progress: { _ in })
        XCTAssertEqual(result.segments.count, 84, "The final one-second tail of both physical sources is retained")
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(Set(result.segments.map(\.id)).count, 84)
        for track in fixture.session.audioTracks {
            let words = result.segments.filter { $0.sourceTrackID == track.id }
            XCTAssertEqual(words.first?.nativeTiming?.start, 0)
            XCTAssertEqual(words.last?.nativeTiming?.end, 20.9)
        }
        XCTAssertEqual(runtime.evidence.count("scope-open"), 1)
        XCTAssertEqual(runtime.evidence.count("scope-cleaned"), 1)
        XCTAssertEqual(runtime.evidence.count("replay"), 0)
        XCTAssertNil(fixture.pipeline.memoryAttempts[fixture.session.id])
    }

    func testOnlineStreamingPipelineCancellationJoinsTheOtherPhysicalSource() async throws {
        let service = OnlinePipelineService(), runtime = OnlinePipelineRuntime()
        let fixture = try self.onlinePipelineFixture(service: service, runtime: runtime)
        let microphone = try await fixture.pipeline.memoryConsumer(for: fixture.session.id,
            track: fixture.session.audioTracks[0], eventHandler: { _ in })
        _ = try await fixture.pipeline.memoryConsumer(for: fixture.session.id,
            track: fixture.session.audioTracks[1], eventHandler: { _ in })
        XCTAssertTrue(microphone.enqueue(try Self.onlinePCM(frames: 8_000, startFrame: 0)))
        try await Self.onlineWait { runtime.evidence.count("recognize-entered") == 1 }
        await fixture.pipeline.cancelMemoryAudio(sessionID: fixture.session.id)
        XCTAssertEqual(service.residencyEntries, 1)
        XCTAssertEqual(service.residencyExits, 1)
        XCTAssertEqual(runtime.evidence.count("scope-cleaned"), 1,
                       "The sibling waiting for its first command cannot keep native ownership orphaned")
        XCTAssertEqual(runtime.evidence.count("replay"), 0)
        XCTAssertNil(fixture.pipeline.memoryAttempts[fixture.session.id])
    }

    /// Explicit local replay of synthetic speech through the same online consumer boundary.
    /// This is actual-model evidence with paced file input, not a physical capture/UI test.
    func testOnlineStreamingRealModelsWithPacedSyntheticSources() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PICHI_ONLINE_STREAMING_REAL_MODELS"] == "1" else {
            throw XCTSkip("Set PICHI_ONLINE_STREAMING_REAL_MODELS=1 with two attested synthetic mono16k WAVs")
        }
        guard environment["PICHI_ONLINE_STREAMING_SYNTHETIC_AUDIO"] == "1",
              let microphonePath = environment["PICHI_ONLINE_STREAMING_MIC_WAV"],
              let applicationPath = environment["PICHI_ONLINE_STREAMING_APP_WAV"] else {
            throw OnlinePipelineFailure.invalidInput
        }
        let sources = try [microphonePath, applicationPath].map(Self.onlineSyntheticWAV)
        guard sources[0].count == sources[1].count, (336_000...2_880_000).contains(sources[0].count) else {
            throw OnlinePipelineFailure.invalidInput
        }
        let model = try XCTUnwrap(SettingsStore.SpeechModel(rawValue:
            environment["PICHI_ONLINE_STREAMING_ASR"] ?? SettingsStore.SpeechModel.gigaam.rawValue))
        let descriptor = try XCTUnwrap(PichiMeetingProviderFactory.registeredBackendDescriptor(for: model.rawValue))
        let language = environment["PICHI_ONLINE_STREAMING_LANGUAGE"] ?? "ru"
        let configuration = try await PichiMeetingProviderFactory.frozenConfiguration(backendID: descriptor.id,
            languageCode: language, diarizationEnabled: true, speakerProcessingMode: .streaming)
        try await PichiMeetingProviderFactory.prepareSpeakerResources(for: configuration)
        try await MeetingSpeechActivityResources.shared.prepare()
        let service = ASRService(meetingModelResidency: MeetingModelResidencyCoordinator())
        let lease = try service.acquireExclusiveActivity(.meeting)
        var ownedPipeline: MeetingProcessingPipeline?
        var ownedSessionID: UUID?
        var ownedActivity: MeetingPendingSpeechCapture?
        do {
        let runtime = MeetingParakeetNemotronRuntime(asrServiceProvider: { service },
            modelLocator: try PichiMeetingProviderFactory.modelLocator(for: configuration))
        let fixture = try self.onlinePipelineFixture(service: service, runtime: runtime,
            configuration: configuration, descriptor: descriptor)
        ownedPipeline = fixture.pipeline
        ownedSessionID = fixture.session.id
        let origin = MeetingLiveOriginBox()
        _ = origin.establish(.zero)
        let speechActivity = MeetingPendingSpeechCapture(originBox: origin,
            activityModel: { try MeetingSileroActivityArtifacts.open() }, activitySources: [.you, .them]) { _ in }
        ownedActivity = speechActivity
        fixture.attempt.trackConfidentlyNonSpeech = { kind, start, end in
            await speechActivity.awaitConfidentNonSpeech(source: kind == .microphone ? .you : .them,
                start: start, end: end)
        }
        let consumers = try await fixture.session.audioTracks.asyncOnlineMap { track in
            try await fixture.pipeline.memoryConsumer(for: fixture.session.id, track: track, eventHandler: { _ in })
        }
        let clock = ContinuousClock(), began = ContinuousClock.now
        let cpuBegan = DiagnosticProcessCPUTime.capture()
        var peakFootprint = Self.onlineFootprintMiB() ?? 0
        for start in stride(from: 0, to: sources[0].count, by: 4_000) {
            let end = min(sources[0].count, start + 4_000)
            for index in consumers.indices {
                let sample = try Self.onlinePCM(samples: Array(sources[index][start..<end]), startFrame: start)
                speechActivity.offer(kind: fixture.session.audioTracks[index].kind, sampleBuffer: sample)
                XCTAssertTrue(consumers[index].enqueue(sample))
            }
            peakFootprint = max(peakFootprint, Self.onlineFootprintMiB() ?? 0)
            try await clock.sleep(until: began.advanced(by: .seconds(Double(end) / 16_000)))
        }
        let duringCapture = fixture.publication.session.transcriptSegments.count
        let stopped = ContinuousClock.now
        try await withThrowingTaskGroup(of: Void.self) { group in
            for consumer in consumers { group.addTask { try await consumer.finish() } }
            while try await group.next() != nil {}
        }
        let result = try await fixture.pipeline.process(session: fixture.publication.session,
            sessionDirectory: fixture.directory, progress: { _ in })
        peakFootprint = max(peakFootprint, Self.onlineFootprintMiB() ?? 0)
        await speechActivity.stopAndWait()
        service.releaseExclusiveActivity(lease)
        let dictationLease = try service.acquireExclusiveActivity(.dictation)
        service.releaseExclusiveActivity(dictationLease)
        let nextMeetingLease = try service.acquireExclusiveActivity(.meeting)
        service.releaseExclusiveActivity(nextMeetingLease)
        let cpuMilliseconds = cpuBegan.flatMap { earlier in DiagnosticProcessCPUTime.capture()?.milliseconds(since: earlier) }
        let elapsed = stopped.duration(to: .now).components
        let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1_000_000_000_000_000
        XCTAssertGreaterThan(duringCapture, 0, "Recognition must accumulate before Stop")
        XCTAssertTrue(result.isComplete)
        for track in fixture.session.audioTracks { XCTAssertTrue(result.segments.contains { $0.sourceTrackID == track.id }) }
        XCTAssertNil(fixture.pipeline.memoryAttempts[fixture.session.id])
        let report: [String: Any] = ["schema": 1, "realModels": true, "input": "paced-synthetic-mono16k-sources",
            "physicalCapture": false, "uiAcceptance": false, "duringCaptureWords": duringCapture,
            "finalWords": result.segments.count, "sourceCount": 2, "sourceFrames": sources[0].count,
            "stopToResultMilliseconds": milliseconds, "complete": result.isComplete,
            "asrModel": configuration.asrModel, "pipelineVersion": configuration.pipelineVersion,
            "sourceVAD": true, "serviceReAdmissionVerified": true, "sampledPeakPhysicalFootprintMiB": peakFootprint,
            "sampledPhysicalFootprintAfterStopMiB": Self.onlineFootprintMiB() ?? -1,
            "cpuMilliseconds": cpuMilliseconds ?? -1,
            "speakerCountsBySource": fixture.session.audioTracks.map { track in
                Set(result.segments.filter { $0.sourceTrackID == track.id && !$0.isEcho }.compactMap(\.speakerID)).count
            }]
        if let path = environment["PICHI_ONLINE_STREAMING_REPORT"] {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        print("ONLINE_STREAMING_REAL_MODELS stopToResultMs=\(milliseconds) duringCaptureWords=\(duringCapture) finalWords=\(result.segments.count)")
        } catch {
            if let ownedPipeline, let ownedSessionID { await ownedPipeline.cancelMemoryAudio(sessionID: ownedSessionID) }
            await ownedActivity?.stopAndWait()
            service.releaseExclusiveActivity(lease)
            throw error
        }
    }

    private func onlinePipelineFixture(service: any MeetingASRServicing, runtime: any MeetingParakeetNemotronRunning,
                                       mode: MeetingCaptureMode = .onlineCall,
        configuration: MeetingFinalProcessingConfiguration? = nil, descriptor: MeetingBackendDescriptor? = nil) throws
        -> (pipeline: MeetingProcessingPipeline, session: MeetingSession, attempt: MeetingMemoryProcessingAttempt,
            publication: OnlinePipelinePublication, directory: URL) {
        let tracks = mode == .onlineCall
            ? [self.makeMicTrack(chunks: [], eraStart: 0), self.makeAppTrack(chunks: [])]
            : [self.makeMicTrack(chunks: [], eraStart: 0)]
        var session = self.makeSession(mode: mode, tracks: tracks)
        session.speakerLabelsEnabled = true
        session.speakerProcessingMode = .streaming
        session.transcriptIsComplete = true
        let configuration = configuration ?? MeetingFinalProcessingConfiguration(asrModel: "synthetic-streaming",
            languageCode: "en", diarizationFingerprint: "synthetic-speaker-state", speakerProcessingMode: .streaming)
        session.languageCode = configuration.languageCode
        let descriptor = descriptor ?? MeetingBackendDescriptor(id: .init(rawValue: "synthetic-online-stream"), version: "1",
            execution: .local, supportedLanguageCodes: [configuration.languageCode], supportedTrackKinds: [.microphone, .applicationAudio],
            supportedFinalPrecisions: [.word], resultContract: .canonicalEvidence, knownLimits: [], analysisSampleRate: 16_000,
            supportedInputs: [.boundedMultiTrackPCM, .boundedMicrophonePCM], supportedSpeakerProcessingModes: [.streaming])
        let directory = try self.makeTempSessionDirectory()
        let request = MeetingBackendRequest(attemptID: UUID(), session: session, sessionDirectory: directory, configuration: configuration)
        let publication = OnlinePipelinePublication(session)
        let attempt = MeetingMemoryProcessingAttempt(request: request, descriptor: descriptor, runtime: runtime,
            archive: try MeetingMemoryAudioArchive(), redactor: nil,
            checkpoint: { try await publication.apply($0) }, preview: { kind, partial in
                publication.previewSources.insert(kind)
                publication.preview[kind] = partial
            })
        let pipeline = MeetingProcessingPipeline(asrServiceProvider: { service }, managesModelResidency: true,
            serializationGate: MeetingProcessingSerializationGate(), meetingRuntimeFactory: { _ in runtime })
        pipeline.memoryAttempts[session.id] = attempt
        addTeardownBlock { await pipeline.cancelMemoryAudio(sessionID: session.id) }
        return (pipeline, session, attempt, publication, directory)
    }

    private static func onlineWait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw OnlinePipelineFailure.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func onlinePCM(frames: Int, startFrame: Int) throws -> CMSampleBuffer {
        try onlinePCM(samples: [Float](repeating: 0.1, count: frames), startFrame: startFrame)
    }
    private static func onlinePCM(samples: [Float], startFrame: Int) throws -> CMSampleBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        return try MeetingCapturePCMConverter.sampleBuffer(buffer: buffer,
            presentationTime: CMTime(value: Int64(startFrame), timescale: 16_000))
    }
    private static func onlineFootprintMiB() -> Double? {
        var information = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &information) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Double(information.phys_footprint) / 1_048_576 : nil
    }

    private static func onlineSyntheticWAV(_ path: String) throws -> [Float] {
        guard path.hasPrefix("/") else { throw OnlinePipelineFailure.invalidInput }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
              (1...2_880_000).contains(file.length) else { throw OnlinePipelineFailure.invalidInput }
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}

private enum OnlinePipelineFailure: Error { case unexpected, invalidInput, timeout }

@MainActor
private final class OnlinePipelinePublication {
    var session: MeetingSession
    var preview: [MeetingAudioTrackKind: MeetingLivePartial] = [:]
    var previewSources = Set<MeetingAudioTrackKind>()
    var persistentStore: MeetingSessionStore?
    var beforeApply: ((MeetingPCMTranscriptBatch) throws -> Void)?
    var collectBatches = false
    var receivedBatches: [MeetingPCMTranscriptBatch] = []
    init(_ session: MeetingSession) { self.session = session }
    func apply(_ batch: MeetingPCMTranscriptBatch) async throws {
        try self.beforeApply?(batch)
        var indices = Dictionary(uniqueKeysWithValues: session.transcriptSegments.enumerated().map { ($0.element.id, $0.offset) })
        for segment in batch.segments {
            if let index = indices[segment.id] { session.transcriptSegments[index] = segment }
            else { indices[segment.id] = session.transcriptSegments.count; session.transcriptSegments.append(segment) }
        }
        for revision in batch.speakerRevisions {
            guard let index = indices[revision.segmentID] else { throw OnlinePipelineFailure.unexpected }
            try revision.apply(to: &session.transcriptSegments[index])
        }
        for revision in batch.echoRevisions {
            if let index = indices[revision.segmentID] { session.transcriptSegments[index].isLikelyEcho = revision.isLikelyEcho }
        }
        session.speakers = batch.mergingSpeakers(into: session.speakers)
        session.transcriptIsComplete = session.transcriptIsComplete != false && batch.isComplete
        session.transcriptTimeDomain = .meetingRelative
        try session.validateTranscriptStructure()
        if let persistentStore { try await persistentStore.save(session) }
        if self.collectBatches { self.receivedBatches.append(batch) }
    }
}

@MainActor
private final class OnlinePipelineService: MeetingASRServicing {
    var residencyEntries = 0
    var residencyExits = 0
    var isRunning: Bool { false }
    var fileTranscriptionProvider: any TranscriptionProvider { fatalError("Unused synthetic provider") }
    func acquireExclusiveActivity(_ activity: ASRExclusiveActivity) throws -> ASRActivityLease { .init(id: UUID(), activity: activity) }
    func releaseExclusiveActivity(_ lease: ASRActivityLease) {}
    func prepareMeetingAudioHandoff(_ lease: ASRActivityLease) async throws {}
    func completeMeetingAudioHandback(_ lease: ASRActivityLease) async {}
    func ensureAsrReady() async throws { throw OnlinePipelineFailure.unexpected }
    func meetingResidencyParticipant() -> MeetingModelParticipant {
        .init(owner: "synthetic", snapshot: { nil }, suspend: {}, restore: { _ in })
    }
    func withMeetingModelResidency<T>(attemptID: UUID, acceptsCompletedCancellation: (T) -> Bool,
        work: nonisolated(nonsending) () async throws -> T) async throws -> T {
        guard residencyEntries == residencyExits else { throw OnlinePipelineFailure.unexpected }
        residencyEntries += 1
        defer { residencyExits += 1 }
        return try await work()
    }
    func withPreparedMeetingASR<T>(attemptID: UUID, configuration: MeetingFinalProcessingConfiguration,
        body: nonisolated(nonsending) @escaping (any TranscriptionProvider) async throws -> T) async throws -> T { throw OnlinePipelineFailure.unexpected }
    func transcribeMeetingSamples(_ samples: [Float], provider: any TranscriptionProvider, languageCode: String) async throws -> ASRTranscriptionResult { throw OnlinePipelineFailure.unexpected }
    func transcribeMeetingSamplesWithTimings(_ samples: [Float], provider: any TranscriptionProvider) async throws -> (result: ASRTranscriptionResult, words: [ASRWordTiming]) { throw OnlinePipelineFailure.unexpected }
    func transcribeMeetingFile(at fileURL: URL, provider: any TranscriptionProvider) async throws -> ASRTranscriptionResult { throw OnlinePipelineFailure.unexpected }
}

private final nonisolated class OnlinePipelineEvidence: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    func record(_ event: String) { lock.withLock { events.append(event) } }
    func count(_ event: String) -> Int { lock.withLock { events.filter { $0 == event }.count } }
}

private final nonisolated class OnlinePipelineRuntime: MeetingParakeetNemotronRunning, @unchecked Sendable {
    let evidence = OnlinePipelineEvidence()
    var supportsStreamingPCMProcessing: Bool { true }
    var supportsMultiTrackStreamingPCMProcessing: Bool { true }
    func preparePCMResources(attemptID: UUID, configuration: MeetingFinalProcessingConfiguration) async throws { evidence.record("prepare") }
    func withPreparedStreamingPCM(trackID: UUID, attemptID: UUID, configuration: MeetingFinalProcessingConfiguration,
        onProgress: nonisolated(nonsending) @escaping @Sendable (MeetingStreamingPCMObservation) async throws -> Void,
        body: nonisolated(nonsending) @escaping @Sendable (any MeetingPreparedStreamingPCMProcessing) async throws -> Void) async throws {
        evidence.record("scope-open")
        defer { evidence.record("scope-cleaned") }
        try await body(OnlinePipelinePrepared(track: trackID, attempt: attemptID, evidence: evidence, progress: onProgress))
    }
    func withPreparedStreamingPCMTracks(trackIDs: [UUID], attemptID: UUID, configuration: MeetingFinalProcessingConfiguration,
        onProgress: nonisolated(nonsending) @escaping @Sendable (UUID, MeetingStreamingPCMObservation) async throws -> Void,
        body: nonisolated(nonsending) @escaping @Sendable ([UUID: any MeetingPreparedStreamingPCMProcessing]) async throws -> Void) async throws {
        evidence.record("scope-open")
        defer { evidence.record("scope-cleaned") }
        let sessions = Dictionary(uniqueKeysWithValues: trackIDs.map { track in
            (track, OnlinePipelinePrepared(track: track, attempt: attemptID, evidence: evidence,
                progress: { try await onProgress(track, $0) }) as any MeetingPreparedStreamingPCMProcessing)
        })
        try await body(sessions)
    }
    func withNemotronDiarization(artifact: MeetingNemotronModelArtifact,
        _ body: nonisolated(nonsending) @escaping @Sendable (any MeetingNemotronDiarizerFactory) async throws -> MeetingNemotronPhaseResult) async throws -> MeetingNemotronPhaseResult {
        evidence.record("replay"); throw OnlinePipelineFailure.unexpected
    }
    func withPreparedASR(attemptID: UUID, configuration: MeetingFinalProcessingConfiguration,
        body: nonisolated(nonsending) @escaping @Sendable (any MeetingParakeetASRSession) async throws -> MeetingParakeetPhaseResult) async throws -> MeetingParakeetPhaseResult {
        evidence.record("replay"); throw OnlinePipelineFailure.unexpected
    }
}

private actor OnlinePipelinePrepared: MeetingPreparedStreamingPCMProcessing {
    let track: UUID
    let attempt: UUID
    let evidence: OnlinePipelineEvidence
    let progress: @Sendable (MeetingStreamingPCMObservation) async throws -> Void
    var accepted = 0
    init(track: UUID, attempt: UUID, evidence: OnlinePipelineEvidence,
        progress: @escaping @Sendable (MeetingStreamingPCMObservation) async throws -> Void) {
        self.track = track; self.attempt = attempt; self.evidence = evidence; self.progress = progress
    }
    func recognize(window: MeetingPCMProgressiveWindow, offset: TimeInterval,
        preview: (nonisolated(nonsending) @Sendable (MeetingPCMTranscriptBatch) async throws -> Void)?) async throws -> MeetingStreamingPCMObservation {
        evidence.record("recognize-entered")
        let start = Int((offset * 16_000).rounded())
        while let update = try await window.next() {
            accepted = start + update.totalFrames
            try await progress(observation(batch: .init(segments: []), final: false))
        }
        let words = stride(from: start, to: accepted, by: 8_000).map { frame in
            let start = Double(frame) / 16_000, end = min(Double(accepted) / 16_000, start + 0.4)
            return MeetingTranscriptSegment(id: UUID(), start: .init(value: Int64(frame), timescale: 16_000),
                end: .init(value: Int64((end * 16_000).rounded()), timescale: 16_000), sourceTrackID: track,
                speakerID: nil, text: "synthetic-\(frame)", revision: 0, status: .final, overlap: .none, completeness: .complete,
                attributionState: .unassigned, nativePrecision: .word, nativeUnitID: "\(track)-\(frame)",
                nativeSpeakerAssignment: .unassigned, nativeTiming: .init(start: start, end: end))
        }
        let batch = MeetingPCMTranscriptBatch(segments: words)
        if let preview { try await preview(batch) }
        return observation(batch: batch, final: false, asrStable: accepted)
    }
    func finishStreaming() async throws -> MeetingStreamingPCMObservation {
        observation(batch: .init(segments: []), final: true, asrStable: accepted)
    }
    func discardActivity(beforeSample: Int) async throws {}
    private func observation(batch: MeetingPCMTranscriptBatch, final: Bool, asrStable: Int? = nil) -> MeetingStreamingPCMObservation {
        let end = Double(accepted) / 16_000
        let epoch = MeetingAnalysisEpochID(trackID: track, ordinal: 0)
        var activity: [MeetingBackendSpeakerActivity] = []
        if end > 0 { activity.append(.init(token: .init(analysisEpochID: epoch, label: "a"), start: 0, end: min(10, end))) }
        if end > 10 { activity.append(.init(token: .init(analysisEpochID: epoch, label: "b"), start: 10, end: end)) }
        return .init(batch: batch, activity: activity, acceptedThroughSample: accepted, processedThroughSample: accepted,
            retainedFromSample: 0, isFinal: final, asrStableThroughSample: asrStable)
    }
}

private extension Array where Element == MeetingAudioTrack {
    @MainActor func asyncOnlineMap<T>(_ transform: (Element) async throws -> T) async throws -> [T] {
        var output: [T] = []
        for element in self { output.append(try await transform(element)) }
        return output
    }
}
