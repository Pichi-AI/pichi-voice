import Foundation

/// Joins the existing privacy admission owner with bounded, word-timed speaker refinement.
/// It owns protected text and scalar cursors only, never PCM or an additional redaction pass
/// over previously published text. The capture owner serializes emissions and applies patches.
actor MeetingStreamingTranscriptState {
    struct Limits: Sendable {
        let maximumPendingWords: Int
        let maximumPendingTextBytes: Int
        let maximumPendingSeconds: TimeInterval
        let tail: MeetingStreamingProtectedWordTail.Limits

        init(maximumPendingWords: Int = 2_048, maximumPendingTextBytes: Int = 524_288,
             maximumPendingSeconds: TimeInterval = 120,
             tail: MeetingStreamingProtectedWordTail.Limits = .init()) {
            self.maximumPendingWords = maximumPendingWords
            self.maximumPendingTextBytes = maximumPendingTextBytes
            self.maximumPendingSeconds = maximumPendingSeconds
            self.tail = tail
        }
    }

    struct Diagnostics: Sendable {
        let acceptedThroughSample: Int
        let asrStableThroughSample: Int
        let diarizationProcessedThroughSample: Int
        let privacySafeThroughSample: Int
        let committedThroughSample: Int
        let pendingProtectedWords: Int
        let retainedAttributionWords: Int
        let insertedWords: Int
        let revisedWords: Int
        let privacyMilliseconds: Double
        let attributionMilliseconds: Double
        let isFinal: Bool
    }

    struct Emission: Sendable {
        let safeBatch: MeetingPCMTranscriptBatch
        let hasSpeakerIdentityChanges: Bool
        let hasPreviewChanges: Bool
        /// Call the runtime eviction operation after its observation callback has returned.
        let retainActivityFromSample: Int
        let diagnostics: Diagnostics
    }

    enum Failure: Error, Equatable {
        case invalidConfiguration
        case invalidObservation
        case unsupportedNativeTiming
        case regressedCursor
        case staleObservation
        case concurrentOperation
        case pendingWordLimit
        case pendingTextLimit
        case pendingTimeLimit
        case speakerLimit
        case alreadyFinished
        case cancelled
        case failed
    }

    private enum Phase { case active, finished, cancelled, failed }
    private let attemptID: UUID
    private let track: MeetingAudioTrack
    private let epoch: MeetingAnalysisEpochID
    private let privacyContext: MeetingTranscriptPrivacyContext?
    private let limits: Limits
    private var tail: MeetingStreamingProtectedWordTail
    private var pending: [MeetingTranscriptSegment] = []
    private var speakers: [MeetingSessionSpeaker]
    private var confirmedLocalUserTokens: Set<MeetingBackendSpeakerToken>?
    private var phase: Phase = .active
    private var isProcessing = false
    private var acceptedThroughSample = 0
    private var processedThroughSample = 0
    private var asrStableThroughSample = 0
    private var privacySafeThroughSample = 0
    private var privacySafeThroughTime: TimeInterval = 0
    private var lastRawWordEndSample = 0
    private var acknowledgedThroughSample = 0
    private var emittedProtectedSourceThroughSample = 0
    private var isComplete = true
    private let previewID = UUID()
    private var speechPreview: MeetingLivePartial?
    private var preview: MeetingLivePartial?
    private(set) var metadataDiagnostics: Diagnostics?
    var retainActivityFromSample: Int { self.acknowledgedThroughSample }

    init(attemptID: UUID, track: MeetingAudioTrack,
         configuration: MeetingFinalProcessingConfiguration,
         privacyContext: MeetingTranscriptPrivacyContext?,
         priorSpeakers: [MeetingSessionSpeaker] = [], limits: Limits = .init(),
         speakerNameFormat: String = PichiLocalization.text("Speaker %lld")) throws {
        guard configuration.speakerLabelsEnabled,
              configuration.effectiveSpeakerProcessingMode == .streaming,
              track.kind == .microphone,
              limits.maximumPendingWords > 0, limits.maximumPendingTextBytes > 0,
              limits.maximumPendingSeconds.isFinite, limits.maximumPendingSeconds > 0 else {
            throw Failure.invalidConfiguration
        }
        self.attemptID = attemptID
        self.track = track
        self.epoch = .init(trackID: track.id, ordinal: 0)
        self.privacyContext = privacyContext
        self.limits = limits
        self.speakers = Self.identityOnly(priorSpeakers)
        self.tail = try .init(attemptID: attemptID, epoch: self.epoch,
            speakerNameFormat: speakerNameFormat, policy: configuration.speakerAttributionPolicy ?? .standard,
            limits: limits.tail, priorSpeakers: priorSpeakers)
    }

    /// A nil ASR cursor denotes an acoustic-only callback. It may refine existing words,
    /// but cannot declare an unrecognized captured prefix or silence ASR-stable.
    func observe(_ observation: MeetingStreamingPCMObservation) async throws -> Emission {
        try await self.consume(observation, final: false)
    }

    /// The streaming state is the sole owner of the displayed protected composition.
    /// A growing hypothesis cannot replace earlier safe words waiting for speaker scoring.
    func observeSpeechPreview(_ speech: MeetingPCMTranscriptBatch) async throws -> MeetingLivePartial? {
        try self.checkActive()
        guard !self.isProcessing else { throw Failure.concurrentOperation }
        if let identity = speech.speechObservationIdentity {
            guard identity.attemptID == self.attemptID, identity.epochID.trackID == self.track.id else {
                throw Failure.staleObservation
            }
        }
        self.isProcessing = true
        defer { self.isProcessing = false }
        var source = speech
        source.sourceTrack = self.track
        let protected: MeetingLivePartial?
        if let privacyContext = self.privacyContext {
            protected = try await privacyContext.previewSpeech(source, preservingPendingPreview: true)
        } else {
            protected = source.speechPreview(id: self.previewID)
        }
        try self.checkActive()
        self.speechPreview = protected
        self.preview = self.protectedPendingPreview(tail: protected)
        return self.preview
    }

    /// The runtime must join ASR and flush its acoustic right context first. This drains only
    /// the original privacy lexical tail and bounded protected attribution tail, exactly once.
    func finish(_ observation: MeetingStreamingPCMObservation) async throws -> Emission {
        try await self.consume(observation, final: true)
    }

    func cancel() {
        self.phase = .cancelled
        self.pending.removeAll(keepingCapacity: false)
        self.speakers.removeAll(keepingCapacity: false)
        self.confirmedLocalUserTokens = nil
        self.speechPreview = nil
        self.preview = nil
        self.tail.cancel()
    }

    private func consume(_ observation: MeetingStreamingPCMObservation, final: Bool) async throws -> Emission {
        try self.checkActive()
        guard !self.isProcessing else { throw Failure.concurrentOperation }
        self.isProcessing = true
        defer { self.isProcessing = false }
        do {
            try self.validate(observation, final: final)
            let priorIdentities = self.speakers
            if let tokens = observation.confirmedLocalUserTokens {
                guard tokens.count <= self.limits.tail.maximumSpeakers,
                      tokens.allSatisfy({ $0.analysisEpochID == self.epoch && !$0.label.isEmpty }) else {
                    throw Failure.invalidObservation
                }
                self.confirmedLocalUserTokens = tokens
            }
            let priorPreview = self.preview
            if observation.asrStableThroughSample != nil { self.speechPreview = nil }
            var privacyMilliseconds = 0.0
            let oldASRCursor = self.asrStableThroughSample
            if let asrCursor = observation.asrStableThroughSample { self.asrStableThroughSample = asrCursor }
            self.acceptedThroughSample = observation.acceptedThroughSample
            self.processedThroughSample = observation.processedThroughSample
            self.isComplete = self.isComplete && observation.batch.isComplete

            // Legacy identity-only revisions still refine already admitted participants.
            if observation.batch.segments.isEmpty, !observation.batch.speakers.isEmpty {
                let existingIDs = Set(self.speakers.map(\.id))
                guard observation.batch.speakers.allSatisfy({ existingIDs.contains($0.id) }),
                      Set(observation.batch.speakers.map(\.id)).count == observation.batch.speakers.count else {
                    throw Failure.invalidObservation
                }
                // This additive path can change owner flags on existing IDs only. New speaker
                // metadata still enters through the ordinary speech privacy gate below.
                var identity = MeetingPCMTranscriptBatch(segments: [], speakers: observation.batch.speakers)
                for index in identity.speakers.indices {
                    identity.speakers[index].diarizationEmbedding = nil
                    identity.speakers[index].identityCandidates = []
                }
                try self.mergeSpeakers(identity, updatesOwnerIdentity: true)
            }
            if !observation.batch.segments.isEmpty {
                try self.validateRawWords(observation.batch, previousASRCursor: oldASRCursor)
                var source = observation.batch
                source.sourceTrack = self.track
                // Raw window identity remains useful to privacy preview admission. The
                // attribution tail receives a separate global epoch identity below.
                let safe: MeetingPCMTranscriptBatch
                if let privacyContext = self.privacyContext {
                    let started = ContinuousClock.now
                    MeetingTimelineTrace.shared?.record("privacy_begin", fields: ["attemptID": self.attemptID.uuidString,
                        "operation": "canonical-redact", "inputWords": String(source.segments.count)])
                    safe = try await privacyContext.redact(source)
                    MeetingTimelineTrace.shared?.record("privacy_end", fields: ["attemptID": self.attemptID.uuidString,
                        "operation": "canonical-redact", "outputWords": String(safe.segments.count),
                        "wallMilliseconds": String(Self.milliseconds(since: started))])
                    privacyMilliseconds += Self.milliseconds(since: started)
                } else { safe = source }
                try self.checkActive()
                try self.mergeSpeakers(safe)
                self.pending.append(contentsOf: safe.segments)
                self.lastRawWordEndSample = max(self.lastRawWordEndSample,
                    source.segments.compactMap { $0.nativeTiming?.end }.map(Self.ceilingSample).max() ?? 0)
            }
            // An actual sealed empty decoder result is a nonterminal speech boundary.
            // Acoustic-only progress and incomplete/rejected prefixes cannot authorize it.
            // Text privacy can settle before speaker scoring; its protected words still
            // wait below for their complete acoustic envelopes before canonical insertion.
            if !final, let range = observation.sealedEmptyASRRange,
               observation.batch.isComplete, self.isComplete,
               range.lowerBound >= self.lastRawWordEndSample,
               let privacyContext = self.privacyContext {
                let started = ContinuousClock.now
                MeetingTimelineTrace.shared?.record("privacy_begin", fields: ["attemptID": self.attemptID.uuidString,
                    "operation": "speech-boundary"])
                let settled = try await privacyContext.admitSpeechBoundary()
                MeetingTimelineTrace.shared?.record("privacy_end", fields: ["attemptID": self.attemptID.uuidString,
                    "operation": "speech-boundary", "outputWords": String(settled?.segments.count ?? 0),
                    "wallMilliseconds": String(Self.milliseconds(since: started))])
                privacyMilliseconds += Self.milliseconds(since: started)
                try self.checkActive()
                if let settled {
                    try self.mergeSpeakers(settled)
                    self.pending.append(contentsOf: settled.segments)
                }
            }
            if final, let privacyContext = self.privacyContext {
                let started = ContinuousClock.now
                MeetingTimelineTrace.shared?.record("privacy_begin", fields: ["attemptID": self.attemptID.uuidString,
                    "operation": "finish"])
                let remainder = try await privacyContext.finish()
                MeetingTimelineTrace.shared?.record("privacy_end", fields: ["attemptID": self.attemptID.uuidString,
                    "operation": "finish", "outputWords": String(remainder?.segments.count ?? 0),
                    "wallMilliseconds": String(Self.milliseconds(since: started))])
                privacyMilliseconds += Self.milliseconds(since: started)
                try self.checkActive()
                if let remainder {
                    try self.mergeSpeakers(remainder)
                    self.pending.append(contentsOf: remainder.segments)
                    self.isComplete = self.isComplete && remainder.isComplete
                }
            }
            try self.checkActive()
            let heldStart = await self.privacyContext?.earliestHeldWordStart
            let pendingPreview = await self.privacyContext?.pendingPreview
            try self.checkActive()
            try self.validatePending(checkTime: false)

            let asrSeconds = Double(self.asrStableThroughSample) / 16_000
            let diarizationSeconds = Double(self.processedThroughSample) / 16_000
            let availableThrough = min(asrSeconds, diarizationSeconds)
            // Preserve exact word envelopes, including overlapping native word bounds. An
            // overlap cluster crossing a scored/privacy boundary waits as a whole; admitting
            // its first word then moving the safe prefix backwards would violate publication.
            var admittedCount = self.pending.prefix { word in
                guard let timing = word.nativeTiming else { return false }
                return timing.end <= availableThrough + 1e-9
                    && word.end.seconds <= availableThrough + 0.001
            }.count
            var prefixRequiredEnds: [TimeInterval] = []
            prefixRequiredEnds.reserveCapacity(admittedCount)
            for word in self.pending.prefix(admittedCount) {
                // Native intervals may be nested; the most recent word is not necessarily
                // the longest. Millisecond canonical rounding retains its existing slack.
                prefixRequiredEnds.append(max(prefixRequiredEnds.last ?? 0,
                    word.nativeTiming!.end, word.end.seconds - 0.001))
            }
            while admittedCount > 0 {
                let boundary = min(availableThrough, heldStart ?? availableThrough,
                    admittedCount < self.pending.count
                        ? self.pending[admittedCount].nativeTiming!.start : availableThrough)
                if prefixRequiredEnds[admittedCount - 1] <= boundary + 1e-9 { break }
                admittedCount -= 1
            }
            let admitted = Array(self.pending.prefix(admittedCount))
            self.pending.removeFirst(admittedCount)
            try self.validatePending()
            let pendingStart = self.pending.first?.nativeTiming?.start
            let safeSeconds = min(asrSeconds, heldStart ?? asrSeconds, pendingStart ?? asrSeconds)
            let safeSample = Self.floorSample(safeSeconds)
            guard safeSeconds >= self.privacySafeThroughTime,
                  safeSample >= self.privacySafeThroughSample else { throw Failure.regressedCursor }
            self.privacySafeThroughTime = safeSeconds
            self.privacySafeThroughSample = safeSample
            if final {
                guard self.pending.isEmpty, heldStart == nil,
                      self.asrStableThroughSample == self.acceptedThroughSample,
                      self.processedThroughSample == self.acceptedThroughSample,
                      self.privacySafeThroughSample == self.acceptedThroughSample else {
                    throw Failure.invalidObservation
                }
            }
            var safe = MeetingPCMTranscriptBatch(segments: admitted, speakers: self.speakers,
                isComplete: self.isComplete)
            if let tokens = self.confirmedLocalUserTokens {
                safe.speakers = MeetingTranscriptAssembler.applyingLocalUserTokens(to: safe.speakers,
                    attemptID: self.attemptID, tokens: tokens, speakerNameFormat: self.tail.speakerNameFormat)
                try self.mergeSpeakers(safe, updatesOwnerIdentity: true)
            }
            safe.speechObservationIdentity = .init(attemptID: self.attemptID, epochID: self.epoch)
            let marks = MeetingStreamingProtectedWordTail.Watermarks(asrStableThrough: asrSeconds,
                diarizationProcessedThrough: diarizationSeconds,
                privacySafeThrough: safeSeconds)
            let attributionStarted = ContinuousClock.now
            if !safe.segments.isEmpty {
                // ASR can seal a window before all its words are acoustically scored. Those
                // private words wait above; their first canonical publication must contain
                // evidence from the complete scored envelope, rather than the earlier empty
                // assignment. Never refresh native evidence of already-published words.
                let owners = Dictionary(uniqueKeysWithValues: self.speakers.map { ($0.id, $0.isLocalUser) })
                safe = try MeetingPCMRecordingAttribution.assemble(transcript: safe,
                    activity: observation.activity, epoch: self.epoch, attemptID: self.attemptID,
                    duration: diarizationSeconds, speakerNameFormat: self.tail.speakerNameFormat,
                    speakerAttributionPolicy: self.tail.policy)
                for index in safe.speakers.indices {
                    if let isLocalUser = owners[safe.speakers[index].id] {
                        safe.speakers[index].isLocalUser = isLocalUser
                    }
                }
                try self.mergeSpeakers(safe)
            }
            let updated: MeetingStreamingProtectedWordTail.Update
            if final {
                updated = try self.tail.finish(safeWords: safe, activity: observation.activity,
                    watermarks: marks, attemptID: self.attemptID, epoch: self.epoch,
                    activityAvailableFrom: Double(observation.retainedFromSample) / 16_000)
            } else {
                updated = try self.tail.update(safeWords: safe, activity: observation.activity,
                    watermarks: marks, attemptID: self.attemptID, epoch: self.epoch,
                    activityAvailableFrom: Double(observation.retainedFromSample) / 16_000)
            }
            let attributionMilliseconds = Self.milliseconds(since: attributionStarted)
            let identities = self.confirmedLocalUserTokens.map {
                MeetingTranscriptAssembler.applyingLocalUserTokens(to: updated.speakers,
                    attemptID: self.attemptID, tokens: $0, speakerNameFormat: self.tail.speakerNameFormat)
            } ?? updated.speakers
            var batch = MeetingPCMTranscriptBatch(segments: updated.inserted, speakers: identities,
                isComplete: self.isComplete)
            batch.speakerNameFormat = self.tail.speakerNameFormat
            batch.speakerRevisions = updated.revisions
            batch.sourceTrack = self.track
            // Physical coverage can retire estimates spanning native word gaps, but only
            // after the protected checkpoint joins. It never derives from a preview end.
            let protectedThrough = min(self.asrStableThroughSample,
                self.processedThroughSample, self.privacySafeThroughSample)
            if self.isComplete, protectedThrough > self.emittedProtectedSourceThroughSample {
                batch.protectedSourceThroughSample = protectedThrough
                self.emittedProtectedSourceThroughSample = protectedThrough
            }
            // Privacy-approved words can be visible while their acoustic envelopes await
            // speaker scoring. The lexical-tail display is disjoint from these canonical-safe
            // pending words. Neither display changes canonical admission or its safe cursor.
            self.preview = final ? nil : self.protectedPendingPreview(tail: self.speechPreview ?? pendingPreview)
            batch.livePreview = self.preview
            let retain = Self.floorSample(min(updated.retainActivityFrom,
                heldStart ?? updated.retainActivityFrom, pendingStart ?? updated.retainActivityFrom))
            guard retain >= self.acknowledgedThroughSample else { throw Failure.regressedCursor }
            self.acknowledgedThroughSample = retain
            try self.mergeSpeakers(batch, updatesOwnerIdentity: self.confirmedLocalUserTokens != nil)
            batch.speakers = self.speakers
            let hasSpeakerIdentityChanges = self.speakers != priorIdentities
            if final {
                self.phase = .finished
                self.speakers.removeAll(keepingCapacity: false)
                self.confirmedLocalUserTokens = nil
            }
            try Task.checkCancellation()
            let diagnostics = Diagnostics(acceptedThroughSample: self.acceptedThroughSample,
                    asrStableThroughSample: self.asrStableThroughSample,
                    diarizationProcessedThroughSample: self.processedThroughSample,
                    privacySafeThroughSample: self.privacySafeThroughSample,
                    committedThroughSample: Self.floorSample(updated.committedThrough),
                    pendingProtectedWords: self.pending.count,
                    retainedAttributionWords: updated.retainedWordCount,
                    insertedWords: updated.inserted.count, revisedWords: updated.revisions.count,
                    privacyMilliseconds: privacyMilliseconds, attributionMilliseconds: attributionMilliseconds, isFinal: final)
            MeetingTimelineTrace.shared?.record("protected_admission", fields: ["attemptID": self.attemptID.uuidString,
                "acceptedThroughSample": String(self.acceptedThroughSample), "asrStableThroughSample": String(self.asrStableThroughSample),
                "diarizationProcessedThroughSample": String(self.processedThroughSample), "privacySafeThroughSample": String(safeSample),
                "protectedThroughSample": String(protectedThrough), "pendingProtectedWords": String(self.pending.count),
                "insertedWords": String(updated.inserted.count), "speakerRevisedWords": String(updated.revisions.count),
                "privacyMilliseconds": String(privacyMilliseconds), "attributionMilliseconds": String(attributionMilliseconds),
                "isFinal": String(final)], text: batch.segments.map(\.text).joined(separator: " "),
                words: batch.segments.map { .init(text: $0.text, start: $0.start.seconds, end: $0.end.seconds,
                    wordID: String(describing: $0.id), speakerID: $0.speakerID.map { String(describing: $0) }) })
            if let trace = MeetingTimelineTrace.shared {
                for revision in batch.speakerRevisions {
                    trace.record("speaker_revision", fields: ["attemptID": self.attemptID.uuidString,
                        "wordID": String(describing: revision.segmentID),
                        "speakerID": revision.speakerID.map { String(describing: $0) } ?? "unassigned"])
                }
            }
            self.metadataDiagnostics = diagnostics
            return .init(safeBatch: batch, hasSpeakerIdentityChanges: hasSpeakerIdentityChanges,
                hasPreviewChanges: self.preview != priorPreview,
                retainActivityFromSample: retain, diagnostics: diagnostics)
        } catch {
            // Privacy may have consumed an admitted lexical tail before a later check fails.
            // Retrying it could duplicate words or weaken the safe prefix. Fail this attempt
            // explicitly; the capture owner joins native work and preserves prior checkpoints.
            if case .cancelled = self.phase {} else { self.phase = .failed }
            self.pending.removeAll(keepingCapacity: false)
            self.speakers.removeAll(keepingCapacity: false)
            self.confirmedLocalUserTokens = nil
            self.speechPreview = nil
            self.preview = nil
            self.tail.cancel()
            throw error
        }
    }

    private func validate(_ observation: MeetingStreamingPCMObservation, final: Bool) throws {
        guard observation.isFinal == final,
              observation.acceptedThroughSample >= 0,
              observation.acceptedThroughSample <= Int.max / 2,
              observation.processedThroughSample >= 0,
              observation.processedThroughSample <= observation.acceptedThroughSample,
              observation.retainedFromSample >= 0,
              observation.retainedFromSample <= self.acknowledgedThroughSample,
              observation.batch.speakerRevisions.isEmpty,
              observation.batch.sourceTrack.map({ $0.id == self.track.id }) ?? true else {
            throw Failure.invalidObservation
        }
        guard observation.acceptedThroughSample >= self.acceptedThroughSample,
              observation.processedThroughSample >= self.processedThroughSample else { throw Failure.regressedCursor }
        if let cursor = observation.asrStableThroughSample {
            guard cursor >= self.asrStableThroughSample else { throw Failure.regressedCursor }
            guard cursor <= observation.acceptedThroughSample else { throw Failure.invalidObservation }
        } else {
            guard observation.batch.segments.isEmpty, !final else { throw Failure.invalidObservation }
        }
        if let range = observation.sealedEmptyASRRange {
            guard !final, observation.batch.segments.isEmpty, observation.batch.isComplete,
                  let cursor = observation.asrStableThroughSample,
                  range.lowerBound == self.asrStableThroughSample,
                  range.upperBound == cursor, range.upperBound > range.lowerBound else {
                throw Failure.invalidObservation
            }
        }
        if let identity = observation.batch.speechObservationIdentity {
            guard identity.attemptID == self.attemptID, identity.epochID.trackID == self.track.id else {
                throw Failure.staleObservation
            }
        }
    }

    private func validateRawWords(_ batch: MeetingPCMTranscriptBatch, previousASRCursor: Int) throws {
        guard batch.segments.count <= self.limits.maximumPendingWords else { throw Failure.pendingWordLimit }
        guard batch.speakers.count <= self.limits.tail.maximumSpeakers,
              Set(batch.speakers.map(\.id)).count == batch.speakers.count else { throw Failure.invalidObservation }
        var lastStart = Double(previousASRCursor) / 16_000
        var bytes = 0
        var IDs = Set<MeetingTranscriptSegmentID>()
        var nativeIDs = Set<String>()
        for word in batch.segments {
            for count in [word.text.utf8.count, word.originalText?.utf8.count ?? 0] {
                guard count <= self.limits.maximumPendingTextBytes - bytes else { throw Failure.pendingTextLimit }
                bytes += count
            }
            guard let timing = word.nativeTiming, (word.nativePrecision == .word || word.nativePrecision == .utterance),
                  let nativeID = word.nativeUnitID, !nativeID.isEmpty else { throw Failure.unsupportedNativeTiming }
            guard word.sourceTrackID == self.track.id,
                  MeetingEvidenceInterval.isValid(start: timing.start, end: timing.end),
                  timing.start + 0.001 >= lastStart,
                  timing.end <= Double(self.asrStableThroughSample) / 16_000 + 1e-9,
                  word.start.seconds.isFinite, word.end.seconds.isFinite,
                  word.start.seconds >= 0, word.end.seconds > word.start.seconds,
                  word.end.seconds <= Double(self.asrStableThroughSample) / 16_000 + 0.001,
                  word.nativeSpeakerAssignment?.tokens.allSatisfy({ $0.analysisEpochID == self.epoch }) ?? true,
                  IDs.insert(word.id).inserted, nativeIDs.insert(nativeID).inserted,
                  word.status == .final, !word.text.isEmpty else { throw Failure.invalidObservation }
            lastStart = timing.start
        }
    }

    private func validatePending(checkTime: Bool = true) throws {
        guard self.pending.count <= self.limits.maximumPendingWords else { throw Failure.pendingWordLimit }
        var bytes = 0
        var previous = -1.0
        var IDs = Set<MeetingTranscriptSegmentID>()
        for word in self.pending {
            guard let timing = word.nativeTiming, (word.nativePrecision == .word || word.nativePrecision == .utterance) else { throw Failure.unsupportedNativeTiming }
            guard timing.start >= previous, IDs.insert(word.id).inserted else { throw Failure.invalidObservation }
            previous = timing.start
            for count in [word.text.utf8.count, word.originalText?.utf8.count ?? 0] {
                guard count <= self.limits.maximumPendingTextBytes - bytes else { throw Failure.pendingTextLimit }
                bytes += count
            }
        }
        // Silence advances physical/ASR cursors without consuming more text memory. Bound
        // the actual queued word envelope, never wall-clock age of a held privacy token.
        if checkTime, let start = self.pending.first?.nativeTiming?.start,
           let end = self.pending.compactMap({ $0.nativeTiming?.end }).max(),
           end - start > self.limits.maximumPendingSeconds { throw Failure.pendingTimeLimit }
    }

    private func protectedPendingPreview(tail: MeetingLivePartial?) -> MeetingLivePartial? {
        let pendingText = self.pending.map(\.text).joined(separator: " ")
        let text = [pendingText, tail?.text ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        guard !text.isEmpty else { return nil }
        let starts = self.pending.map { $0.start.seconds } + (tail.map { [$0.start] } ?? [])
        guard let start = starts.min() else { return nil }
        // A partial lexical tail can have approved text without an approved endpoint.
        // In that case only complete pending fragments contribute audio coverage.
        let ends = self.pending.map { $0.end.seconds } + (tail?.end.map { [$0] } ?? [])
        return MeetingLivePartial(id: self.previewID, text: text, start: start, end: ends.max())
    }

    private func checkActive() throws {
        try Task.checkCancellation()
        switch self.phase {
        case .active: break
        case .finished: throw Failure.alreadyFinished
        case .cancelled: throw Failure.cancelled
        case .failed: throw Failure.failed
        }
    }

    private func mergeSpeakers(_ batch: MeetingPCMTranscriptBatch, updatesOwnerIdentity: Bool = false) throws {
        guard Set(self.speakers.map(\.id)).union(batch.speakers.map(\.id)).count <= self.limits.tail.maximumSpeakers else {
            throw Failure.speakerLimit
        }
        var identities = batch
        if !updatesOwnerIdentity {
            // Raw ASR and a delayed privacy lexical tail carry the earlier anonymous flags.
            // Only the separate verified-identity publication can promote/revoke an owner.
            let ownerFlags = Dictionary(uniqueKeysWithValues: self.speakers.map { ($0.id, $0.isLocalUser) })
            for index in identities.speakers.indices {
                if let isLocalUser = ownerFlags[identities.speakers[index].id] {
                    identities.speakers[index].isLocalUser = isLocalUser
                }
            }
        }
        self.speakers = Self.identityOnly(identities.mergingSpeakers(into: self.speakers,
            speakerNameFormat: self.tail.speakerNameFormat))
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let value = start.duration(to: .now).components
        return Double(value.seconds) * 1_000 + Double(value.attoseconds) / 1_000_000_000_000_000
    }

    private static func identityOnly(_ speakers: [MeetingSessionSpeaker]) -> [MeetingSessionSpeaker] {
        speakers.map { source in
            var speaker = source
            speaker.diarizationEmbedding = nil
            return speaker
        }
    }

    private static func ceilingSample(_ seconds: TimeInterval) -> Int {
        Int((seconds * 16_000 - 1e-7).rounded(.up))
    }

    private static func floorSample(_ seconds: TimeInterval) -> Int {
        Int((seconds * 16_000 + 1e-7).rounded(.down))
    }
}
