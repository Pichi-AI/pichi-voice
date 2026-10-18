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
         collectOwnerEvidence: Bool = false, useAdaptiveOwnerEvidence: Bool = false,
         onProgress: @escaping @Sendable (MeetingStreamingPCMObservation) async throws -> Void) {
        self.runtime = runtime
        self.asr = asr
        self.diarizer = diarizer
        self.trackID = trackID
        self.attemptID = attemptID
        self.configuration = configuration
        self.speakerNameFormat = speakerNameFormat
        self.useAdaptiveOwnerEvidence = useAdaptiveOwnerEvidence
        self.onProgress = onProgress
        self.ownerSamples = collectOwnerEvidence
            ? .init(epoch: .init(trackID: trackID, ordinal: 0), useAdaptiveOwnerEvidence: useAdaptiveOwnerEvidence) : nil
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
                if self.useAdaptiveOwnerEvidence {
                    // A coalesced twenty-second ASR delta may exceed the acoustic scoring
                    // lag. Feed the same PCM in bounded slices before optional owner lookback
                    // can evict its unscored tail. Publication still occurs once per ASR delta.
                    for local in stride(from: 0, to: samples.count, by: 16_000) {
                        try Task.checkCancellation()
                        let end = min(samples.count, local + 16_000)
                        let portion = Array(samples[local..<end])
                        self.ownerSamples?.append(portion, sourceStartSample: start + local)
                        let next = try await self.diarizer.appendStreaming(portion, sourceStartSample: start + local)
                        try Task.checkCancellation()
                        try self.accept(next, expectedAccepted: start + end, final: false)
                    }
                } else {
                    self.ownerSamples?.append(samples, sourceStartSample: start)
                    let next = try await self.diarizer.appendStreaming(samples, sourceStartSample: start)
                    try Task.checkCancellation()
                    try self.accept(next, expectedAccepted: start + samples.count, final: false)
                }
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

    /// The finished owner transfers its arrays before native model cleanup, avoiding a
    /// second full copy of all eight voices while ASR and diarizer weights still reside.
    mutating func takeExcerpts() -> [MeetingSpeakerVoiceSamples] {
        guard self.enabled else { return [] }
        guard self.useAdaptiveOwnerEvidence else {
            let result = self.excerpts
            self.clips.removeAll(keepingCapacity: false); self.pending.removeAll(keepingCapacity: false)
            return result
        }
        for slot in 0..<8 where !self.pending[slot].isEmpty {
            if self.pending[slot].count >= 800, Self.hasUsableOwnerSignal(self.pending[slot]) {
                self.retainAdaptive(self.pending[slot][...], slot: slot)
            }
            self.pending[slot].removeAll(keepingCapacity: false)
        }
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
