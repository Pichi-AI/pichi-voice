import Foundation

/// Bounded raw echo evidence belongs to the same streaming attempt as privacy and speaker
/// admission. It never owns PCM or durable text. Each source continues independently: a later
/// application result can correct only echo metadata on already protected microphone words.
/// The shared deterministic scorer is also used by recorded-file canonical assembly.
actor MeetingStreamingEchoAdmission {
    typealias PresentationInterval = @Sendable (MeetingAudioTrackID, Double, Double) -> (start: Double, end: Double)?
    typealias PresentationThrough = @Sendable (MeetingAudioTrackID, Double) -> Double?

    struct Limits: Sendable {
        var historySeconds: Double = 60
        var maximumRawUnits = 8_192
        var maximumRawUTF8Bytes = 1_048_576
        var maximumActivityIntervals = 8_192
        var maximumUnpublishedFlags = 8_192
    }

    enum Failure: Error, Equatable {
        case invalidTopology, invalidObservation, regressedCursor, lateEvidence, resourceLimit, closed
    }

    struct Diagnostics: Sendable {
        let retainedRawUnits: Int
        let retainedRawUTF8Bytes: Int
        let unpublishedFlags: Int
        let pendingRevisions: Int
        let mutableFromSeconds: Double
        let closed: Bool
    }

    private struct RawUnit {
        let positioned: MeetingPositionedEchoUnit
        let segmentID: MeetingTranscriptSegmentID
        let native: MeetingFinalTextUnit
    }
    private struct Source {
        let kind: MeetingAudioTrackKind
        var units: [RawUnit] = []
        var activity: [MeetingBackendSpeakerActivity] = []
        var acceptedThroughSample = 0
        var processedThroughSample = 0
        var asrThroughSample = 0
        var sealed = false
    }

    private var sources: [MeetingAudioTrackID: Source]
    private let microphoneID: MeetingAudioTrackID
    private let applicationID: MeetingAudioTrackID
    private let limits: Limits
    private let presentationInterval: PresentationInterval
    private let presentationThrough: PresentationThrough
    private var latestPresentation = 0.0
    private var latestFlags: [MeetingTranscriptSegmentID: Bool] = [:]
    private var unpublished = Set<MeetingTranscriptSegmentID>()
    private var pendingRevisions: [MeetingTranscriptSegmentID: Bool] = [:]
    private var closed = false

    init(tracks: [MeetingAudioTrack], limits: Limits = .init(),
         presentationInterval: @escaping PresentationInterval = { _, start, end in (start, end) },
         presentationThrough: @escaping PresentationThrough = { _, time in time }) throws {
        guard tracks.count == 2, Set(tracks.map(\.id)).count == 2,
              let microphone = tracks.first(where: { $0.kind == .microphone }),
              let application = tracks.first(where: { $0.kind == .applicationAudio }),
              limits.historySeconds.isFinite, limits.historySeconds > 0,
              limits.maximumRawUnits > 0, limits.maximumRawUTF8Bytes > 0,
              limits.maximumActivityIntervals > 0, limits.maximumUnpublishedFlags > 0 else {
            throw Failure.invalidTopology
        }
        self.microphoneID = microphone.id
        self.applicationID = application.id
        self.sources = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, Source(kind: $0.kind)) })
        self.limits = limits
        self.presentationInterval = presentationInterval
        self.presentationThrough = presentationThrough
    }

    /// Native acoustic progress may revise candidate visibility independently of ASR. Neither
    /// source waits for the other source, future audio, or the enclosing prepared scope's EOF.
    /// The caller must keep source operations ordered and invoke this before privacy admission.
    func observe(track: MeetingAudioTrack, observation: MeetingStreamingPCMObservation) throws -> MeetingStreamingPCMObservation {
        do {
            try Task.checkCancellation()
            guard !self.closed else { throw Failure.closed }
            guard var source = self.sources[track.id], source.kind == track.kind,
                  observation.acceptedThroughSample >= source.acceptedThroughSample,
                  observation.processedThroughSample >= source.processedThroughSample,
                  observation.processedThroughSample <= observation.acceptedThroughSample,
                  observation.retainedFromSample >= 0,
                  observation.retainedFromSample <= observation.processedThroughSample else {
                throw Failure.invalidObservation
            }
            guard !source.sealed || observation.batch.segments.isEmpty,
                  observation.batch.segments.count <= self.limits.maximumRawUnits,
                  observation.activity.count <= self.limits.maximumActivityIntervals else { throw Failure.resourceLimit }
            var inputBytes = 0
            for segment in observation.batch.segments {
                guard segment.text.utf8.count <= self.limits.maximumRawUTF8Bytes - inputBytes else { throw Failure.resourceLimit }
                inputBytes += segment.text.utf8.count
            }
            let priorActivity = source.activity
            let oldASR = source.asrThroughSample
            if let asr = observation.asrStableThroughSample {
                guard asr >= oldASR, asr <= observation.acceptedThroughSample else { throw Failure.regressedCursor }
                source.asrThroughSample = asr
            } else if !observation.batch.segments.isEmpty {
                throw Failure.invalidObservation
            }
            source.acceptedThroughSample = observation.acceptedThroughSample
            source.processedThroughSample = observation.processedThroughSample
            if let through = self.presentationThrough(track.id, Double(observation.acceptedThroughSample) / 16_000) {
                guard through.isFinite, through >= 0 else { throw Failure.invalidObservation }
                self.latestPresentation = max(self.latestPresentation, through)
            }
            let nativeFloor = Double(observation.retainedFromSample) / 16_000
            var activity: [MeetingBackendSpeakerActivity] = source.activity.compactMap { interval in
                guard interval.start < nativeFloor else { return nil }
                return .init(token: interval.token, start: interval.start, end: min(interval.end, nativeFloor))
            }
            let epoch = MeetingAnalysisEpochID(trackID: track.id, ordinal: 0)
            for interval in observation.activity {
                guard interval.token.analysisEpochID == epoch,
                      interval.start.isFinite, interval.end.isFinite,
                      interval.start >= nativeFloor, interval.end > interval.start,
                      interval.end <= Double(observation.processedThroughSample) / 16_000 + 0.000_001 else {
                    throw Failure.invalidObservation
                }
                activity.append(interval)
            }
            source.activity = activity
            let existingIDs = Set(source.units.map(\.segmentID))
            var insertedIDs = Set<MeetingTranscriptSegmentID>()
            for segment in observation.batch.segments {
                guard segment.sourceTrackID == track.id,
                      let native = segment.nativeTiming, let precision = segment.nativePrecision,
                      native.start.isFinite, native.end.isFinite, native.start >= Double(oldASR) / 16_000 - 0.001,
                      native.end > native.start, native.end <= Double(source.asrThroughSample) / 16_000 + 0.001,
                      !existingIDs.contains(segment.id), insertedIDs.insert(segment.id).inserted else {
                    throw Failure.invalidObservation
                }
                guard let projected = self.presentationInterval(track.id, native.start, native.end) else { continue }
                guard projected.start.isFinite, projected.end.isFinite, projected.start >= 0,
                      projected.end > projected.start else { throw Failure.invalidObservation }
                // A genuinely delayed source cannot revise expired raw context silently. A
                // normal capture gap contains no old units and therefore never waits or fails.
                guard projected.start + 0.001 >= self.mutableFrom else { throw Failure.lateEvidence }
                let id = segment.id.uuidString
                let positioned = MeetingPositionedEchoUnit(id: id, trackID: track.id, text: segment.text,
                    presentation: .init(start: projected.start, end: projected.end))
                // Boundary recovery may cross only a continuous physical source island.
                let rawOffset = (projected.start - native.start) * 16_000
                guard rawOffset.isFinite, abs(rawOffset) < Double(Int64.max / 2) else { throw Failure.invalidObservation }
                let offset = Int64(rawOffset.rounded())
                let raw = MeetingFinalTextUnit(id: id, trackID: track.id, analysisEpochID: epoch,
                    precision: precision, text: segment.text, analysisStart: native.start, analysisEnd: native.end,
                    speaker: segment.nativeSpeakerAssignment ?? .unassigned,
                    analysisSpanIDs: ["streaming-offset:\(offset)"], confidence: nil)
                source.units.append(.init(positioned: positioned, segmentID: segment.id, native: raw))
                if track.kind == .microphone { self.unpublished.insert(segment.id) }
            }
            self.sources[track.id] = source
            self.prune()
            try self.checkBounds()
            if !observation.batch.segments.isEmpty
                || (track.kind == .applicationAudio && priorActivity != self.sources[track.id]?.activity) {
                try self.recompute()
            }
            try self.checkBounds()
            var batch = observation.batch
            if track.kind == .microphone {
                for index in batch.segments.indices {
                    if let flag = self.latestFlags[batch.segments[index].id] { batch.segments[index].isLikelyEcho = flag }
                }
            }
            return Self.replacingBatch(observation, with: batch)
        } catch {
            self.cancel()
            throw error
        }
    }

    /// The publication owner invokes this under its existing serialization gate. Privacy can
    /// hold a word beyond a later echo observation; its first durable value still gets the latest
    /// flag. Echo-only patches never replace text, timing, native evidence or user corrections.
    func admitting(_ safeBatch: MeetingPCMTranscriptBatch) throws -> MeetingPCMTranscriptBatch {
        try Task.checkCancellation()
        guard !self.closed else { throw Failure.closed }
        var batch = safeBatch
        for index in batch.segments.indices {
            let id = batch.segments[index].id
            if let flag = self.latestFlags[id] { batch.segments[index].isLikelyEcho = flag }
            self.unpublished.remove(id)
        }
        var revisions = Dictionary(batch.echoRevisions.map { ($0.segmentID, $0.isLikelyEcho) }, uniquingKeysWith: { _, last in last })
        for (id, flag) in self.pendingRevisions { revisions[id] = flag }
        batch.echoRevisions = revisions.sorted { $0.key.uuidString < $1.key.uuidString }
            .map { .init(segmentID: $0.key, isLikelyEcho: $0.value) }
        self.pendingRevisions.removeAll(keepingCapacity: true)
        self.pruneFlags()
        return batch
    }

    /// Metadata can change while a source's new private words still await their own admission.
    /// This patch carries only existing product IDs and booleans, with no source preview to clear.
    func pendingRevisionBatch() -> MeetingPCMTranscriptBatch? {
        guard !self.closed, !self.pendingRevisions.isEmpty else { return nil }
        var batch = MeetingPCMTranscriptBatch(segments: [])
        batch.echoRevisions = self.pendingRevisions.sorted { $0.key.uuidString < $1.key.uuidString }
            .map { .init(segmentID: $0.key, isLikelyEcho: $0.value) }
        self.pendingRevisions.removeAll(keepingCapacity: true)
        return batch
    }

    func markSealed(trackID: MeetingAudioTrackID) throws {
        guard !self.closed, var source = self.sources[trackID] else { throw Failure.closed }
        source.sealed = true
        self.sources[trackID] = source
        try self.recompute()
    }

    func cancel() {
        self.closed = true
        self.sources.removeAll(keepingCapacity: false)
        self.latestFlags.removeAll(keepingCapacity: false)
        self.unpublished.removeAll(keepingCapacity: false)
        self.pendingRevisions.removeAll(keepingCapacity: false)
    }

    var diagnostics: Diagnostics {
        .init(retainedRawUnits: self.sources.values.reduce(0) { $0 + $1.units.count },
            retainedRawUTF8Bytes: self.sources.values.reduce(0) { $0 + $1.units.reduce(0) { $0 + $1.positioned.text.utf8.count } },
            unpublishedFlags: self.unpublished.count, pendingRevisions: self.pendingRevisions.count,
            mutableFromSeconds: self.mutableFrom, closed: self.closed)
    }

    private var mutableFrom: Double { max(0, self.latestPresentation - self.limits.historySeconds) }

    private func recompute() throws {
        guard let microphone = self.sources[self.microphoneID], let application = self.sources[self.applicationID] else { throw Failure.closed }
        let activityByEpoch = Dictionary(grouping: application.activity) { $0.token.analysisEpochID }
        let units = application.units.map(\.native)
        let boundaryAssignments = MeetingWordBoundaryRecovery.assignments(units: units, activityByEpoch: activityByEpoch)
        let eligibleApplication = application.units.filter {
            !MeetingSpeakerActivityCoverage.isOutside($0.native, activityByEpoch: activityByEpoch,
                boundaryAssignments: boundaryAssignments)
        }.map(\.positioned)
        let verdicts = try MeetingPositionedEchoScoring.verdicts(microphoneUnits: microphone.units.map(\.positioned),
            applicationUnits: eligibleApplication)
        for unit in microphone.units where unit.positioned.presentation.start + 0.001 >= self.mutableFrom {
            guard let verdict = verdicts[unit.positioned.id] else { throw Failure.invalidObservation }
            let next: Bool
            switch verdict { case .notEcho: next = false; case .echoSuppressed: next = true }
            if let prior = self.latestFlags[unit.segmentID], prior != next {
                self.pendingRevisions[unit.segmentID] = next
            }
            self.latestFlags[unit.segmentID] = next
        }
    }

    private func prune() {
        let contextFloor = max(0, self.mutableFrom - MeetingPositionedEchoScoring.wordContextSeconds)
        for id in Array(self.sources.keys) {
            guard var source = self.sources[id] else { continue }
            source.units.removeAll { $0.positioned.presentation.end <= contextFloor }
            let nativeFloor = source.units.map { $0.native.analysisStart }.min()
                ?? max(0, Double(source.processedThroughSample) / 16_000 - self.limits.historySeconds)
            source.activity = source.activity.compactMap { interval in
                guard interval.end > nativeFloor else { return nil }
                return .init(token: interval.token, start: max(interval.start, nativeFloor), end: interval.end)
            }
            self.sources[id] = source
        }
        self.pruneFlags()
    }

    private func pruneFlags() {
        let active = Set(self.sources[self.microphoneID]?.units.map(\.segmentID) ?? [])
        for id in Array(self.latestFlags.keys) where !active.contains(id) && !self.unpublished.contains(id) {
            self.latestFlags.removeValue(forKey: id)
        }
    }

    private func checkBounds() throws {
        let value = self.diagnostics
        guard value.retainedRawUnits <= self.limits.maximumRawUnits,
              value.retainedRawUTF8Bytes <= self.limits.maximumRawUTF8Bytes,
              value.unpublishedFlags <= self.limits.maximumUnpublishedFlags,
              self.pendingRevisions.count <= self.limits.maximumRawUnits,
              self.latestFlags.count <= self.limits.maximumRawUnits + self.limits.maximumUnpublishedFlags,
              self.sources.values.reduce(0, { $0 + $1.activity.count }) <= self.limits.maximumActivityIntervals else {
            throw Failure.resourceLimit
        }
    }

    private static func replacingBatch(_ observation: MeetingStreamingPCMObservation,
                                       with batch: MeetingPCMTranscriptBatch) -> MeetingStreamingPCMObservation {
        .init(batch: batch, activity: observation.activity, acceptedThroughSample: observation.acceptedThroughSample,
            processedThroughSample: observation.processedThroughSample, retainedFromSample: observation.retainedFromSample,
            isFinal: observation.isFinal, asrStableThroughSample: observation.asrStableThroughSample,
            sealedEmptyASRRange: observation.sealedEmptyASRRange,
            confirmedLocalUserTokens: observation.confirmedLocalUserTokens)
    }
}
