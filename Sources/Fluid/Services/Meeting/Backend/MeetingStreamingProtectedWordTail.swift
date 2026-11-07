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
             maximumSpeakers: Int = MeetingSessionSpeaker.maximumParticipants,
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

    typealias SpeakerRevision = MeetingPCMTranscriptBatch.SpeakerRevision

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
    private struct ProvisionalBout: Sendable {
        let speakerID: SessionSpeakerID
        let start: TimeInterval
        var end: TimeInterval
        let precedingToken: MeetingBackendSpeakerToken?
        var recoveryToken: MeetingBackendSpeakerToken?
    }
    /// A scalar reading cursor, not another acoustic clusterer. Replaying retained words from
    /// the pruned prefix makes both IDs and recovery boundaries independent of batch partitioning.
    private struct ProvisionalReadingState: Sendable {
        var lastEnd: TimeInterval?
        var precedingToken: MeetingBackendSpeakerToken?
        var bout: ProvisionalBout?
        var isBarrier = false
    }
    private struct Retained: Sendable {
        /// Never replace source evidence with an earlier contextual display choice.
        let original: MeetingTranscriptSegment
        var published: MeetingTranscriptSegment
        var committed: Bool
        var provisionalStateAfter = ProvisionalReadingState()
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
    private var provisionalPrefixState = ProvisionalReadingState()
    /// A retired text prefix cannot be relabelled by a bounded future observation. One bit per
    /// product identity prevents an automatic alias from changing already committed uncertainty.
    private var committedProvisionalIdentities = Set<SessionSpeakerID>()
    private var speakers: [MeetingSessionSpeaker]
    private struct VoiceSupport: Sendable {
        var intervals: [MeetingSpeakerAttributionInterval] = []
        var qualified = false
    }
    /// Sponsored native bouts only, coalesced and discarded once the fixed admission
    /// requirement is earned. No PCM, embeddings, raw text or full meeting history.
    private var voiceSupport: [MeetingBackendSpeakerToken: VoiceSupport] = [:]
    var retainedAdmissionIntervalCount: Int { self.voiceSupport.values.reduce(0) { $0 + $1.intervals.count } }
    var retainedAdmissionTokenCount: Int { self.voiceSupport.count }
    func admittedVoiceSeconds(for token: MeetingBackendSpeakerToken) -> TimeInterval {
        guard let support = self.voiceSupport[token] else { return 0 }
        return support.qualified ? MeetingTranscriptAssembler.minimumSpeakerSeconds
            : support.intervals.reduce(0) { $0 + $1.duration }
    }
    private var watermarks = Watermarks(asrStableThrough: 0, diarizationProcessedThrough: 0, privacySafeThrough: 0)
    private(set) var committedThrough: TimeInterval = 0
    private(set) var retainActivityFrom: TimeInterval = 0
    private var lastIntroducedStart: TimeInterval = -1

    init(attemptID: UUID, epoch: MeetingAnalysisEpochID, speakerNameFormat: String,
         policy: MeetingSpeakerAttributionPolicy = .standard, limits: Limits = .init(),
         priorSpeakers: [MeetingSessionSpeaker] = []) throws {
        _ = try policy.validated()
        let acousticLookahead = max(
            policy.enableNeighborResolution ? policy.maximumUnknownRunSeconds + 2 * policy.maximumNeighborGapSeconds : 0,
            policy.enableBriefInterruption ? policy.maximumInterruptionWordSeconds + policy.maximumNeighborGapSeconds
                + policy.maximumBriefInterruptionSeconds + policy.maximumBriefInterruptionGapSeconds : 0)
        let lookahead = max(acousticLookahead,
            policy.enableCompleteReadingAssignment ? MeetingReadingSpeakerResolver.contextRadiusSeconds : 0,
            policy.enableTokenEmissionContext ? policy.maximumEmissionContextSeconds : 0)
        guard limits.maximumRetainedWords > 0, limits.maximumRetainedSeconds.isFinite,
              limits.maximumRetainedSeconds > lookahead,
              limits.maximumActivityIntervals > 0,
              (1...MeetingSessionSpeaker.maximumParticipants).contains(limits.maximumSpeakers),
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
        self.voiceSupport.removeAll(keepingCapacity: false)
        self.provisionalPrefixState = .init()
        self.committedProvisionalIdentities.removeAll(keepingCapacity: false)
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
        let merged = safeWords.mergingSpeakers(into: self.speakers, speakerNameFormat: self.speakerNameFormat)
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
        // A newly privacy-admitted batch may straddle a long silent gap. Bound allocations
        // now, then evaluate the time horizon after finite policy commitment and pruning.
        // Silence consumes no word/text memory and must not make an otherwise bounded
        // batch fail before its already-expired left words can be emitted and retired.
        try self.validateBounds(checkTime: false)

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
            try self.updateVoiceSupport(activity: activity,
                original: self.retained.map(\.original), scored: result.segments)
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
            self.speakers = Self.identityOnly(identities.mergingSpeakers(into: self.speakers,
                speakerNameFormat: self.speakerNameFormat))
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
                let cluster = "\(token.analysisEpochID):\(token.label.precomposedStringWithCanonicalMapping)"
                let matchingSpeakers = self.speakers.filter { $0.diarizationClusterID == cluster }
                guard let known = matchingSpeakers.first else { continue }
                // A provider can already have attached the same automatic contextual ID to
                // this safe word. That metadata is not a manual assignment. Reuse it only
                // when complete native provenance and one active admitted identity agree.
                let sameAutomaticContext = self.canReuseAutomaticIdentity(original: original,
                    summary: summary, token: token, known: known, matchingCount: matchingSpeakers.count)
                let permitsContextIdentity = original.speakerID == nil || sameAutomaticContext
                let timing = Self.timing(original)
                let hasWordSupport = boundedActivity.contains { $0.token == token
                    && min($0.end, timing.end) - max($0.start, timing.start) > self.policy.comparisonTolerance }
                // The canonical neighbor resolver has already checked independent original
                // anchors, cue paths and barriers using this same immutable source snapshot.
                // A gap word need not itself contain the chosen voice. Resolve its existing
                // identity without changing native assignment or inventing acoustic support.
                let hasNeighborCues = permitsContextIdentity && summary.rawAssignment == .unassigned
                    && (summary.rule == .neighborAgreement || summary.rule == .incomingSpeaker)
                    && (summary.relation == .none || summary.relation == .single)
                let hasContinuationCues = permitsContextIdentity && summary.rule == .mainSpeakerContinuation
                guard hasWordSupport || hasNeighborCues || hasContinuationCues else { continue }
                resolved[index].speakerID = known.id
                resolved[index].attributionState = .assigned
                resolved[index].speakerAttribution = .init(streamingSummary: summary,
                    knownToken: token, speakerID: known.id)
            }
            try self.applyProvisionalIdentities(to: &resolved)
            for index in self.retained.indices where !self.retained[index].committed {
                try Task.checkCancellation()
                let patch = SpeakerRevision(resolved[index])
                if try patch.apply(to: &self.retained[index].published), !insertedIDs.contains(patch.segmentID) {
                    revisions.append(patch)
                }
            }
        } else {
            try self.updateVoiceSupport(activity: activity, original: [], scored: [])
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
            if self.retained[index].published.speakerIdentityIsProvisional == true,
               let id = self.retained[index].published.speakerID,
               self.speakers.contains(where: { $0.id == id && $0.diarizationClusterID == nil }) {
                self.committedProvisionalIdentities.insert(id)
            }
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
            self.voiceSupport.removeAll(keepingCapacity: false)
            self.provisionalPrefixState = .init()
            self.committedProvisionalIdentities.removeAll(keepingCapacity: false)
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

    private mutating func updateVoiceSupport(activity: [MeetingBackendSpeakerActivity],
        original: [MeetingTranscriptSegment], scored: [MeetingTranscriptSegment]
    ) throws {
        // Same-epoch native activity is append-only evidence: admitted bouts can extend,
        // backdate their onset or be evicted after acknowledgement, but never retract.
        // A reset/retraction needs a new analysis epoch, not reuse of a saturated receipt.
        guard self.policy.enableVoicedSpeakerAdmission else { return }
        let scoredByID = Dictionary(scored.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard original.count == scored.count, scoredByID.count == scored.count,
              original.allSatisfy({ scoredByID[$0.id] != nil }) else { throw Failure.revisionIdentityMismatch }
        var lexical: [MeetingBackendSpeakerToken: [MeetingSpeakerAttributionInterval]] = [:]
        for source in original {
            try Task.checkCancellation()
            guard let current = scoredByID[source.id] else { throw Failure.revisionIdentityMismatch }
            guard source.status == .final, source.completeness == .complete, !source.isEcho,
                  source.attributionState != .timingUncertain, source.originalText == nil,
                  source.isUserTextEdited != true, source.speakerAttributionInference == nil,
                  source.nativePrecision == .word, source.nativeUnitID?.isEmpty == false,
                  (self.policy.enableStableSpeakerOpening ? source.hasLexicalContent
                    : source.text.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) })),
                  case let .assigned(token) = source.nativeSpeakerAssignment,
                  current.nativeSpeakerAssignment == .assigned(token), current.overlap == .none,
                  token.analysisEpochID == self.epoch,
                  source.speakerID.map({ $0 == MeetingTranscriptAssembler.speakerID(attemptID: self.attemptID, token: token) }) ?? true
            else { continue }
            if let summary = source.speakerAttribution {
                guard summary.unitID == source.nativeUnitID, summary.rawAssignment == .assigned(token),
                      summary.rule.isIndependentAcousticSelection, summary.selectedToken == token,
                      summary.selectedSpeakerID == source.speakerID else { continue }
            } else {
                guard source.revision == 0 else { continue }
            }
            if let summary = current.speakerAttribution {
                guard summary.rule.isIndependentAcousticSelection, summary.selectedToken == token,
                      summary.rawAssignment == .assigned(token) else { continue }
            }
            let timing = Self.timing(source)
            lexical[token, default: []].append(.init(start: timing.start, end: timing.end))
        }
        for token in lexical.keys { lexical[token] = try MeetingSpeakerAttribution.unionedIntervals(lexical[token]!) }
        let byToken = Dictionary(grouping: activity, by: \.token)
        for (token, entries) in byToken {
            try Task.checkCancellation()
            var support = self.voiceSupport[token] ?? VoiceSupport()
            guard !support.qualified else { continue }
            let bouts = try MeetingSpeakerAttribution.unionedIntervals(entries.map { .init(start: $0.start, end: $0.end) })
            let words = lexical[token] ?? []
            let sponsored = bouts.filter { bout in
                words.contains { min($0.end, bout.end) - max($0.start, bout.start) > self.policy.comparisonTolerance }
                    || support.intervals.contains { min($0.end, bout.end) - max($0.start, bout.start) >= 0 }
            }
            guard !sponsored.isEmpty else { continue }
            support.intervals = try MeetingSpeakerAttribution.unionedIntervals(support.intervals + sponsored)
            if support.intervals.reduce(0, { $0 + $1.duration }) + self.policy.comparisonTolerance
                >= MeetingTranscriptAssembler.minimumSpeakerSeconds {
                support.qualified = true
                support.intervals.removeAll(keepingCapacity: false)
            }
            self.voiceSupport[token] = support
            guard self.voiceSupport.count <= MeetingSpeakerVoiceSamples.maximumProfiles else { throw Failure.speakerLimit }
            guard self.retainedAdmissionIntervalCount <= self.limits.maximumActivityIntervals else { throw Failure.activityLimit }
        }
        let qualification = MeetingVoicedSpeakerAdmission(attemptID: self.attemptID, epoch: self.epoch,
            tokens: Set(self.voiceSupport.filter { $0.value.qualified }.map(\.key)))
        let admitted = try MeetingTranscriptAssembler(speakerNameFormat: self.speakerNameFormat)
            .admitPCMIdentities(qualification, attemptID: self.attemptID, epoch: self.epoch, priorSpeakers: self.speakers)
        guard Set(self.speakers.map(\.id)).union(admitted.map(\.id)).count <= self.limits.maximumSpeakers else {
            throw Failure.speakerLimit
        }
        self.speakers = Self.identityOnly(MeetingPCMTranscriptBatch(segments: [], speakers: admitted)
            .mergingSpeakers(into: self.speakers, speakerNameFormat: self.speakerNameFormat))
    }

    private func canReuseAutomaticIdentity(original: MeetingTranscriptSegment,
        summary: MeetingTranscriptSpeakerAttribution, token: MeetingBackendSpeakerToken,
        known: MeetingSessionSpeaker, matchingCount: Int
    ) -> Bool {
        guard original.speakerID == known.id, original.attributionState == .assigned,
              matchingCount == 1, known.mergedIntoSpeakerID == nil,
              known.trackKind == .microphone,
              self.speakers.filter({ $0.id == known.id }).count == 1,
              token.analysisEpochID == self.epoch,
              known.id == MeetingTranscriptAssembler.speakerID(attemptID: self.attemptID, token: token),
              original.nativePrecision == .word, original.sourceTrackID == self.epoch.trackID,
              original.isUserTextEdited != true, original.originalText == nil,
              original.speakerAttributionInference == nil,
              let nativeUnitID = original.nativeUnitID, !nativeUnitID.isEmpty,
              let timing = original.nativeTiming,
              abs(original.start.seconds - timing.start) <= 0.001,
              abs(original.end.seconds - timing.end) <= 0.001,
              let nativeAssignment = original.nativeSpeakerAssignment,
              let prior = original.speakerAttribution,
              prior.unitID == nativeUnitID, summary.unitID == nativeUnitID,
              prior.rawAssignment == nativeAssignment, summary.rawAssignment == nativeAssignment,
              prior.selectedToken == token, prior.selectedSpeakerID == known.id,
              [.neighborAgreement, .incomingSpeaker, .mainSpeakerContinuation].contains(prior.rule),
              (prior.candidates + prior.background).allSatisfy({ $0.token.analysisEpochID == self.epoch }),
              prior.policyVersion == self.policy.schemaVersion, summary.policyVersion == self.policy.schemaVersion,
              prior.policyFingerprint == self.policy.fingerprint,
              summary.policyFingerprint == prior.policyFingerprint else { return false }
        switch nativeAssignment {
        case .unassigned, .ambiguous: return true
        case .assigned: return false
        }
    }

    /// Supply a durable reading identity only after canonical privacy admission and scoring.
    /// An unknown bout is not an acoustic person: it cannot sponsor voice/owner matching and
    /// never rewrites the native token or the resolver's original summary.
    private mutating func applyProvisionalIdentities(to resolved: inout [MeetingTranscriptSegment],
        trackKind: MeetingAudioTrackKind = .microphone,
        resetBefore: Set<MeetingTranscriptSegmentID> = [], allowRecovery: Bool = true
    ) throws {
        if self.policy.enableCompleteReadingAssignment {
            let assembler = MeetingTranscriptAssembler(speakerNameFormat: self.speakerNameFormat)
            let reading = try MeetingReadingSpeakerResolver.resolve(segments: resolved, speakers: self.speakers,
                policy: self.policy,
                contextualBarrierEpochIDs: allowRecovery ? [] : [self.epoch],
                resetBeforeIDs: resetBefore,
                scopeForSegment: { _ in self.epoch },
                fallbackSpeaker: { assembler.readingFallbackSpeaker(attemptID: self.attemptID,
                    epoch: $0, trackKind: trackKind) })
            guard reading.speakers.count <= self.limits.maximumSpeakers else { throw Failure.speakerLimit }
            resolved = reading.segments
            self.speakers = MeetingSessionSpeaker.numberingGeneratedParticipants(reading.speakers,
                speakerNameFormat: self.speakerNameFormat)
            return
        }
        if self.policy.enableStableSpeakerOpening {
            try self.applyExistingParticipantContext(to: &resolved, resetBefore: resetBefore,
                allowContext: allowRecovery)
            return
        }
        guard self.policy.enableProvisionalSpeakerIdentities else { return }
        var state = self.provisionalPrefixState
        var speakerIndices = Dictionary(self.speakers.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first })
        for index in resolved.indices {
            try Task.checkCancellation()
            let source = self.retained[index].original, timing = Self.timing(source)
            if resetBefore.contains(source.id) { state = .init() }
            let barrier = source.status != .final || source.completeness != .complete || source.isEcho
                || source.attributionState == .timingUncertain || source.isUserSpeakerAssigned == true
                || source.nativeUnitID?.isEmpty != false || source.nativeSpeakerAssignment == nil
            // Speech bouts include ordinary pauses between ASR words. Once a native slot
            // resumes provisionally, its pauses obey the same identity continuity as that
            // slot. A new unresolved bout, a different token or a barrier ends the recovery.
            let maximumGap = state.bout?.recoveryToken != nil ? Double.infinity : self.policy.maximumUnknownRunSeconds
            let contiguous = state.lastEnd.map {
                timing.start - $0 <= maximumGap + self.policy.comparisonTolerance
            } ?? false
            if !contiguous || barrier != state.isBarrier { state = .init() }

            let identity = resolved[index].speakerID.flatMap { speakerIndices[$0] }.map { self.speakers[$0] }
            let validIdentity = identity.map { $0.mergedIntoSpeakerID == nil
                && !$0.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } == true
            if source.isUserSpeakerAssigned == true, validIdentity {
                // Manual confirmation remains authoritative and is also a bout boundary.
                self.retained[index].provisionalStateAfter = .init()
                continue
            }
            let independentToken: MeetingBackendSpeakerToken? = {
                guard validIdentity, case let .assigned(native) = resolved[index].nativeSpeakerAssignment,
                      native.analysisEpochID == self.epoch,
                      resolved[index].speakerID == MeetingTranscriptAssembler.speakerID(attemptID: self.attemptID, token: native)
                else { return nil }
                if let summary = resolved[index].speakerAttribution {
                    guard summary.rule.isIndependentAcousticSelection, summary.selectedToken == native else { return nil }
                }
                return native
            }()
            let contextualContinuationToken: MeetingBackendSpeakerToken? = {
                guard validIdentity, let summary = resolved[index].speakerAttribution,
                      let token = summary.selectedToken, token.analysisEpochID == self.epoch,
                      summary.unitID == source.nativeUnitID,
                      summary.rawAssignment == source.nativeSpeakerAssignment,
                      resolved[index].nativeSpeakerAssignment == source.nativeSpeakerAssignment,
                      summary.selectedSpeakerID == resolved[index].speakerID,
                      resolved[index].speakerID == MeetingTranscriptAssembler.speakerID(attemptID: self.attemptID, token: token)
                else { return nil }
                return token
            }()
            if validIdentity {
                if allowRecovery, let token = independentToken ?? contextualContinuationToken, var bout = state.bout,
                   !barrier, (bout.recoveryToken == token
                    || (independentToken == token && bout.precedingToken == token
                        && bout.end - bout.start > self.policy.maximumUnknownRunSeconds + self.policy.comparisonTolerance)) {
                    // A sustained unscored speech passage breaks product identity continuity.
                    // A return of the same native slot alone cannot prove the same person.
                    // Keep one explicitly provisional reading identity until another actual
                    // token or a manual selection establishes a boundary. No text is inspected.
                    bout.recoveryToken = token
                    bout.end = max(bout.end, timing.end)
                    state.bout = bout
                    resolved[index].speakerID = bout.speakerID
                    resolved[index].speakerIdentityIsProvisional = true
                } else {
                    state.bout = nil
                    state.precedingToken = barrier || !allowRecovery ? nil : independentToken
                    resolved[index].speakerIdentityIsProvisional = identity?.identityIsProvisional == true ? true : nil
                }
            } else {
                // Missing selection after a resumed slot is a new uncertain turn. A bounded
                // contextual decision selecting that same slot stays in the branch above.
                if state.bout?.recoveryToken != nil,
                   resolved[index].speakerAttribution?.selectedToken == nil { state.bout = nil }
                var bout: ProvisionalBout
                if let current = state.bout { bout = current }
                else {
                    let speaker = MeetingTranscriptAssembler(speakerNameFormat: self.speakerNameFormat)
                        .provisionalPCMSpeaker(attemptID: self.attemptID, epoch: self.epoch,
                            firstWordID: source.id, trackKind: trackKind)
                    if speakerIndices[speaker.id] == nil {
                        guard self.speakers.count < self.limits.maximumSpeakers else { throw Failure.speakerLimit }
                        speakerIndices[speaker.id] = self.speakers.count
                        self.speakers.append(speaker)
                    }
                    bout = .init(speakerID: speaker.id, start: timing.start, end: timing.end,
                        precedingToken: barrier || !allowRecovery ? nil : state.precedingToken)
                }
                bout.end = max(bout.end, timing.end)
                state.bout = bout
                resolved[index].speakerID = bout.speakerID
                resolved[index].speakerIdentityIsProvisional = true
            }
            state.lastEnd = max(state.lastEnd ?? timing.end, timing.end)
            state.isBarrier = barrier
            self.retained[index].provisionalStateAfter = state
        }
        // If every still-editable reference acquired the same actual identity, retain the
        // preliminary record as an alias instead of leaving a ghost participant in the roster.
        // Never merge an identity with a committed unresolved word or a surviving bout.
        var refinementTargets: [SessionSpeakerID: Set<SessionSpeakerID>] = [:]
        let referenced = Set(resolved.compactMap(\.speakerID))
        for index in resolved.indices {
            guard let old = self.retained[index].published.speakerID,
                  self.retained[index].published.speakerIdentityIsProvisional == true,
                  let target = resolved[index].speakerID, target != old,
                  let targetIndex = speakerIndices[target], self.speakers[targetIndex].diarizationClusterID != nil
            else { continue }
            refinementTargets[old, default: []].insert(target)
        }
        for (old, targets) in refinementTargets {
            guard targets.count == 1, let target = targets.first, !referenced.contains(old),
                  !self.committedProvisionalIdentities.contains(old), let index = speakerIndices[old],
                  self.speakers[index].diarizationClusterID == nil,
                  self.speakers[index].identityIsProvisional == true,
                  self.speakers[index].mergedIntoSpeakerID == nil,
                  self.speakers[index].generatedParticipantNumber != nil,
                  self.speakers[index].usesCustomDisplayName != true else { continue }
            self.speakers[index].mergedIntoSpeakerID = target
        }
        self.speakers = MeetingSessionSpeaker.numberingGeneratedParticipants(self.speakers,
            speakerNameFormat: self.speakerNameFormat)
    }

    /// Presentation-only fallback for a short unresolved run. It consumes no product identity,
    /// does not replace an independently selected person and cannot sponsor acoustic admission.
    /// Anchors come from the original independently supported words, never this pass's choices.
    private func applyExistingParticipantContext(to resolved: inout [MeetingTranscriptSegment],
        resetBefore: Set<MeetingTranscriptSegmentID>, allowContext: Bool
    ) throws {
        guard allowContext else { return }
        // CoW snapshot of this bounded tail. Earlier contextual writes cannot become anchors.
        let attributed = resolved
        try self.resolveExistingParticipantContext(count: attributed.count,
            originalAt: { self.retained[$0].original }, attributedAt: { attributed[$0] },
            resetsBefore: { resetBefore.contains(attributed[$0].id) }) { position, id, token in
                resolved[position].speakerID = id
                resolved[position].attributionState = .assigned
                resolved[position].speakerIdentityIsProvisional = nil
                resolved[position].speakerAttribution = .init(existingParticipantContext: attributed[position],
                    token: token, speakerID: id, policy: self.policy)
            }
    }

    /// Index access lets final publication inspect a complete run across storage chunks without
    /// copying its text. Only two neighbor options and scalar run bounds are retained. Both input
    /// accessors must read immutable snapshots, and contextual writes are never acoustic anchors.
    private func resolveExistingParticipantContext(count: Int,
        originalAt: (Int) -> MeetingTranscriptSegment,
        attributedAt: (Int) -> MeetingTranscriptSegment,
        resetsBefore: (Int) -> Bool,
        assign: (Int, SessionSpeakerID, MeetingBackendSpeakerToken) -> Void
    ) throws {
        let identities = Dictionary(self.speakers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func safe(_ index: Int) -> Bool {
            let source = originalAt(index)
            return source.hasReadableContent && source.status == .final && source.completeness == .complete
                && !source.isEcho && source.attributionState != .timingUncertain
                && source.isUserSpeakerAssigned != true && source.nativePrecision == .word
                && source.nativeUnitID?.isEmpty == false && source.nativeSpeakerAssignment != nil
        }
        func anchor(_ index: Int) -> (id: SessionSpeakerID, token: MeetingBackendSpeakerToken)? {
            guard (0..<count).contains(index), safe(index) else { return nil }
            let source = attributedAt(index)
            guard let id = source.speakerID, let speaker = identities[id], speaker.mergedIntoSpeakerID == nil,
                  case let .assigned(token) = source.nativeSpeakerAssignment,
                  token.analysisEpochID == self.epoch,
                  id == MeetingTranscriptAssembler.speakerID(attemptID: self.attemptID, token: token)
            else { return nil }
            if let summary = source.speakerAttribution {
                guard summary.rule.isIndependentAcousticSelection, summary.selectedToken == token else { return nil }
            }
            return (id, token)
        }
        func neighborIndex(from initial: Int, step: Int) throws -> Int? {
            var position = initial
            while (0..<count).contains(position) {
                try Task.checkCancellation()
                if resetsBefore(position) { return nil }
                let source = originalAt(position)
                if source.hasReadableContent { return position }
                guard source.status == .final, source.completeness == .complete, !source.isEcho,
                      source.attributionState != .timingUncertain, source.isUserSpeakerAssigned != true else { return nil }
                position += step
            }
            return nil
        }
        var index = 0
        while index < count {
            try Task.checkCancellation()
            guard attributedAt(index).speakerID == nil, safe(index) else { index += 1; continue }
            let first = index
            var last = index
            var end = Self.timing(originalAt(index)).end
            while last + 1 < count, attributedAt(last + 1).speakerID == nil, safe(last + 1),
                  !resetsBefore(last + 1),
                  Self.timing(originalAt(last + 1)).start - Self.timing(originalAt(last)).end
                    <= self.policy.maximumNeighborGapSeconds + self.policy.comparisonTolerance {
                try Task.checkCancellation()
                last += 1
                end = max(end, Self.timing(originalAt(last)).end)
            }
            index = last + 1
            let start = Self.timing(originalAt(first)).start
            guard end - start <= self.policy.maximumUnknownRunSeconds + self.policy.comparisonTolerance else { continue }
            var options: [(id: SessionSpeakerID, token: MeetingBackendSpeakerToken, gap: Double)] = []
            if !resetsBefore(first), let position = try neighborIndex(from: first - 1, step: -1),
               let left = anchor(position) {
                let gap = start - Self.timing(originalAt(position)).end
                if gap >= -self.policy.comparisonTolerance,
                   gap <= self.policy.maximumNeighborGapSeconds + self.policy.comparisonTolerance {
                    options.append((left.id, left.token, gap))
                }
            }
            if let position = try neighborIndex(from: last + 1, step: 1), let right = anchor(position) {
                let gap = Self.timing(originalAt(position)).start - end
                if gap >= -self.policy.comparisonTolerance,
                   gap <= self.policy.maximumNeighborGapSeconds + self.policy.comparisonTolerance {
                    options.append((right.id, right.token, gap))
                }
            }
            guard !options.isEmpty else { continue }
            // A native cue for an already known person wins over distance. Retain only the
            // two option matches, rather than collecting arbitrary native tokens from a run.
            var supported = [Bool](repeating: false, count: options.count)
            for position in first...last {
                try Task.checkCancellation()
                let native = originalAt(position).nativeSpeakerAssignment?.tokens ?? []
                for option in options.indices where native.contains(options[option].token) { supported[option] = true }
            }
            let matching = options.indices.filter { supported[$0] }
            let candidates = matching.isEmpty ? Array(options.indices) : matching
            let chosen = options[candidates.min { options[$0].gap < options[$1].gap }!]
            for position in first...last {
                try Task.checkCancellation()
                assign(position, chosen.id, chosen.token)
            }
        }
    }

    /// Final publication counterpart of the live protected tail. Call only after the owning
    /// privacy operation admitted all text. This reuses the same reading state without rerunning
    /// ASR, acoustic assignment, privacy or PCM assembly. Working text stays within one normal
    /// tail-sized chunk; product identity metadata retains its separate explicit capacity.
    static func finalizingProtectedTranscript(_ transcript: MeetingPCMTranscriptBatch,
        attemptID: UUID, policy: MeetingSpeakerAttributionPolicy?, speakerNameFormat: String,
        trackKinds: [MeetingAudioTrackID: MeetingAudioTrackKind] = [:],
        barriersByTrack: [MeetingAudioTrackID: [MeetingSpeakerAttributionInterval]] = [:],
        contextualBarrierEpochIDs: Set<MeetingAnalysisEpochID> = [],
        epochForSegment: (MeetingTranscriptSegment) -> MeetingAnalysisEpochID?
    ) throws -> MeetingPCMTranscriptBatch {
        if let policy, policy.enableCompleteReadingAssignment {
            _ = try policy.validated()
            guard transcript.speakers.count <= MeetingSessionSpeaker.maximumParticipants else { throw Failure.speakerLimit }
            for segment in transcript.segments {
                try Task.checkCancellation()
                let timing = Self.timing(segment)
                guard let epoch = epochForSegment(segment), epoch.trackID == segment.sourceTrackID,
                      epoch.ordinal >= 0, epoch.generation >= 0,
                      MeetingEvidenceInterval.isValid(start: timing.start, end: timing.end) else { throw Failure.invalidWord }
                guard segment.text.utf8.count + (segment.originalText?.utf8.count ?? 0)
                    <= Limits().maximumRetainedTextBytes else { throw Failure.retainedTextLimit }
            }
            let assembler = MeetingTranscriptAssembler(speakerNameFormat: speakerNameFormat)
            let reading = try MeetingReadingSpeakerResolver.resolve(segments: transcript.segments,
                speakers: transcript.speakers, policy: policy, barriersByTrack: barriersByTrack,
                contextualBarrierEpochIDs: contextualBarrierEpochIDs, scopeForSegment: epochForSegment,
                fallbackSpeaker: { assembler.readingFallbackSpeaker(attemptID: attemptID, epoch: $0,
                    trackKind: trackKinds[$0.trackID] ?? .microphone) })
            var result = transcript
            result.segments = reading.segments
            result.speakers = MeetingSessionSpeaker.numberingGeneratedParticipants(reading.speakers,
                speakerNameFormat: speakerNameFormat)
            result.speakerNameFormat = speakerNameFormat
            return result
        }
        guard let policy, policy.enableProvisionalSpeakerIdentities || policy.enableStableSpeakerOpening else { return transcript }
        _ = try policy.validated()
        guard transcript.speakers.count <= MeetingSessionSpeaker.maximumParticipants else { throw Failure.speakerLimit }
        var indicesByEpoch: [MeetingAnalysisEpochID: [Int]] = [:]
        for index in transcript.segments.indices {
            try Task.checkCancellation()
            let segment = transcript.segments[index]
            guard let epoch = epochForSegment(segment), epoch.trackID == segment.sourceTrackID,
                  epoch.ordinal >= 0, epoch.generation >= 0 else { throw Failure.invalidWord }
            indicesByEpoch[epoch, default: []].append(index)
        }
        var result = transcript
        // Admission order follows the first product word, independently of dictionary iteration.
        let epochs = indicesByEpoch.keys.sorted { indicesByEpoch[$0]!.first! < indicesByEpoch[$1]!.first! }
        for epoch in epochs {
            try Task.checkCancellation()
            let indices = indicesByEpoch[epoch]!.sorted {
                let lhs = Self.timing(transcript.segments[$0]), rhs = Self.timing(transcript.segments[$1])
                return (lhs.start, lhs.end, $0) < (rhs.start, rhs.end, $1)
            }
            var owner = try Self(attemptID: attemptID, epoch: epoch, speakerNameFormat: speakerNameFormat,
                policy: policy, priorSpeakers: result.speakers)
            let barriers = try MeetingSpeakerAttribution.unionedIntervals(barriersByTrack[epoch.trackID] ?? [])
            if policy.enableStableSpeakerOpening {
                // Index the immutable epoch rather than splitting its contextual runs at word
                // or text-byte chunk boundaries. One source value is inspected at a time.
                for index in indices {
                    try Task.checkCancellation()
                    let source = transcript.segments[index], timing = Self.timing(source)
                    guard MeetingEvidenceInterval.isValid(start: timing.start, end: timing.end) else { throw Failure.invalidWord }
                    guard source.text.utf8.count + (source.originalText?.utf8.count ?? 0)
                        <= owner.limits.maximumRetainedTextBytes else { throw Failure.retainedTextLimit }
                }
                if !contextualBarrierEpochIDs.contains(epoch) {
                    try owner.resolveExistingParticipantContext(count: indices.count,
                        originalAt: { transcript.segments[indices[$0]] },
                        attributedAt: { transcript.segments[indices[$0]] },
                        resetsBefore: { position in
                            guard position > 0 else { return false }
                            let previousStart = Self.timing(transcript.segments[indices[position - 1]]).start
                            let end = Self.timing(transcript.segments[indices[position]]).end
                            // Unioned exclusion ends are sorted. A nested word envelope must
                            // not consume an exclusion needed by a later starting source row.
                            var low = 0, high = barriers.count
                            while low < high {
                                let middle = low + (high - low) / 2
                                if barriers[middle].end <= previousStart { low = middle + 1 }
                                else { high = middle }
                            }
                            return low < barriers.count && barriers[low].start < end
                        }) { position, id, token in
                            let index = indices[position], source = transcript.segments[index]
                            result.segments[index].speakerID = id
                            result.segments[index].attributionState = .assigned
                            result.segments[index].speakerIdentityIsProvisional = nil
                            result.segments[index].speakerAttribution = .init(existingParticipantContext: source,
                                token: token, speakerID: id, policy: policy)
                        }
                }
                result.speakers = owner.speakers
                continue
            }
            var barrierCursor = 0
            var previousStart: TimeInterval?
            var offset = 0
            while offset < indices.count {
                try Task.checkCancellation()
                var end = offset, bytes = 0
                while end < indices.count, end - offset < owner.limits.maximumRetainedWords {
                    let segment = transcript.segments[indices[end]]
                    let count = segment.text.utf8.count + (segment.originalText?.utf8.count ?? 0)
                    guard count <= owner.limits.maximumRetainedTextBytes else { throw Failure.retainedTextLimit }
                    if count > owner.limits.maximumRetainedTextBytes - bytes { break }
                    bytes += count
                    end += 1
                }
                let chunkIndices = Array(indices[offset..<end])
                offset = end
                var resolved = chunkIndices.map { transcript.segments[$0] }
                var resetBefore = Set<MeetingTranscriptSegmentID>()
                for segment in resolved {
                    let timing = Self.timing(segment)
                    guard MeetingEvidenceInterval.isValid(start: timing.start, end: timing.end) else { throw Failure.invalidWord }
                    if let previousStart {
                        // A long or nested prior envelope must not consume a later exclusion.
                        // Starts are monotonic in this scope; ends may enclose subsequent words.
                        while barrierCursor < barriers.count, barriers[barrierCursor].end <= previousStart {
                            barrierCursor += 1
                        }
                        if barrierCursor < barriers.count, barriers[barrierCursor].start < timing.end,
                           barriers[barrierCursor].end > previousStart { resetBefore.insert(segment.id) }
                    }
                    previousStart = timing.start
                }
                owner.retained = resolved.map { .init(original: $0, published: $0, committed: false) }
                try owner.applyProvisionalIdentities(to: &resolved,
                    trackKind: trackKinds[epoch.trackID] ?? .microphone, resetBefore: resetBefore,
                    allowRecovery: !contextualBarrierEpochIDs.contains(epoch))
                for (index, segment) in zip(chunkIndices, resolved) { result.segments[index] = segment }
                owner.provisionalPrefixState = owner.retained.last?.provisionalStateAfter ?? .init()
                owner.retained.removeAll(keepingCapacity: true)
            }
            result.speakers = owner.speakers
        }
        result.speakerNameFormat = speakerNameFormat
        return result
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
        let retired = self.retained.prefix { $0.committed && Self.timing($0.original).end < contextStart }.count
        if retired > 0 {
            self.provisionalPrefixState = self.retained[retired - 1].provisionalStateAfter
            self.retained.removeFirst(retired)
        }
        let firstStart = self.retained.map { Self.timing($0.original).start }.min() ?? self.watermarks.commonThrough
        let boutPreroll = self.policy.enableBriefInterruption
            ? self.policy.maximumBriefInterruptionSeconds + self.policy.maximumBriefInterruptionGapSeconds : 0
        self.retainActivityFrom = max(self.retainActivityFrom, max(0, firstStart - boutPreroll))
    }

    private func validateBounds(checkTime: Bool = true) throws {
        guard self.retained.count <= self.limits.maximumRetainedWords else { throw Failure.retainedWordLimit }
        var bytes = 0
        for word in self.retained {
            for count in [word.original.text.utf8.count, word.original.originalText?.utf8.count ?? 0] {
                guard count <= self.limits.maximumRetainedTextBytes - bytes else { throw Failure.retainedTextLimit }
                bytes += count
            }
        }
        if checkTime, let start = self.retained.map({ Self.timing($0.original).start }).min(),
           let end = self.retained.map({ Self.timing($0.original).end }).max(),
           end - start > self.limits.maximumRetainedSeconds { throw Failure.retainedTimeLimit }
    }
}

/// Ephemeral receipt created only by the bounded native-activity owner in this file.
/// It cannot be decoded from a checkpoint or constructed from word counts by a provider.
nonisolated struct MeetingVoicedSpeakerAdmission: Sendable {
    let attemptID: UUID
    let epoch: MeetingAnalysisEpochID
    let tokens: Set<MeetingBackendSpeakerToken>
    fileprivate init(attemptID: UUID, epoch: MeetingAnalysisEpochID, tokens: Set<MeetingBackendSpeakerToken>) {
        self.attemptID = attemptID; self.epoch = epoch; self.tokens = tokens
    }
}

private nonisolated extension MeetingTranscriptSpeakerAttribution {
    init(existingParticipantContext source: MeetingTranscriptSegment, token: MeetingBackendSpeakerToken,
         speakerID: SessionSpeakerID, policy: MeetingSpeakerAttributionPolicy) {
        self.unitID = source.nativeUnitID!
        self.rawAssignment = source.nativeSpeakerAssignment!
        self.selectedToken = token
        self.selectedSpeakerID = speakerID
        self.candidates = source.speakerAttribution?.candidates ?? []
        self.background = source.speakerAttribution?.background ?? []
        self.relation = source.speakerAttribution?.relation ?? .none
        self.rule = .existingParticipantContext
        self.policyVersion = policy.schemaVersion
        self.policyFingerprint = policy.fingerprint
    }

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
