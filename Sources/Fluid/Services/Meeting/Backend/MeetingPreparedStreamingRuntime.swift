import Foundation

/// The concrete inference adapter keeps both prepared sessions inside their existing model
/// scopes. One controller worker invokes it serially; no complete recording or unprotected
/// transcript history is retained. Canonical privacy admission remains the pipeline's owner.
final nonisolated class MeetingPreparedStreamingRuntime: MeetingPreparedStreamingPCMProcessing, @unchecked Sendable {
    private let runtime: MeetingParakeetNemotronRuntime
    private let asr: any MeetingParakeetASRSession
    private let diarizer: any MeetingIncrementalNemotronDiarizerSession
    private let trackID: MeetingAudioTrackID
    private let attemptID: UUID
    private let configuration: MeetingFinalProcessingConfiguration
    private let speakerNameFormat: String
    private let useAdaptiveOwnerEvidence: Bool
    private let verifyOwnerDuringCapture: Bool
    private let ownerVerificationPolicy: MeetingOwnerVoiceVerifier.Policy
    private let preserveOwnerCadenceAtEOF: Bool
    private let preserveOwnerEvidenceOnInconclusiveRefresh: Bool
    private let onProgress: @Sendable (MeetingStreamingPCMObservation) async throws -> Void
    private let lock = NSLock()
    private var busy = false
    private var closed = false
    private var finished = false
    private var pacing = MeetingPCMPreviewPacing()
    private var pendingWindowTiming: (start: Int, frames: Int, timing: MeetingPCMWindowComputeTiming)?
    private var update = MeetingIncrementalDiarizationUpdate(activity: [], acceptedThroughSample: 0,
        processedThroughSample: 0, retainedFromSample: 0, isFinal: false)
    private var speakers: [MeetingSessionSpeaker] = []
    private var ownerSamples: MeetingStreamingOwnerVoiceSamples?
    /// The clip lengths belong to this exact encoded profile, including when another
    /// slot alone supplies the next inference batch. In the continuity recipe an unavailable
    /// refresh retains this exact proof; only a complete measurement replaces it.
    private nonisolated struct OwnerProfileEvidence: Sendable {
        let profile: MeetingSpeakerVoiceProfile
        let clipFrames: [Int]?
    }
    private var ownerProfiles: [MeetingBackendSpeakerToken: OwnerProfileEvidence] = [:]
    private var incompleteOwnerProfiles = Set<MeetingBackendSpeakerToken>()
    private var confirmedOwnerTokens: Set<MeetingBackendSpeakerToken> = []
    private var ownerEncoderUnavailable = false

    struct OwnerEvidence: Sendable {
        let samples: [MeetingSpeakerVoiceSamples]
        let speakers: [MeetingSessionSpeaker]
        let observation: MeetingStreamingPCMObservation
    }

    init(runtime: MeetingParakeetNemotronRuntime, asr: any MeetingParakeetASRSession,
         diarizer: any MeetingIncrementalNemotronDiarizerSession, trackID: MeetingAudioTrackID,
         attemptID: UUID, configuration: MeetingFinalProcessingConfiguration, speakerNameFormat: String,
         collectOwnerEvidence: Bool = false, useAdaptiveOwnerEvidence: Bool = false,
         verifyOwnerDuringCapture: Bool = false,
         ownerVerificationPolicy: MeetingOwnerVoiceVerifier.Policy = .streamingV2,
         preserveOwnerCadenceAtEOF: Bool = false,
         preserveOwnerEvidenceOnInconclusiveRefresh: Bool = false,
         onProgress: @escaping @Sendable (MeetingStreamingPCMObservation) async throws -> Void) {
        self.runtime = runtime
        self.asr = asr
        self.diarizer = diarizer
        self.trackID = trackID
        self.attemptID = attemptID
        self.configuration = configuration
        self.speakerNameFormat = speakerNameFormat
        self.useAdaptiveOwnerEvidence = useAdaptiveOwnerEvidence
        self.verifyOwnerDuringCapture = verifyOwnerDuringCapture && collectOwnerEvidence
        self.ownerVerificationPolicy = ownerVerificationPolicy
        self.preserveOwnerCadenceAtEOF = preserveOwnerCadenceAtEOF
        self.preserveOwnerEvidenceOnInconclusiveRefresh = preserveOwnerEvidenceOnInconclusiveRefresh
        self.onProgress = onProgress
        self.ownerSamples = collectOwnerEvidence
            ? .init(epoch: .init(trackID: trackID, ordinal: 0), useAdaptiveOwnerEvidence: useAdaptiveOwnerEvidence) : nil
    }

    func recognize(window: MeetingPCMProgressiveWindow, offset: TimeInterval,
                   preview: (@Sendable (MeetingPCMTranscriptBatch) async throws -> Void)?) async throws -> MeetingStreamingPCMObservation {
        try self.begin()
        defer { self.end() }
        guard self.pendingWindowTiming == nil else { throw MeetingStreamingPCMControllerError.invalidScope }
        guard offset.isFinite, offset >= 0, offset <= 31_536_000,
              abs(offset * 16_000 - (offset * 16_000).rounded()) < 0.001,
              Int((offset * 16_000).rounded()) == self.update.acceptedThroughSample else {
            throw MeetingIncrementalDiarizationError.nonContiguousInput
        }
        let epoch = MeetingAnalysisEpochID(trackID: self.trackID, ordinal: self.update.acceptedThroughSample)
        // Admission accepts sub-sample floating-point representation noise. Derive
        // transcript times from the frozen integer clock, never that noisy spelling.
        let sourceOffset = Double(epoch.ordinal) / 16_000
        let timing = MeetingPCMWindowComputeTiming()
        // A sealed window immediately enters the canonical protected transcript below.
        // Sending it through the optional speech preview first repeats the same NER work
        // and can exhaust live capture headroom. Keep only genuinely growing previews;
        // the canonical privacy gate still owns every final word and its lexical tail.
        let growingPreview: (@Sendable (MeetingPCMTranscriptBatch) async throws -> Void)?
        if let preview {
            growingPreview = { batch in
                guard !batch.speechObservationIsFinal else { return }
                try await preview(batch)
            }
        } else { growingPreview = nil }
        let phase = try await self.runtime.recognizeProgressivePCMPhase(session: self.asr, window: window,
            offset: sourceOffset, epoch: epoch, attemptID: self.attemptID, timing: timing,
            permitsIntermediateObservations: self.pacing.permitsIntermediateObservations, preview: growingPreview,
            consumePCM: { samples, start in
                try Task.checkCancellation()
                if self.useAdaptiveOwnerEvidence {
                    // A coalesced twenty-second ASR delta may exceed the acoustic scoring
                    // lag. Feed the same PCM in bounded slices before optional owner lookback
                    // can evict its unscored tail. Publication still occurs once per ASR delta.
                    for local in stride(from: 0, to: samples.count, by: 16_000) {
                        try Task.checkCancellation()
                        let end = min(samples.count, local + 16_000)
                        let portion = Array(samples[local..<end])
                        self.ownerSamples?.append(portion, sourceStartSample: start + local)
                        let began = ProcessInfo.processInfo.systemUptime
                        MeetingTimelineTrace.shared?.record("diarizer_append_begin", fields: ["attemptID": self.attemptID.uuidString,
                            "sourceOffsetSample": String(start + local), "sampleCount": String(portion.count)])
                        let next = try await self.diarizer.appendStreaming(portion, sourceStartSample: start + local)
                        self.traceDiarizer(next, since: began)
                        try Task.checkCancellation()
                        try self.accept(next, expectedAccepted: start + end, final: false)
                        let priorOwner = self.confirmedOwnerTokens
                        try await self.verifyLiveOwner()
                        if priorOwner != self.confirmedOwnerTokens {
                            try await self.onProgress(self.observation())
                        }
                    }
                } else {
                    self.ownerSamples?.append(samples, sourceStartSample: start)
                    let began = ProcessInfo.processInfo.systemUptime
                    MeetingTimelineTrace.shared?.record("diarizer_append_begin", fields: ["attemptID": self.attemptID.uuidString,
                        "sourceOffsetSample": String(start), "sampleCount": String(samples.count)])
                    let next = try await self.diarizer.appendStreaming(samples, sourceStartSample: start)
                    self.traceDiarizer(next, since: began)
                    try Task.checkCancellation()
                    try self.accept(next, expectedAccepted: start + samples.count, final: false)
                }
                // Publication joins durable IO and UI projection on the same worker.
                // It consumes real capture headroom, unlike waiting for future PCM.
                try await self.onProgress(self.observation())
                try Task.checkCancellation()
            })
        try Task.checkCancellation()
        guard phase.outputs.count == 1, let output = phase.outputs.first,
              output.sampleCount == phase.boundedPCMSamples.count else {
            throw MeetingParakeetNemotronRuntimeError.invalidPCMWindow
        }
        let physicalCount = phase.boundedPCMSourceSampleCount ?? phase.boundedPCMSamples.count
        guard physicalCount >= output.sampleCount, physicalCount <= 320_000,
              epoch.ordinal + physicalCount == self.update.acceptedThroughSample else {
            throw MeetingParakeetNemotronRuntimeError.invalidPCMWindow
        }
        // Keep ASR-native word identities based on the physical window. Speaker identity uses
        // the one global epoch below; changing the ASR epoch would duplicate word IDs.
        var raw = try await self.runtime.attributePCMSpeech(samples: phase.boundedPCMSamples, output: output,
            epoch: epoch, offset: sourceOffset, attemptID: self.attemptID, configuration: self.configuration,
            priorProfiles: [], priorSpeakers: self.speakers)
        if output.sampleCount < physicalCount {
            raw.isComplete = false
            for index in raw.segments.indices { raw.segments[index].completeness = .incompleteTrack }
        }
        let attributed = try MeetingPCMRecordingAttribution.assemble(transcript: raw,
            activity: self.activity(), epoch: self.globalEpoch, attemptID: self.attemptID,
            duration: Double(self.update.acceptedThroughSample) / 16_000,
            speakerNameFormat: self.speakerNameFormat,
            confirmedLocalUserTokens: self.confirmedOwnerTokens,
            speakerAttributionPolicy: self.configuration.speakerAttributionPolicy)
        self.speakers = attributed.mergingSpeakers(into: self.speakers, speakerNameFormat: self.speakerNameFormat)
        // Do not sample pacing here: canonical privacy, persistence and UI projection have
        // not run yet. Their joined cost is charged when the transport acknowledges this
        // exact window. Retain only a clock and scalar identity, never the PCM or text.
        self.pendingWindowTiming = (epoch.ordinal, physicalCount, timing)
        try Task.checkCancellation()
        return self.observation(batch: attributed, asrStableThroughSample: self.update.acceptedThroughSample,
            sealedEmptyASRRange: output.sampleCount == physicalCount && attributed.isComplete
                && output.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && output.words.isEmpty && attributed.segments.isEmpty
                ? epoch.ordinal..<self.update.acceptedThroughSample : nil)
    }

    func recordWindowProcessing(_ feedback: MeetingPCMWindowProcessingFeedback) async throws {
        try self.begin()
        defer { self.end() }
        guard let pending = self.pendingWindowTiming,
              feedback.sourceStartSample == pending.start, feedback.sourceFrameCount == pending.frames,
              feedback.chargedPendingFrames >= 0, feedback.maximumPendingFrames > 0,
              feedback.chargedPendingFrames <= feedback.maximumPendingFrames else {
            throw MeetingStreamingPCMControllerError.invalidScope
        }
        let compute = pending.timing.computeSeconds
        self.pacing.record(computeSeconds: compute, audioSeconds: Double(pending.frames) / 16_000,
            chargedPendingFrames: feedback.chargedPendingFrames, maximumPendingFrames: feedback.maximumPendingFrames)
        self.pendingWindowTiming = nil
        DebugLogger.shared.info("streaming_preview_headroom computeMS=\(Int64(min(86_400, compute) * 1_000)) physicalFrames=\(pending.frames) chargedPendingFrames=\(feedback.chargedPendingFrames) budgetFrames=\(feedback.maximumPendingFrames) intermediate=\(self.pacing.permitsIntermediateObservations)",
            source: "MeetingPCMRuntime")
    }

    func finishStreaming() async throws -> MeetingStreamingPCMObservation {
        try self.begin()
        defer { self.end() }
        let began = ProcessInfo.processInfo.systemUptime
        MeetingTimelineTrace.shared?.record("diarizer_finish_begin", fields: ["attemptID": self.attemptID.uuidString,
            "totalSamples": String(self.update.acceptedThroughSample)])
        let next = try await self.diarizer.finishStreaming(totalSamples: self.update.acceptedThroughSample)
        self.traceDiarizer(next, since: began)
        try Task.checkCancellation()
        try self.accept(next, expectedAccepted: self.update.acceptedThroughSample, final: true)
        try await self.verifyLiveOwner(final: true)
        self.lock.withLock { self.finished = true }
        return self.observation(asrStableThroughSample: self.update.acceptedThroughSample)
    }

    func discardActivity(beforeSample: Int) async throws {
        try self.begin()
        defer { self.end() }
        guard beforeSample >= self.update.retainedFromSample, beforeSample <= self.update.processedThroughSample else {
            throw MeetingIncrementalDiarizationError.invalidWatermark
        }
        // Text can acknowledge all scored silence while optional owner evidence still
        // waits for the interval admission horizon. Preserve its left turn-edge context.
        let ownerFloor = self.ownerSamples?.retainActivityFromSample ?? beforeSample
        let retainedFrom = max(self.update.retainedFromSample, min(beforeSample, ownerFloor))
        try await self.diarizer.discardActivity(beforeSample: retainedFrom)
        try Task.checkCancellation()
        let floor = Double(retainedFrom) / 16_000
        self.update = .init(activity: self.update.activity.compactMap {
            let start = max(floor, $0.start)
            return $0.end > start ? .init(slotIndex: $0.slotIndex, start: start, end: $0.end) : nil
        }, acceptedThroughSample: self.update.acceptedThroughSample,
            processedThroughSample: self.update.processedThroughSample, retainedFromSample: retainedFrom, isFinal: false)
    }

    func requireFinished() throws {
        try self.lock.withLock {
            guard self.finished, !self.busy, !self.closed else { throw MeetingStreamingPCMControllerError.invalidScope }
        }
    }

    /// Called only after the resource body's command has joined. The native session's own
    /// joined cleanup is still awaited before its factory and the prepared ASR can be released.
    func cleanup() async {
        self.lock.withLock { self.closed = true }
        await self.diarizer.cleanupStreaming()
        self.speakers.removeAll()
        self.ownerSamples = nil
        self.ownerProfiles.removeAll(keepingCapacity: false)
        self.incompleteOwnerProfiles.removeAll(keepingCapacity: false)
        self.confirmedOwnerTokens.removeAll(keepingCapacity: false)
        self.pendingWindowTiming = nil
        self.update = .init(activity: [], acceptedThroughSample: 0, processedThroughSample: 0,
                            retainedFromSample: 0, isFinal: false)
    }

    /// Copy only bounded clips and lightweight identities before releasing the prepared pair.
    /// No ASR, diarizer or model reference escapes into the subsequent voice-encoder phase.
    func ownerEvidence() throws -> OwnerEvidence? {
        try self.requireFinished()
        guard let samples = self.ownerSamples?.takeExcerpts(), !samples.isEmpty else { return nil }
        return .init(samples: samples, speakers: self.speakers,
            observation: .init(batch: .init(segments: []), activity: self.activity(),
                acceptedThroughSample: self.update.acceptedThroughSample,
                processedThroughSample: self.update.processedThroughSample,
                retainedFromSample: self.update.retainedFromSample, isFinal: false))
    }

    private var globalEpoch: MeetingAnalysisEpochID { .init(trackID: self.trackID, ordinal: 0) }

    private func activity() -> [MeetingBackendSpeakerActivity] {
        self.update.activity.map {
            .init(token: .init(analysisEpochID: self.globalEpoch, label: "slot-\($0.slotIndex)"), start: $0.start, end: $0.end)
        }
    }

    private func observation(batch: MeetingPCMTranscriptBatch = .init(segments: []),
                             asrStableThroughSample: Int? = nil,
                             sealedEmptyASRRange: Range<Int>? = nil) -> MeetingStreamingPCMObservation {
        let value = MeetingStreamingPCMObservation(batch: batch, activity: self.activity(), acceptedThroughSample: self.update.acceptedThroughSample,
            processedThroughSample: self.update.processedThroughSample, retainedFromSample: self.update.retainedFromSample,
            isFinal: self.update.isFinal, asrStableThroughSample: asrStableThroughSample,
            sealedEmptyASRRange: sealedEmptyASRRange,
            confirmedLocalUserTokens: self.verifyOwnerDuringCapture ? self.confirmedOwnerTokens : nil)
        if self.verifyOwnerDuringCapture {
            MeetingTimelineTrace.shared?.record("owner_observation", fields: [
                "attemptID": self.attemptID.uuidString,
                "acceptedThroughSample": String(self.update.acceptedThroughSample),
                "processedThroughSample": String(self.update.processedThroughSample),
                "confirmedCount": String(self.confirmedOwnerTokens.count),
                "confirmedSlots": self.confirmedOwnerTokens.map(\.label).sorted().joined(separator: ","),
                "final": String(self.update.isFinal)])
        }
        return value
    }

    /// The same controller worker joins diarizer, optional voice inference and publication.
    /// The encoder is scoped to this call; only eight two-vector profiles survive it. Scoring
    /// waits for novel admitted speech, so silence and repeated progress never reload weights.
    private func verifyLiveOwner(final: Bool = false) async throws {
        guard self.verifyOwnerDuringCapture, !self.ownerEncoderUnavailable,
              let samples = self.ownerSamples?.liveExcerpts(final: final, preserveCadenceAtEOF: self.preserveOwnerCadenceAtEOF), !samples.isEmpty else { return }
        try Task.checkCancellation()
        let began = ProcessInfo.processInfo.systemUptime
        let profiles: [MeetingSpeakerVoiceProfile]
        do { profiles = try await self.runtime.speakerVoiceProfiles(samples: samples) }
        catch {
            try Task.checkCancellation()
            if self.preserveOwnerEvidenceOnInconclusiveRefresh {
                self.incompleteOwnerProfiles.formUnion(samples.map(\.token))
                self.traceOwnerDecision(encodedProfiles: 0, candidateProfiles: self.ownerProfiles.count,
                    fullEvidenceProfiles: self.ownerProfiles.values.filter { $0.clipFrames == [80_000, 80_000] }.count,
                    outcome: "encoderUnavailablePreserved", final: final, since: began)
                return
            }
            self.ownerEncoderUnavailable = true
            self.ownerProfiles.removeAll(keepingCapacity: false)
            self.confirmedOwnerTokens.removeAll(keepingCapacity: false)
            DebugLogger.shared.info("mode=streaming owner_verification=unavailable preservedAnonymousSpeech=true", source: "MeetingPCMRuntime")
            self.traceOwnerDecision(encodedProfiles: 0, candidateProfiles: 0, fullEvidenceProfiles: 0,
                outcome: "encoderUnavailable", final: final, since: began)
            return
        }
        try Task.checkCancellation()
        let returned = Dictionary(grouping: profiles, by: \.token)
        let encodedClipFrames = MeetingOwnerVoiceVerifier.clipFramesByToken(samples: samples, profiles: profiles)
        let expectedTokens = Set(samples.map(\.token))
        let foreignResults = !Set(returned.keys).isSubset(of: expectedTokens)
        for sample in samples {
            let matches = returned[sample.token] ?? []
            let complete = !foreignResults && MeetingOwnerVoiceVerifier.hasCompleteEncoderResults(samples: [sample], profiles: matches)
            if matches.count == 1, let profile = matches.first,
               self.ownerVerificationPolicy != .streamingV4 || complete {
                if self.preserveOwnerEvidenceOnInconclusiveRefresh,
                   self.confirmedOwnerTokens.contains(sample.token),
                   self.ownerProfiles[sample.token]?.clipFrames == [80_000, 80_000],
                   encodedClipFrames[sample.token] == [80_000, 80_000],
                   let owner = self.runtime.ownerVoiceProfileSnapshot,
                   let consistency = MeetingSpeakerVoiceMatcher.distance(profile, profile),
                   consistency > self.ownerVerificationPolicy.maximumQuerySelfDistance,
                   let reference = MeetingSpeakerVoiceMatcher.distance(profile,
                       MeetingSpeakerVoiceProfile(token: profile.token, embeddings: owner.embeddings)),
                   reference <= self.ownerVerificationPolicy.maximumReferenceDistance {
                    // The new pair disagrees internally but every clip still fits enrollment.
                    // It cannot establish a new identity or contradict the earlier coherent
                    // full proof. Keep that proof, while forbidding any new promotion until
                    // this slot supplies a conclusive replacement. A reference contradiction
                    // or measured close rival still goes through the ordinary scorer below.
                    self.incompleteOwnerProfiles.insert(sample.token)
                    continue
                }
                self.ownerProfiles[sample.token] = .init(profile: profile, clipFrames: encodedClipFrames[sample.token])
                self.incompleteOwnerProfiles.remove(sample.token)
            } else {
                if !self.preserveOwnerEvidenceOnInconclusiveRefresh { self.ownerProfiles[sample.token] = nil }
                if self.ownerVerificationPolicy == .streamingV4 { self.incompleteOwnerProfiles.insert(sample.token) }
            }
        }
        if self.ownerVerificationPolicy == .streamingV4, !self.incompleteOwnerProfiles.isEmpty,
           !self.preserveOwnerEvidenceOnInconclusiveRefresh {
            // Persist the blocker across other slots' batches and unchanged EOF. Only a
            // valid replacement for each missing competitor can restore complete scoring.
            self.confirmedOwnerTokens.removeAll(keepingCapacity: false)
            self.traceOwnerDecision(encodedProfiles: profiles.count, candidateProfiles: self.ownerProfiles.count,
                fullEvidenceProfiles: self.ownerProfiles.values.filter { $0.clipFrames == [80_000, 80_000] }.count,
                outcome: "incompleteEncoderEvidence", final: final, since: began)
            return
        }
        let evidence = self.ownerProfiles.values.sorted { $0.profile.token.label < $1.profile.token.label }
        let candidates = evidence.map(\.profile)
        let clipFramesByToken = Dictionary(uniqueKeysWithValues: evidence.compactMap { entry in
            entry.clipFrames.map { (entry.profile.token, $0) }
        })
        let diagnosticObserver = MeetingPCMRuntimeDiagnostics.ownerVerificationObserver(samples: samples, profiles: candidates,
            streaming: true, clipFramesByToken: clipFramesByToken)
        var decisionOutcome: MeetingOwnerVoiceVerifier.Diagnostics.Outcome?
        let measuredOwnerTokens = MeetingOwnerVoiceVerifier.confirmedTokens(owner: self.runtime.ownerVoiceProfileSnapshot,
            profiles: candidates, policy: self.ownerVerificationPolicy, clipFramesByToken: clipFramesByToken,
            diagnostics: { details in
                decisionOutcome = details.outcome
                diagnosticObserver?(details)
            })
        // Missing evidence cannot promote an unverified identity or restore an earlier
        // decision after a measured contradiction. Complete cached competitors still rank,
        // so a measured rival or replacement can revoke the incumbent immediately.
        self.confirmedOwnerTokens = self.preserveOwnerEvidenceOnInconclusiveRefresh && !self.incompleteOwnerProfiles.isEmpty
            ? self.confirmedOwnerTokens.intersection(measuredOwnerTokens) : measuredOwnerTokens
        self.traceOwnerDecision(encodedProfiles: profiles.count, candidateProfiles: candidates.count,
            fullEvidenceProfiles: evidence.filter { $0.clipFrames == [80_000, 80_000] }.count,
            outcome: decisionOutcome?.rawValue ?? "unavailable", final: final, since: began)
    }

    /// Both successful scoring and optional encoder failure are product decisions.
    /// Keep their scalar trace at the same post-gate boundary as emitted observations.
    private func traceOwnerDecision(encodedProfiles: Int, candidateProfiles: Int,
                                    fullEvidenceProfiles: Int, outcome: String, final: Bool, since began: Double) {
        MeetingTimelineTrace.shared?.record("owner_verification", fields: [
            "attemptID": self.attemptID.uuidString,
            "acceptedThroughSample": String(self.update.acceptedThroughSample),
            "processedThroughSample": String(self.update.processedThroughSample),
            "encodedProfiles": String(encodedProfiles), "candidateProfiles": String(candidateProfiles),
            "fullEvidenceProfiles": String(fullEvidenceProfiles),
            "inconclusiveRefreshProfiles": String(self.incompleteOwnerProfiles.count),
            "policy": self.ownerVerificationPolicy.diagnosticName,
            "decisionOutcome": outcome,
            "confirmedCount": String(self.confirmedOwnerTokens.count),
            "confirmedSlots": self.confirmedOwnerTokens.map(\.label).sorted().joined(separator: ","),
            "wallMilliseconds": String((ProcessInfo.processInfo.systemUptime - began) * 1_000),
            "final": String(final)])
    }

    private func traceDiarizer(_ next: MeetingIncrementalDiarizationUpdate, since began: Double) {
        MeetingTimelineTrace.shared?.record("diarizer_append_end", fields: ["attemptID": self.attemptID.uuidString,
            "wallMilliseconds": String((ProcessInfo.processInfo.systemUptime - began) * 1_000),
            "acceptedThroughSample": String(next.acceptedThroughSample), "processedThroughSample": String(next.processedThroughSample),
            "retainedFromSample": String(next.retainedFromSample), "isFinal": String(next.isFinal),
            "activityCount": String(next.activity.count)], words: next.activity.map {
                .init(text: "slot-\($0.slotIndex)", start: $0.start, end: $0.end)
            })
    }

    private func accept(_ next: MeetingIncrementalDiarizationUpdate, expectedAccepted: Int, final: Bool) throws {
        guard next.acceptedThroughSample == expectedAccepted,
              next.acceptedThroughSample >= self.update.acceptedThroughSample,
              next.processedThroughSample >= self.update.processedThroughSample,
              next.processedThroughSample <= next.acceptedThroughSample,
              next.retainedFromSample == self.update.retainedFromSample,
              next.retainedFromSample <= next.processedThroughSample,
              next.isFinal == final, !final || next.processedThroughSample == next.acceptedThroughSample,
              next.activity.count <= 16_384,
              next.activity.allSatisfy({ (0..<8).contains($0.slotIndex) && $0.start.isFinite && $0.end.isFinite
                  && $0.start >= Double(next.retainedFromSample) / 16_000 && $0.end > $0.start
                  && $0.end <= Double(next.processedThroughSample) / 16_000 + 0.000_001 }) else {
            throw MeetingIncrementalDiarizationError.invalidWatermark
        }
        self.update = next
        self.ownerSamples?.collect(activity: next.activity, processedThroughSample: next.processedThroughSample, final: final)
    }

    private func begin() throws {
        try Task.checkCancellation()
        try self.lock.withLock {
            guard !self.closed else { throw MeetingIncrementalDiarizationError.closed }
            guard !self.finished else { throw MeetingIncrementalDiarizationError.alreadyFinished }
            guard !self.busy else { throw MeetingIncrementalDiarizationError.concurrentOperation }
            self.busy = true
        }
    }
    private func end() { self.lock.withLock { self.busy = false } }
}

/// Optional identity evidence for continuous global slots. Owner-v1 retains its original
/// two 3s clips and 20s lookback. V2 keeps first/latest usable 3-5s clips, half-second quality
/// admission and 16s lookback. It never archives audio or changes native attribution.
/// The controller's one worker owns this value; cancellation drops it with the prepared scope.
nonisolated struct MeetingStreamingOwnerVoiceSamples: Sendable {
    static let sampleRate = 16_000
    static let clipFrames = 3 * sampleRate
    static let maximumPCMFrames = 20 * sampleRate
    static let maximumVoiceFrames = 8 * 2 * clipFrames
    static let adaptiveClipFrames = 5 * sampleRate
    static let qualityBlockFrames = sampleRate / 2
    static let maximumAdaptivePCMFrames = 16 * sampleRate
    static let maximumAdaptiveVoiceFrames = 8 * (2 * adaptiveClipFrames + qualityBlockFrames)
    private let useAdaptiveOwnerEvidence: Bool
    private let epoch: MeetingAnalysisEpochID
    private var pcm: [Float] = []
    private var pcmStart = 0
    private var accepted = 0
    private var consumedThrough = 0
    private var clips = [[[Float]]](repeating: [], count: 8)
    private var pending = [[Float]](repeating: [], count: 8)
    private var first = [[Float]](repeating: [], count: 8)
    private var latest = [[Float]](repeating: [], count: 8)
    private var cleanFrameCounts = [Int](repeating: 0, count: 8)
    private var encodedFrameCounts = [Int](repeating: 0, count: 8)
    private var enabled = true

    init(epoch: MeetingAnalysisEpochID, useAdaptiveOwnerEvidence: Bool = false) {
        self.epoch = epoch; self.useAdaptiveOwnerEvidence = useAdaptiveOwnerEvidence
    }
    var retainedPCMFrames: Int { self.pcm.count }
    var retainActivityFromSample: Int? {
        self.enabled && self.useAdaptiveOwnerEvidence ? max(0, self.consumedThrough - 2_560) : nil
    }
    var retainedVoiceFrames: Int {
        self.useAdaptiveOwnerEvidence
            ? self.first.reduce(0) { $0 + $1.count } + self.latest.reduce(0) { $0 + $1.count }
                + self.pending.reduce(0) { $0 + $1.count }
            : self.clips.flatMap { $0 }.reduce(0) { $0 + $1.count } + self.pending.reduce(0) { $0 + $1.count }
    }
    var excerpts: [MeetingSpeakerVoiceSamples] {
        guard self.enabled else { return [] }
        if self.useAdaptiveOwnerEvidence {
            return (0..<8).compactMap { slot in
                let frames = min(Self.adaptiveClipFrames, self.cleanFrameCounts[slot] / 2)
                guard frames >= Self.clipFrames, self.first[slot].count >= frames, self.latest[slot].count >= frames else { return nil }
                let clips = [Array(self.first[slot].prefix(frames)), Array(self.latest[slot].suffix(frames))]
                guard clips.allSatisfy(Self.isUsableOwnerClip) else { return nil }
                return .init(token: .init(analysisEpochID: self.epoch, label: "slot-\(slot)"), clips: clips)
            }
        }
        return self.clips.enumerated().compactMap { slot, clips in
            clips.count == 2 ? .init(token: .init(analysisEpochID: self.epoch, label: "slot-\(slot)"), clips: clips) : nil
        }
    }

    /// First decision uses two independent 3s clips. Retry after 2s of new clean speech
    /// until 10s, then after each additional 10s. Final collection always admits pending
    /// quality blocks; only frozen legacy recipes bypass the same novelty budget at EOF.
    /// Eight counters and the existing fixed PCM/clip budgets bound all retained evidence.
    mutating func liveExcerpts(final: Bool = false, preserveCadenceAtEOF: Bool = false) -> [MeetingSpeakerVoiceSamples] {
        guard self.enabled, self.useAdaptiveOwnerEvidence else { return [] }
        if final { self.flushAdaptivePending() }
        let slots = Set((0..<8).filter { slot in
            let count = self.cleanFrameCounts[slot], prior = self.encodedFrameCounts[slot]
            return count >= 2 * Self.clipFrames && count > prior
                && (prior == 0 || (final && !preserveCadenceAtEOF) || count - prior >= (prior < 2 * Self.adaptiveClipFrames ? 2 * Self.sampleRate : 10 * Self.sampleRate))
        }.map { "slot-\($0)" })
        guard !slots.isEmpty else { return [] }
        let result = self.excerpts.filter { slots.contains($0.token.label) }
        for slot in 0..<8 where result.contains(where: { $0.token.label == "slot-\(slot)" }) {
            self.encodedFrameCounts[slot] = self.cleanFrameCounts[slot]
        }
        return result
    }

    /// The finished owner transfers its arrays before native model cleanup, avoiding a
    /// second full copy of all eight voices while ASR and diarizer weights still reside.
    mutating func takeExcerpts() -> [MeetingSpeakerVoiceSamples] {
        guard self.enabled else { return [] }
        guard self.useAdaptiveOwnerEvidence else {
            let result = self.excerpts
            self.clips.removeAll(keepingCapacity: false); self.pending.removeAll(keepingCapacity: false)
            return result
        }
        self.flushAdaptivePending()
        var result: [MeetingSpeakerVoiceSamples] = []
        for slot in 0..<8 {
            let frames = min(Self.adaptiveClipFrames, self.cleanFrameCounts[slot] / 2)
            guard frames >= Self.clipFrames, self.first[slot].count >= frames, self.latest[slot].count >= frames else { continue }
            self.first[slot].removeLast(self.first[slot].count - frames)
            self.latest[slot].removeFirst(self.latest[slot].count - frames)
            guard Self.isUsableOwnerClip(self.first[slot]), Self.isUsableOwnerClip(self.latest[slot]) else { continue }
            result.append(.init(token: .init(analysisEpochID: self.epoch, label: "slot-\(slot)"),
                clips: [self.first[slot], self.latest[slot]]))
        }
        self.first = [[Float]](repeating: [], count: 8)
        self.latest = [[Float]](repeating: [], count: 8)
        self.cleanFrameCounts = [Int](repeating: 0, count: 8)
        return result
    }

    private mutating func flushAdaptivePending() {
        for slot in 0..<8 where !self.pending[slot].isEmpty {
            if self.pending[slot].count >= 800, Self.hasUsableOwnerSignal(self.pending[slot]) {
                self.retainAdaptive(self.pending[slot][...], slot: slot)
            }
            self.pending[slot].removeAll(keepingCapacity: false)
        }
    }

    static func isUsableOwnerClip(_ clip: [Float]) -> Bool {
        guard (Self.clipFrames...Self.adaptiveClipFrames).contains(clip.count), clip.allSatisfy(\.isFinite) else { return false }
        return Self.hasUsableOwnerSignal(clip)
    }

    private static func hasUsableOwnerSignal(_ clip: [Float]) -> Bool {
        guard !clip.isEmpty, clip.allSatisfy(\.isFinite) else { return false }
        let mean = clip.reduce(Double.zero) { $0 + Double($1) } / Double(clip.count)
        let variance = clip.reduce(Double.zero) { $0 + pow(Double($1) - mean, 2) } / Double(clip.count)
        return variance >= 0.0042 * 0.0042 && Double(clip.reduce(0) { $0 + (abs($1) >= 0.99 ? 1 : 0) }) < Double(clip.count) / 20
    }

    private mutating func retainAdaptive(_ samples: ArraySlice<Float>, slot: Int) {
        let room = Self.adaptiveClipFrames - self.first[slot].count
        if room > 0 { self.first[slot].append(contentsOf: samples.prefix(room)) }
        if samples.count >= Self.adaptiveClipFrames {
            self.latest[slot] = Array(samples.suffix(Self.adaptiveClipFrames))
        } else {
            let excess = max(0, self.latest[slot].count + samples.count - Self.adaptiveClipFrames)
            if excess > 0 { self.latest[slot].removeFirst(excess) }
            self.latest[slot].append(contentsOf: samples)
        }
        self.cleanFrameCounts[slot] += samples.count
    }

    /// Live and retained V2 admit the same fixed half-second signal-quality blocks.
    /// A bad early/trailing window cannot poison or overwrite the usable reference clips.
    mutating func consumeCleanOwnerSamples(_ samples: ArraySlice<Float>, slot: Int) {
        guard self.enabled, self.useAdaptiveOwnerEvidence else { return }
        guard (0..<8).contains(slot), samples.allSatisfy(\.isFinite) else { self.disable(); return }
        if self.first[slot].capacity < Self.adaptiveClipFrames { self.first[slot].reserveCapacity(Self.adaptiveClipFrames) }
        if self.latest[slot].capacity < Self.adaptiveClipFrames { self.latest[slot].reserveCapacity(Self.adaptiveClipFrames) }
        if self.pending[slot].capacity < Self.qualityBlockFrames { self.pending[slot].reserveCapacity(Self.qualityBlockFrames) }
        var position = samples.startIndex
        while position < samples.endIndex {
            let end = min(samples.endIndex, position + Self.qualityBlockFrames - self.pending[slot].count)
            self.pending[slot].append(contentsOf: samples[position..<end])
            position = end
            if self.pending[slot].count == Self.qualityBlockFrames {
                if Self.hasUsableOwnerSignal(self.pending[slot]) { self.retainAdaptive(self.pending[slot][...], slot: slot) }
                self.pending[slot].removeAll(keepingCapacity: true)
            }
        }
    }

    mutating func append(_ samples: [Float], sourceStartSample: Int) {
        guard self.enabled else { return }
        let maximum = self.useAdaptiveOwnerEvidence ? Self.maximumAdaptivePCMFrames : Self.maximumPCMFrames
        guard sourceStartSample == self.accepted, samples.count <= maximum,
              samples.allSatisfy(\.isFinite) else { self.disable(); return }
        self.accepted += samples.count
        let overflow = max(0, self.pcm.count + samples.count - maximum)
        if self.useAdaptiveOwnerEvidence, overflow > 0 { self.disable(); return }
        if overflow > 0 { self.pcm.removeFirst(overflow); self.pcmStart += overflow }
        self.pcm.append(contentsOf: samples)
    }

    mutating func collect(activity: [MeetingNemotronSpeakerSegment], processedThroughSample: Int, final: Bool = false) {
        guard self.enabled, processedThroughSample >= self.consumedThrough,
              processedThroughSample <= self.accepted else { return }
        // Future frames are not scored yet. Retain the trailing edge until a later update,
        // while excluding every actual voice turn's leading/trailing 160 milliseconds.
        let edge = 2_560
        // Native intervals admit a newly open voice only after 200ms. Its padded left
        // edge must be visible before preceding PCM becomes immutable identity evidence.
        // Once final, all accepted intervals are known and only turn-edge padding remains.
        let horizon = self.useAdaptiveOwnerEvidence && !final ? edge + 3_200 : edge
        let through = max(self.consumedThrough, processedThroughSample - horizon)
        let lower = max(self.consumedThrough, self.pcmStart)
        guard through > lower else { return }
        if self.useAdaptiveOwnerEvidence {
            for entry in Self.cleanRanges(activity: activity, lower: lower, through: through, sourceEnd: processedThroughSample) {
                for range in entry.ranges {
                    let samples = self.pcm[(range.lowerBound - self.pcmStart)..<(range.upperBound - self.pcmStart)]
                    self.consumeCleanOwnerSamples(samples, slot: entry.slot)
                }
            }
            self.consumedThrough = through
            let remove = min(self.pcm.count, max(0, through - self.pcmStart))
            if remove > 0 { self.pcm.removeFirst(remove); self.pcmStart += remove }
            return
        }
        let valid = activity.filter { (0..<8).contains($0.slotIndex) && $0.start.isFinite && $0.end.isFinite
            && $0.start >= 0 && $0.end > $0.start && $0.end <= Double(processedThroughSample) / 16_000 + 0.000_001
            && $0.end * 16_000 > Double(lower - edge) && $0.start * 16_000 < Double(through + edge) }
        func union(_ ranges: [Range<Int>]) -> [Range<Int>] {
            var result: [Range<Int>] = []
            for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                if let last = result.last, range.lowerBound <= last.upperBound {
                    result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
                } else { result.append(range) }
            }
            return result
        }
        for slot in 0..<8 where self.clips[slot].count < 2 {
            let own = union(valid.filter { $0.slotIndex == slot }.compactMap { segment in
                let start = max(lower, Int((segment.start * 16_000).rounded(.up)) + edge)
                let end = min(through, Int((segment.end * 16_000).rounded(.down)) - edge)
                return start < end ? start..<end : nil
            })
            let blocked = union(valid.filter { $0.slotIndex != slot }.map { segment in
                max(0, Int((segment.start * 16_000).rounded(.down)) - edge)..<(Int((segment.end * 16_000).rounded(.up)) + edge)
            })
            var ranges: [Range<Int>] = []
            var blockedIndex = 0
            for range in own {
                var cursor = range.lowerBound
                while blockedIndex < blocked.count, blocked[blockedIndex].upperBound <= cursor { blockedIndex += 1 }
                var index = blockedIndex
                while index < blocked.count, blocked[index].lowerBound < range.upperBound {
                    if blocked[index].lowerBound > cursor { ranges.append(cursor..<min(range.upperBound, blocked[index].lowerBound)) }
                    cursor = max(cursor, blocked[index].upperBound)
                    if cursor >= range.upperBound { break }
                    index += 1
                }
                if cursor < range.upperBound { ranges.append(cursor..<range.upperBound) }
            }
            var usedThrough = lower
            for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                var start = max(usedThrough, range.lowerBound)
                let end = min(range.upperBound, self.pcmStart + self.pcm.count)
                guard start < end else { continue }
                while start < end, self.clips[slot].count < 2 {
                    let finish = min(end, start + Self.clipFrames - self.pending[slot].count)
                    self.pending[slot].append(contentsOf: self.pcm[(start - self.pcmStart)..<(finish - self.pcmStart)])
                    start = finish
                    if self.pending[slot].count == Self.clipFrames {
                        let clip = self.pending[slot]
                        self.pending[slot].removeAll(keepingCapacity: false)
                        let mean = clip.reduce(Double.zero) { $0 + Double($1) } / Double(clip.count)
                        let variance = clip.reduce(Double.zero) { $0 + pow(Double($1) - mean, 2) } / Double(clip.count)
                        if variance >= 0.0042 * 0.0042 && clip.filter({ abs($0) >= 0.99 }).count < clip.count / 20 {
                            self.clips[slot].append(clip)
                        }
                    }
                }
                usedThrough = max(usedThrough, end)
            }
        }
        self.consumedThrough = through
        let remove = min(self.pcm.count, max(0, through - self.pcmStart))
        if remove > 0 { self.pcm.removeFirst(remove); self.pcmStart += remove }
    }

    struct CleanSlotRanges: Sendable { let slot: Int; let ranges: [Range<Int>] }

    /// One acoustic admission rule for live V2 and retained V2. Retained retry reads native
    /// speech ranges in bounded buffers, without acquiring a full-recording Float buffer.
    static func cleanRanges(activity: [MeetingNemotronSpeakerSegment], lower: Int, through: Int,
                            sourceEnd: Int) -> [CleanSlotRanges] {
        let edge = 2_560
        guard lower >= 0, through > lower, sourceEnd >= through, sourceEnd <= Int.max / 2 else { return [] }
        let valid = activity.filter { (0..<8).contains($0.slotIndex) && $0.start.isFinite && $0.end.isFinite
            && $0.start >= 0 && $0.end > $0.start && $0.end <= Double(sourceEnd) / 16_000 + 0.000_001
            && $0.end * 16_000 > Double(lower - edge) && $0.start * 16_000 < Double(through + edge) }
        func union(_ ranges: [Range<Int>]) -> [Range<Int>] {
            var result: [Range<Int>] = []
            for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                if let last = result.last, range.lowerBound <= last.upperBound {
                    result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
                } else { result.append(range) }
            }
            return result
        }
        return (0..<8).compactMap { slot in
            let own = union(valid.filter { $0.slotIndex == slot }.compactMap { segment in
                let start = max(lower, Int((segment.start * 16_000).rounded(.up)) + edge)
                let end = min(through, Int((segment.end * 16_000).rounded(.down)) - edge)
                return start < end ? start..<end : nil
            })
            let blocked = union(valid.filter { $0.slotIndex != slot }.map { segment in
                max(0, Int((segment.start * 16_000).rounded(.down)) - edge)..<(Int((segment.end * 16_000).rounded(.up)) + edge)
            })
            var ranges: [Range<Int>] = []
            var blockedIndex = 0
            for range in own {
                var cursor = range.lowerBound
                while blockedIndex < blocked.count, blocked[blockedIndex].upperBound <= cursor { blockedIndex += 1 }
                var index = blockedIndex
                while index < blocked.count, blocked[index].lowerBound < range.upperBound {
                    if blocked[index].lowerBound > cursor { ranges.append(cursor..<min(range.upperBound, blocked[index].lowerBound)) }
                    cursor = max(cursor, blocked[index].upperBound)
                    if cursor >= range.upperBound { break }
                    index += 1
                }
                if cursor < range.upperBound { ranges.append(cursor..<range.upperBound) }
            }
            return ranges.isEmpty ? nil : .init(slot: slot, ranges: ranges)
        }
    }

    private mutating func disable() {
        self.enabled = false
        self.pcm.removeAll(keepingCapacity: false)
        self.pending.removeAll(keepingCapacity: false)
        self.clips.removeAll(keepingCapacity: false)
        self.first.removeAll(keepingCapacity: false)
        self.latest.removeAll(keepingCapacity: false)
        self.cleanFrameCounts.removeAll(keepingCapacity: false)
    }
}
