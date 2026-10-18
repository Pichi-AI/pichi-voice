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
    private let onProgress: @Sendable (MeetingStreamingPCMObservation) async throws -> Void
    private let lock = NSLock()
    private var busy = false
    private var closed = false
    private var finished = false
    private var pacing = MeetingPCMPreviewPacing()
    private var update = MeetingIncrementalDiarizationUpdate(activity: [], acceptedThroughSample: 0,
        processedThroughSample: 0, retainedFromSample: 0, isFinal: false)
    private var speakers: [MeetingSessionSpeaker] = []
    private var ownerSamples: MeetingStreamingOwnerVoiceSamples?

    struct OwnerEvidence: Sendable {
        let samples: [MeetingSpeakerVoiceSamples]
        let speakers: [MeetingSessionSpeaker]
        let observation: MeetingStreamingPCMObservation
    }

    init(runtime: MeetingParakeetNemotronRuntime, asr: any MeetingParakeetASRSession,
         diarizer: any MeetingIncrementalNemotronDiarizerSession, trackID: MeetingAudioTrackID,
         attemptID: UUID, configuration: MeetingFinalProcessingConfiguration, speakerNameFormat: String,
         collectOwnerEvidence: Bool = false,
         onProgress: @escaping @Sendable (MeetingStreamingPCMObservation) async throws -> Void) {
        self.runtime = runtime
        self.asr = asr
        self.diarizer = diarizer
        self.trackID = trackID
        self.attemptID = attemptID
        self.configuration = configuration
        self.speakerNameFormat = speakerNameFormat
        self.onProgress = onProgress
        self.ownerSamples = collectOwnerEvidence ? .init(epoch: .init(trackID: trackID, ordinal: 0)) : nil
    }

    func recognize(window: MeetingPCMProgressiveWindow, offset: TimeInterval,
                   preview: (@Sendable (MeetingPCMTranscriptBatch) async throws -> Void)?) async throws -> MeetingStreamingPCMObservation {
        try self.begin()
        defer { self.end() }
        guard offset.isFinite, offset >= 0, offset <= 31_536_000,
              abs(offset * 16_000 - (offset * 16_000).rounded()) < 0.001,
              Int((offset * 16_000).rounded()) == self.update.acceptedThroughSample else {
            throw MeetingIncrementalDiarizationError.nonContiguousInput
        }
        let epoch = MeetingAnalysisEpochID(trackID: self.trackID, ordinal: self.update.acceptedThroughSample)
        let timing = MeetingPCMWindowComputeTiming()
        let phase = try await self.runtime.recognizeProgressivePCMPhase(session: self.asr, window: window,
            offset: offset, epoch: epoch, attemptID: self.attemptID, timing: timing,
            permitsIntermediateObservations: self.pacing.permitsIntermediateObservations, preview: preview,
            consumePCM: { samples, start in
                try Task.checkCancellation()
                self.ownerSamples?.append(samples, sourceStartSample: start)
                let next = try await self.diarizer.appendStreaming(samples, sourceStartSample: start)
                try Task.checkCancellation()
                try self.accept(next, expectedAccepted: start + samples.count, final: false)
                let publication = timing.beginExclusion()
                do {
                    try await self.onProgress(self.observation())
                    timing.endExclusion(since: publication)
                } catch {
                    timing.endExclusion(since: publication)
                    throw error
                }
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
            epoch: epoch, offset: offset, attemptID: self.attemptID, configuration: self.configuration,
            priorProfiles: [], priorSpeakers: self.speakers)
        if output.sampleCount < physicalCount {
            raw.isComplete = false
            for index in raw.segments.indices { raw.segments[index].completeness = .incompleteTrack }
        }
        let attributed = try MeetingPCMRecordingAttribution.assemble(transcript: raw,
            activity: self.activity(), epoch: self.globalEpoch, attemptID: self.attemptID,
            duration: Double(self.update.acceptedThroughSample) / 16_000,
            speakerNameFormat: self.speakerNameFormat,
            speakerAttributionPolicy: self.configuration.speakerAttributionPolicy)
        self.speakers = attributed.mergingSpeakers(into: self.speakers)
        self.pacing.record(computeSeconds: timing.computeSeconds, audioSeconds: Double(physicalCount) / 16_000)
        try Task.checkCancellation()
        return self.observation(batch: attributed, asrStableThroughSample: self.update.acceptedThroughSample)
    }

    func finishStreaming() async throws -> MeetingStreamingPCMObservation {
        try self.begin()
        defer { self.end() }
        let next = try await self.diarizer.finishStreaming(totalSamples: self.update.acceptedThroughSample)
        try Task.checkCancellation()
        try self.accept(next, expectedAccepted: self.update.acceptedThroughSample, final: true)
        self.lock.withLock { self.finished = true }
        return self.observation(asrStableThroughSample: self.update.acceptedThroughSample)
    }

    func discardActivity(beforeSample: Int) async throws {
        try self.begin()
        defer { self.end() }
        guard beforeSample >= self.update.retainedFromSample, beforeSample <= self.update.processedThroughSample else {
            throw MeetingIncrementalDiarizationError.invalidWatermark
        }
        try await self.diarizer.discardActivity(beforeSample: beforeSample)
        try Task.checkCancellation()
        let floor = Double(beforeSample) / 16_000
        self.update = .init(activity: self.update.activity.compactMap {
            let start = max(floor, $0.start)
            return $0.end > start ? .init(slotIndex: $0.slotIndex, start: start, end: $0.end) : nil
        }, acceptedThroughSample: self.update.acceptedThroughSample,
            processedThroughSample: self.update.processedThroughSample, retainedFromSample: beforeSample, isFinal: false)
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
        self.update = .init(activity: [], acceptedThroughSample: 0, processedThroughSample: 0,
                            retainedFromSample: 0, isFinal: false)
    }

    /// Copy only bounded clips and lightweight identities before releasing the prepared pair.
    /// No ASR, diarizer or model reference escapes into the subsequent voice-encoder phase.
    func ownerEvidence() throws -> OwnerEvidence? {
        try self.requireFinished()
        guard let samples = self.ownerSamples?.excerpts, !samples.isEmpty else { return nil }
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
                             asrStableThroughSample: Int? = nil) -> MeetingStreamingPCMObservation {
        .init(batch: batch, activity: self.activity(), acceptedThroughSample: self.update.acceptedThroughSample,
            processedThroughSample: self.update.processedThroughSample, retainedFromSample: self.update.retainedFromSample,
            isFinal: self.update.isFinal, asrStableThroughSample: asrStableThroughSample)
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
        self.ownerSamples?.collect(activity: next.activity, processedThroughSample: next.processedThroughSample)
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

/// Optional identity evidence for the continuous global slots. Keeps two disjoint three-second
/// clips per slot and only a twenty-second acoustic lookback. It never retains a recording,
/// fills silence, trusts an overlapping voice, or changes the diarizer's native attribution.
/// The controller's one worker owns this value; cancellation drops it with the prepared scope.
nonisolated struct MeetingStreamingOwnerVoiceSamples: Sendable {
    static let sampleRate = 16_000
    static let clipFrames = 3 * sampleRate
    static let maximumPCMFrames = 20 * sampleRate
    static let maximumVoiceFrames = 8 * 2 * clipFrames
    private let epoch: MeetingAnalysisEpochID
    private var pcm: [Float] = []
    private var pcmStart = 0
    private var accepted = 0
    private var consumedThrough = 0
    private var clips = [[[Float]]](repeating: [], count: 8)
    private var pending = [[Float]](repeating: [], count: 8)
    private var enabled = true

    init(epoch: MeetingAnalysisEpochID) { self.epoch = epoch }
    var retainedPCMFrames: Int { self.pcm.count }
    var retainedVoiceFrames: Int { self.clips.flatMap { $0 }.reduce(0) { $0 + $1.count } + self.pending.reduce(0) { $0 + $1.count } }
    var excerpts: [MeetingSpeakerVoiceSamples] {
        self.clips.enumerated().compactMap { slot, clips in
            clips.count == 2 ? .init(token: .init(analysisEpochID: self.epoch, label: "slot-\(slot)"), clips: clips) : nil
        }
    }

    mutating func append(_ samples: [Float], sourceStartSample: Int) {
        guard self.enabled else { return }
        guard sourceStartSample == self.accepted, samples.count <= Self.maximumPCMFrames,
              samples.allSatisfy(\.isFinite) else { self.disable(); return }
        self.accepted += samples.count
        let overflow = max(0, self.pcm.count + samples.count - Self.maximumPCMFrames)
        if overflow > 0 { self.pcm.removeFirst(overflow); self.pcmStart += overflow }
        self.pcm.append(contentsOf: samples)
    }

    mutating func collect(activity: [MeetingNemotronSpeakerSegment], processedThroughSample: Int) {
        guard self.enabled, processedThroughSample >= self.consumedThrough,
              processedThroughSample <= self.accepted else { return }
        // Future frames are not scored yet. Retain the trailing edge until a later update,
        // while excluding every actual voice turn's leading/trailing 160 milliseconds.
        let edge = 2_560
        let through = max(self.consumedThrough, processedThroughSample - edge)
        let lower = max(self.consumedThrough, self.pcmStart)
        guard through > lower else { return }
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

    private mutating func disable() {
        self.enabled = false
        self.pcm.removeAll(keepingCapacity: false)
        self.pending.removeAll(keepingCapacity: false)
        self.clips.removeAll(keepingCapacity: false)
    }
}
