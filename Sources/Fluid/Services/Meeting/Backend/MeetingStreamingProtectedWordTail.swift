import Foundation

/// Reconciles only already privacy-admitted text. The capture/runtime owner supplies complete
/// acoustic snapshots for the acknowledged interval and serializes calls for one frozen attempt.
/// This value owns no audio, raw ASR hypotheses, privacy actor, model, persistence or UI.
nonisolated struct MeetingStreamingProtectedWordTail: Sendable {
    struct Limits: Equatable, Sendable {
        let maximumRetainedWords: Int
        let maximumRetainedSeconds: TimeInterval
        let maximumActivityIntervals: Int
        let maximumSpeakers: Int
        let maximumRetainedTextBytes: Int

        init(maximumRetainedWords: Int = 2_048, maximumRetainedSeconds: TimeInterval = 120,
             maximumActivityIntervals: Int = 8_192,
             maximumSpeakers: Int = MeetingSpeakerVoiceSamples.maximumProfiles,
             maximumRetainedTextBytes: Int = 524_288) {
            self.maximumRetainedWords = maximumRetainedWords
            self.maximumRetainedSeconds = maximumRetainedSeconds
            self.maximumActivityIntervals = maximumActivityIntervals
            self.maximumSpeakers = maximumSpeakers
            self.maximumRetainedTextBytes = maximumRetainedTextBytes
        }
    }

    /// Each cursor accounts for the entire physical prefix, including silence. A privacy-safe
    /// cursor must not advance past held PII tokens. No later call may introduce a word behind it.
    struct Watermarks: Equatable, Sendable {
        let asrStableThrough: TimeInterval
        let diarizationProcessedThrough: TimeInterval
        let privacySafeThrough: TimeInterval
        var commonThrough: TimeInterval {
            min(self.asrStableThrough, self.diarizationProcessedThrough, self.privacySafeThrough)
        }
    }

    /// A patch cannot overwrite a concurrent correction to text, native evidence, status or
    /// completeness. Apply it to the latest product segment through the existing store owner.
    struct SpeakerRevision: Equatable, Sendable {
        let segmentID: MeetingTranscriptSegmentID
        let speakerID: SessionSpeakerID?
        let overlap: MeetingTranscriptOverlap
        let attributionState: MeetingTranscriptAttributionState?
        let speakerAttribution: MeetingTranscriptSpeakerAttribution?

        init(_ segment: MeetingTranscriptSegment) {
            self.segmentID = segment.id
            self.speakerID = segment.speakerID
            self.overlap = segment.overlap
            self.attributionState = segment.attributionState
            self.speakerAttribution = segment.speakerAttribution
        }

        @discardableResult
        func apply(to segment: inout MeetingTranscriptSegment) throws -> Bool {
            guard segment.id == self.segmentID else { throw Failure.revisionIdentityMismatch }
            guard Self(segment) != self else { return false }
            guard segment.revision < Int.max else { throw Failure.revisionOverflow }
            segment.speakerID = self.speakerID
            segment.overlap = self.overlap
            segment.attributionState = self.attributionState
            segment.speakerAttribution = self.speakerAttribution
            segment.revision += 1
            return true
        }
    }

    struct Update: Sendable {
        let inserted: [MeetingTranscriptSegment]
        let revisions: [SpeakerRevision]
        /// Lightweight identity records. Merge through the existing batch merge operation;
        /// voice vectors remain with the product identity owner and are never replaced here.
        let speakers: [MeetingSessionSpeaker]
        let committedIDs: [MeetingTranscriptSegmentID]
        /// Text can be ASR-final while its speaker is still provisional. Do not change status.
        let provisionalSpeakerIDs: [MeetingTranscriptSegmentID]
        /// End of the last committed word. Stop advances it through the final admitted prefix.
        /// Use retainActivityFrom, rather than this text cursor, to evict acoustic history.
        let committedThrough: TimeInterval
        /// Acknowledgement for acoustic eviction, covering committed left context as well as
        /// pending words. Do not clip a surviving activity interval's original start to this value.
        let retainActivityFrom: TimeInterval
        let retainedWordCount: Int
        let isFinal: Bool
    }

    enum Failure: Error, Equatable {
        case invalidConfiguration
        case staleAttempt
        case invalidWatermark
        case regressedWatermark
        case incompleteActivitySnapshot
        case invalidWord
        case conflictingWord
        case wordBehindSafePrefix
        case invalidActivity
        case retainedWordLimit
        case retainedTimeLimit
        case retainedTextLimit
        case activityLimit
        case speakerLimit
        case revisionIdentityMismatch
        case revisionOverflow
        case alreadyFinished
        case cancelled
    }

    private enum Phase: Sendable { case active, finished, cancelled }
    private struct Retained: Sendable {
        /// Never replace source evidence with an earlier contextual display choice.
        let original: MeetingTranscriptSegment
        var published: MeetingTranscriptSegment
        var committed: Bool
    }

    let attemptID: UUID
    let epoch: MeetingAnalysisEpochID
    let policy: MeetingSpeakerAttributionPolicy
    let limits: Limits
    let speakerNameFormat: String
    /// Scheduling delay derived from the actual frozen v2 contextual limits. It is not an
    /// accuracy guarantee: without a valid anchor, expired unknown/mixed words keep uncertainty.
    let policyLookahead: TimeInterval
    private var phase: Phase = .active
    private var retained: [Retained] = []
    private var speakers: [MeetingSessionSpeaker]
    private var watermarks = Watermarks(asrStableThrough: 0, diarizationProcessedThrough: 0, privacySafeThrough: 0)
    private(set) var committedThrough: TimeInterval = 0
    private(set) var retainActivityFrom: TimeInterval = 0
    private var lastIntroducedStart: TimeInterval = -1

    init(attemptID: UUID, epoch: MeetingAnalysisEpochID, speakerNameFormat: String,
         policy: MeetingSpeakerAttributionPolicy = .standard, limits: Limits = .init(),
         priorSpeakers: [MeetingSessionSpeaker] = []) throws {
        _ = try policy.validated()
        let lookahead = max(
            policy.enableNeighborResolution ? policy.maximumUnknownRunSeconds + 2 * policy.maximumNeighborGapSeconds : 0,
            policy.enableBriefInterruption ? policy.maximumInterruptionWordSeconds + policy.maximumNeighborGapSeconds
                + policy.maximumBriefInterruptionSeconds + policy.maximumBriefInterruptionGapSeconds : 0)
        guard limits.maximumRetainedWords > 0, limits.maximumRetainedSeconds.isFinite,
              limits.maximumRetainedSeconds > lookahead,
              limits.maximumActivityIntervals > 0,
              (1...MeetingSpeakerVoiceSamples.maximumProfiles).contains(limits.maximumSpeakers),
              limits.maximumRetainedTextBytes > 0,
              priorSpeakers.count <= limits.maximumSpeakers,
              Set(priorSpeakers.map(\.id)).count == priorSpeakers.count else { throw Failure.invalidConfiguration }
        self.attemptID = attemptID
        self.epoch = epoch
        self.policy = policy
        self.limits = limits
        self.speakerNameFormat = speakerNameFormat
        self.policyLookahead = lookahead
        self.speakers = Self.identityOnly(priorSpeakers)
    }

    /// Incoming words retain canonical native timing, are append-only, ASR-stable and already admitted by the original privacy
    /// context (or the immutable privacy-disabled policy). Exact repeats still retained are no-ops.
    /// Limit/input/cancellation failures are atomic: the caller retains the rejected batch and
    /// fails or pauses this attempt explicitly. This component never silently drops safe text.
    mutating func update(safeWords: MeetingPCMTranscriptBatch, activity: [MeetingBackendSpeakerActivity],
                         watermarks: Watermarks, attemptID: UUID, epoch: MeetingAnalysisEpochID,
                         activityAvailableFrom: TimeInterval = 0) throws -> Update {
        var next = self
        let result = try next.reconcile(safeWords: safeWords, activity: activity, watermarks: watermarks,
            attemptID: attemptID, epoch: epoch, activityAvailableFrom: activityAvailableFrom, final: false)
        self = next
        return result
    }

    /// Stop flushes only the retained safe tail. No old privacy context is replayed and no audio
    /// is revisited. Call exactly once after ASR, privacy and diarization have all drained.
    mutating func finish(safeWords: MeetingPCMTranscriptBatch = .init(segments: []),
                         activity: [MeetingBackendSpeakerActivity], watermarks: Watermarks,
                         attemptID: UUID, epoch: MeetingAnalysisEpochID,
                         activityAvailableFrom: TimeInterval = 0) throws -> Update {
        var next = self
        let result = try next.reconcile(safeWords: safeWords, activity: activity, watermarks: watermarks,
            attemptID: attemptID, epoch: epoch, activityAvailableFrom: activityAvailableFrom, final: true)
        self = next
        return result
    }

    mutating func cancel() {
        self.retained.removeAll(keepingCapacity: false)
        self.speakers.removeAll(keepingCapacity: false)
        self.phase = .cancelled
    }

    private mutating func reconcile(safeWords: MeetingPCMTranscriptBatch,
        activity: [MeetingBackendSpeakerActivity], watermarks: Watermarks,
        attemptID: UUID, epoch: MeetingAnalysisEpochID, activityAvailableFrom: TimeInterval, final: Bool
    ) throws -> Update {
        try Task.checkCancellation()
        switch self.phase {
        case .finished: throw Failure.alreadyFinished
        case .cancelled: throw Failure.cancelled
        case .active: break
        }
        guard attemptID == self.attemptID, epoch == self.epoch else { throw Failure.staleAttempt }
        if let observation = safeWords.speechObservationIdentity {
            guard observation.attemptID == self.attemptID, observation.epochID == self.epoch else { throw Failure.staleAttempt }
        }
        let cursors = [watermarks.asrStableThrough, watermarks.diarizationProcessedThrough, watermarks.privacySafeThrough]
        guard cursors.allSatisfy({ $0.isFinite && $0 >= 0 }), activityAvailableFrom.isFinite,
              activityAvailableFrom >= 0,
              watermarks.privacySafeThrough <= watermarks.asrStableThrough + self.policy.comparisonTolerance
        else { throw Failure.invalidWatermark }
        guard watermarks.asrStableThrough >= self.watermarks.asrStableThrough,
              watermarks.diarizationProcessedThrough >= self.watermarks.diarizationProcessedThrough,
              watermarks.privacySafeThrough >= self.watermarks.privacySafeThrough else { throw Failure.regressedWatermark }
        if final {
            guard (cursors.max() ?? 0) - watermarks.commonThrough <= self.policy.comparisonTolerance else {
                throw Failure.invalidWatermark
            }
        }
        guard activityAvailableFrom <= self.retainActivityFrom + self.policy.comparisonTolerance else {
            throw Failure.incompleteActivitySnapshot
        }
        guard safeWords.segments.count <= self.limits.maximumRetainedWords else { throw Failure.retainedWordLimit }
        guard activity.count <= self.limits.maximumActivityIntervals else { throw Failure.activityLimit }
        guard activity.allSatisfy({ $0.token.analysisEpochID == self.epoch && !$0.token.label.isEmpty
            && MeetingEvidenceInterval.isValid(start: $0.start, end: $0.end)
            && $0.end <= watermarks.diarizationProcessedThrough + self.policy.comparisonTolerance }) else {
            throw Failure.invalidActivity
        }
        guard safeWords.speakers.count <= self.limits.maximumSpeakers,
              Set(safeWords.speakers.map(\.id)).count == safeWords.speakers.count else { throw Failure.speakerLimit }
        let merged = safeWords.mergingSpeakers(into: self.speakers)
        guard Set(self.speakers.map(\.id)).union(safeWords.speakers.map(\.id)).count <= self.limits.maximumSpeakers else {
            throw Failure.speakerLimit
        }
        self.speakers = Self.identityOnly(merged)

        var insertedIDs = Set<MeetingTranscriptSegmentID>()
        var known = Dictionary(uniqueKeysWithValues: self.retained.enumerated().map { ($0.element.original.id, $0.offset) })
        var nativeIDs = Set(self.retained.compactMap { $0.original.nativeUnitID })
        for word in safeWords.segments {
            try Task.checkCancellation()
            if let index = known[word.id] {
                guard self.retained[index].original == word else { throw Failure.conflictingWord }
                continue
            }
            let timing = Self.timing(word)
            guard word.sourceTrackID == self.epoch.trackID,
                  word.nativeTiming != nil,
                  MeetingEvidenceInterval.isValid(start: timing.start, end: timing.end),
                  word.start.seconds.isFinite, word.end.seconds.isFinite,
                  word.start.seconds >= 0, word.end.seconds > word.start.seconds,
                  timing.end <= watermarks.commonThrough + self.policy.comparisonTolerance,
                  word.end.seconds <= watermarks.commonThrough + 0.001,
                  word.revision >= 0, !word.text.isEmpty,
                  word.nativeSpeakerAssignment?.tokens.allSatisfy({ $0.analysisEpochID == self.epoch }) ?? true else {
                throw Failure.invalidWord
            }
            guard timing.start >= self.lastIntroducedStart,
                  timing.start >= self.committedThrough - self.policy.comparisonTolerance,
                  timing.start >= self.watermarks.privacySafeThrough - self.policy.comparisonTolerance else {
                throw Failure.wordBehindSafePrefix
            }
            if let id = word.nativeUnitID {
                guard !id.isEmpty, nativeIDs.insert(id).inserted else { throw Failure.conflictingWord }
            }
            self.lastIntroducedStart = timing.start
            known[word.id] = self.retained.count
            insertedIDs.insert(word.id)
            self.retained.append(.init(original: word, published: word, committed: false))
        }
        self.watermarks = watermarks
        self.pruneContext()
        try self.validateBounds()

        var revisions: [SpeakerRevision] = []
        var resolved: [MeetingTranscriptSegment] = []
        if !self.retained.isEmpty {
            let duration = max(watermarks.diarizationProcessedThrough,
                self.retained.map { Self.timing($0.original).end }.max() ?? 0)
            let boundedActivity = activity.filter { $0.end > self.retainActivityFrom && $0.start < duration }
            let result = try MeetingPCMRecordingAttribution.assemble(
                transcript: .init(segments: self.retained.map(\.original), speakers: self.speakers),
                activity: boundedActivity, epoch: self.epoch, attemptID: self.attemptID, duration: duration,
                speakerNameFormat: self.speakerNameFormat, speakerAttributionPolicy: self.policy)
            guard result.speakers.count <= self.limits.maximumSpeakers else { throw Failure.speakerLimit }
            let ownerFlags = Dictionary(uniqueKeysWithValues: self.speakers.map { ($0.id, $0.isLocalUser) })
            var identities = result
            identities.speakers = result.speakers.map { source in
                var speaker = source
                // Attribution is not owner verification. Only incoming identity-owner records
                // may promote/revoke this flag; an absent voice in a small window cannot do it.
                if let isLocalUser = ownerFlags[speaker.id] { speaker.isLocalUser = isLocalUser }
                return speaker
            }
            self.speakers = Self.identityOnly(identities.mergingSpeakers(into: self.speakers))
            let admittedIDs = Set(self.speakers.map(\.id))
            guard result.segments.allSatisfy({ $0.speakerID.map { admittedIDs.contains($0) } ?? true }) else {
                // The existing product merge has a global profile cap. Surface its exclusion
                // instead of publishing an ID whose identity record was silently capped out.
                throw Failure.speakerLimit
            }
            resolved = result.segments
            // A known identity can disappear from this small window's ID table because the
            // assembler admits names by voiced duration. Reuse only an already admitted ID,
            // never mint one here or turn unsupported/context-only text into a new speaker.
            for index in resolved.indices {
                let original = self.retained[index].original
                guard resolved[index].speakerID == nil,
                      original.status == .final, original.completeness == .complete,
                      !original.isEcho, original.attributionState != .timingUncertain,
                      let summary = resolved[index].speakerAttribution,
                      let token = summary.selectedToken else { continue }
                let timing = Self.timing(original)
                guard activity.contains(where: { $0.token == token
                    && min($0.end, timing.end) - max($0.start, timing.start) > self.policy.comparisonTolerance }),
                      let known = self.speakers.first(where: {
                          $0.diarizationClusterID == "\(token.analysisEpochID):\(token.label.precomposedStringWithCanonicalMapping)"
                      }) else { continue }
                resolved[index].speakerID = known.id
                resolved[index].attributionState = .assigned
                resolved[index].speakerAttribution = .init(streamingSummary: summary,
                    knownToken: token, speakerID: known.id)
            }
            for index in self.retained.indices where !self.retained[index].committed {
                try Task.checkCancellation()
                let patch = SpeakerRevision(resolved[index])
                if try patch.apply(to: &self.retained[index].published), !insertedIDs.contains(patch.segmentID) {
                    revisions.append(patch)
                }
            }
        }

        let threshold = final ? watermarks.commonThrough : max(0, watermarks.commonThrough - self.policyLookahead)
        var committedIDs: [MeetingTranscriptSegmentID] = []
        for index in self.retained.indices where !self.retained[index].committed {
            let word = self.retained[index].original, timing = Self.timing(word)
            guard timing.end <= threshold + self.policy.comparisonTolerance else { break }
            // The complete-prefix contract prevents a later word being introduced behind the
            // current watermark. Once the finite policy window expires, absent future anchors
            // cannot legitimately rescue this word. Commit the canonical uncertain outcome;
            // never invent an incoming speaker merely to drain a noisy meeting.
            self.retained[index].committed = true
            committedIDs.append(word.id)
            self.committedThrough = max(self.committedThrough, timing.end)
        }
        let inserted = self.retained.filter { insertedIDs.contains($0.original.id) }.map(\.published)
        let provisional = self.retained.filter { !$0.committed }.map { $0.original.id }
        self.pruneContext()
        try self.validateBounds()
        if final {
            guard provisional.isEmpty else { throw Failure.invalidWatermark }
            self.phase = .finished
            self.retained.removeAll(keepingCapacity: false)
            self.committedThrough = max(self.committedThrough, watermarks.commonThrough)
            self.retainActivityFrom = self.committedThrough
        }
        try Task.checkCancellation()
        return Update(inserted: inserted, revisions: revisions, speakers: self.speakers,
            committedIDs: committedIDs, provisionalSpeakerIDs: provisional,
            committedThrough: self.committedThrough, retainActivityFrom: self.retainActivityFrom,
            retainedWordCount: self.retained.count, isFinal: final)
    }

    private static func timing(_ segment: MeetingTranscriptSegment) -> MeetingTranscriptNativeTiming {
        segment.nativeTiming ?? .init(start: segment.start.seconds, end: segment.end.seconds)
    }

    private static func identityOnly(_ speakers: [MeetingSessionSpeaker]) -> [MeetingSessionSpeaker] {
        speakers.map { source in
            var speaker = source
            // Voice vectors belong to the existing identity owner. These lightweight records
            // are merged through MeetingPCMTranscriptBatch.mergingSpeakers, never replacements.
            speaker.diarizationEmbedding = nil
            return speaker
        }
    }

    private mutating func pruneContext() {
        let firstPendingStart = self.retained.first(where: { !$0.committed }).map { Self.timing($0.original).start }
        let contextStart = max(0, (firstPendingStart ?? self.watermarks.commonThrough) - self.policyLookahead)
        // Keep the full original left anchor when it intersects the context horizon. A very long
        // native envelope fails the explicit retention cap rather than being silently clipped.
        self.retained.removeAll { $0.committed && Self.timing($0.original).end < contextStart }
        let firstStart = self.retained.map { Self.timing($0.original).start }.min() ?? self.watermarks.commonThrough
        let boutPreroll = self.policy.enableBriefInterruption
            ? self.policy.maximumBriefInterruptionSeconds + self.policy.maximumBriefInterruptionGapSeconds : 0
        self.retainActivityFrom = max(self.retainActivityFrom, max(0, firstStart - boutPreroll))
    }

    private func validateBounds() throws {
        guard self.retained.count <= self.limits.maximumRetainedWords else { throw Failure.retainedWordLimit }
        var bytes = 0
        for word in self.retained {
            for count in [word.original.text.utf8.count, word.original.originalText?.utf8.count ?? 0] {
                guard count <= self.limits.maximumRetainedTextBytes - bytes else { throw Failure.retainedTextLimit }
                bytes += count
            }
        }
        if let start = self.retained.map({ Self.timing($0.original).start }).min(),
           let end = self.retained.map({ Self.timing($0.original).end }).max(),
           end - start > self.limits.maximumRetainedSeconds { throw Failure.retainedTimeLimit }
    }
}

private nonisolated extension MeetingTranscriptSpeakerAttribution {
    init(streamingSummary source: Self, knownToken: MeetingBackendSpeakerToken, speakerID: SessionSpeakerID) {
        self.unitID = source.unitID
        self.rawAssignment = source.rawAssignment
        self.selectedToken = source.selectedToken
        self.selectedSpeakerID = source.selectedToken == knownToken ? speakerID : source.selectedSpeakerID
        self.candidates = source.candidates.map {
            .init(token: $0.token, speakerID: $0.token == knownToken ? speakerID : $0.speakerID)
        }
        self.background = source.background.map {
            .init(token: $0.token, speakerID: $0.token == knownToken ? speakerID : $0.speakerID)
        }
        self.relation = source.relation
        self.rule = source.rule
        self.policyVersion = source.policyVersion
        self.policyFingerprint = source.policyFingerprint
    }
}
