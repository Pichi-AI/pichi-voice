import AVFoundation
import CoreMedia
import Foundation

/// Internal live-only source tags: `.you` is the microphone track and `.them` is application audio.
/// Protected streaming results can additionally supply participant presentation without
/// changing source routing or partial recognition contracts.
nonisolated enum MeetingLiveSpeaker: Sendable, Equatable {
    case you
    case them
}

nonisolated enum MeetingLiveAvailability: Sendable, Equatable {
    case unavailable(reason: String)
    case degraded(reason: String)
    case available
}

nonisolated struct MeetingLiveUtterance: Identifiable, Sendable, Equatable {
    var id: UUID
    var speaker: MeetingLiveSpeaker
    var text: String
    /// Session-relative seconds, derived from capture PTS — never from arrival order.
    var start: TimeInterval
    var end: TimeInterval
    /// A contextual privacy preview can expose only part of this finalized turn.
    /// Its original end then cannot retire the audio still waiting for safe text.
    var hasIncompleteTextCoverage = false
    /// Optional product speaker evidence for protected streaming results. Source-only engines
    /// and provisional hypotheses do not claim a participant identity.
    var participant: MeetingSpeakerPresentation? = nil
}

/// `id` is minted at the turn's first partial and reused as the `MeetingLiveUtterance.id` at EOU,
/// so SwiftUI keeps one continuous row identity as the bubble "solidifies".
nonisolated struct MeetingLivePartial: Sendable, Equatable, Identifiable {
    var id: UUID
    var text: String
    var start: TimeInterval
    /// Upper capture bound for actually visible speech. Nil when publication cannot
    /// safely map its text prefix back to a complete audio fragment.
    var end: TimeInterval? = nil
    /// Whole-word prefix repeated in consecutive observations of this same turn.
    /// This is recognition evidence, not permission to publish unredacted text.
    var stableUTF16Count: Int? = nil
    /// Set by privacy projection when a visible prefix contains a real replacement mask.
    var containsPrivacyReplacement = false
}

/// Batch recognizers revise a growing audio prefix. Only words repeated across
/// observations are eligible for contextual privacy inference before the turn ends.
nonisolated enum MeetingSpeechHypothesisStability {
    static func stableUTF16Count(previous: String, current: String) -> Int {
        guard previous.utf16.count <= 32_768, current.utf16.count <= 32_768 else { return 0 }
        let common = String(zip(previous, current).prefix { $0.0 == $0.1 }.map(\.0))
        var boundary = common.startIndex
        for index in common.indices where common[index].isWhitespace {
            boundary = common.index(after: index)
        }
        // A repeated sentence terminator closes its preceding word. An open last
        // token remains tentative even if two short hypotheses happened to match.
        if let last = common.last, ".!?…".contains(last) { boundary = common.endIndex }
        return common[..<boundary].utf16.count
    }
}

/// In-memory only. Never written into `MeetingSession.transcriptSegments`, so it can never reach
/// the manifest, Copy Transcript, or Export — those all read a `MeetingSession` value, a type this
/// struct cannot become.
nonisolated struct MeetingLiveTranscriptSnapshot: Sendable, Equatable {
    private static let finalizedTurnIDCap = 64

    /// Assigned under the coordinator's state lock, independently of callback delivery order.
    var revision: UInt64 = 0
    var utterances: [MeetingLiveUtterance] = []
    var partials: [MeetingLiveSpeaker: MeetingLivePartial] = [:]
    var availability: MeetingLiveAvailability = .unavailable(reason: "Live captions have not started.")
    /// Turn IDs whose EOU already fired — a partial for one of these is a stale, out-of-order
    /// arrival that must not resurrect a bubble. Oldest-first so eviction trims from the front.
    private(set) var finalizedTurnIDs: [UUID] = []

    static let empty = MeetingLiveTranscriptSnapshot()

    /// Old callbacks must neither roll back this session nor repopulate a stopped/new session.
    func accepts(_ update: Self, generation: UUID, activeGeneration: UUID?) -> Bool {
        generation == activeGeneration && update.revision > self.revision
    }

    /// Inserts keeping `utterances` sorted by `start` — two engines finalize independently, so a
    /// later-arriving utterance with an earlier PTS must still land in the right place.
    func inserting(_ utterance: MeetingLiveUtterance) -> MeetingLiveTranscriptSnapshot {
        var copy = self
        let index = copy.utterances.firstIndex { $0.start > utterance.start } ?? copy.utterances.count
        copy.utterances.insert(utterance, at: index)
        copy.markFinalized(utterance.id)
        return copy
    }

    /// Replaces, never appends — and drops a partial whose turn already finalized.
    func settingPartial(_ partial: MeetingLivePartial?, for speaker: MeetingLiveSpeaker) -> MeetingLiveTranscriptSnapshot {
        var copy = self
        if var partial, !partial.text.isEmpty {
            guard !copy.finalizedTurnIDs.contains(partial.id) else { return copy }
            if partial.stableUTF16Count == nil, let previous = copy.partials[speaker], previous.id == partial.id {
                partial.stableUTF16Count = MeetingSpeechHypothesisStability.stableUTF16Count(
                    previous: previous.text, current: partial.text)
            }
            copy.partials[speaker] = partial
        } else {
            copy.partials.removeValue(forKey: speaker)
        }
        return copy
    }

    /// Finalizes a turn without an utterance — the echo-suppression path, where the bubble is
    /// discarded rather than solidified.
    func markingFinalized(_ id: UUID) -> MeetingLiveTranscriptSnapshot {
        var copy = self
        copy.markFinalized(id)
        return copy
    }

    /// A checkpoint commits one source. An unrelated source's preview cannot restore
    /// the committing source's older hypothesis while the reading projection awaits.
    func preservingConcurrentPartials(from current: Self,
                                      since previous: [MeetingLiveSpeaker: MeetingLivePartial],
                                      committing source: MeetingLiveSpeaker?) -> Self {
        var result = self
        for key in [MeetingLiveSpeaker.you, .them] {
            if key != source || current.partials[key] != previous[key] {
                result.partials[key] = current.partials[key]
            }
        }
        return result
    }

    private mutating func markFinalized(_ id: UUID) {
        guard !self.finalizedTurnIDs.contains(id) else { return }
        self.finalizedTurnIDs.append(id)
        if self.finalizedTurnIDs.count > Self.finalizedTurnIDCap {
            self.finalizedTurnIDs.removeFirst(self.finalizedTurnIDs.count - Self.finalizedTurnIDCap)
        }
    }

    /// True when this snapshot holds words the earlier one did not: somebody is talking. A caption
    /// that only went away, or captions becoming available, is not speech.
    func hasNewWords(since earlier: MeetingLiveTranscriptSnapshot) -> Bool {
        // Participant refinement is presentation metadata, not additional speech. Keep the
        // common append/refinement path allocation-free even for a long live transcript.
        if self.utterances.count > earlier.utterances.count { return true }
        if self.utterances.count == earlier.utterances.count {
            if zip(self.utterances, earlier.utterances).contains(where: { $0.id != $1.id || $0.text != $1.text }) { return true }
        } else {
            let earlierText = Dictionary(earlier.utterances.map { ($0.id, $0.text) },
                                         uniquingKeysWith: { _, latest in latest })
            if self.utterances.contains(where: { earlierText[$0.id] != $0.text }) { return true }
        }
        return self.partials.contains { speaker, partial in earlier.partials[speaker]?.text != partial.text }
    }

    func settingAvailability(_ availability: MeetingLiveAvailability) -> MeetingLiveTranscriptSnapshot {
        var copy = self
        copy.availability = availability
        return copy
    }
}

/// Pure row composition for the live captions card: finalized turns in transcript order, then
/// active partials bottom-pinned by turn start, so a solidifying bubble keeps its row identity.
nonisolated enum MeetingLiveBubbleComposer {
    nonisolated struct Row: Identifiable, Equatable, Sendable {
        var id: UUID
        var speaker: MeetingLiveSpeaker
        var text: String
        var isPartial: Bool
        var showsLabel: Bool
        var participant: MeetingSpeakerPresentation? = nil
        /// Original session-relative first-word time, retained independently of reading ownership.
        var start: TimeInterval = 0
        /// The first word of the current readable participant turn, including layout continuations.
        var readingTurnStart: TimeInterval = 0

        var hasReadableParticipant: Bool {
            participant?.hasReadableParticipant == true
        }

        func hasSameSpeaker(as other: Self) -> Bool {
            speaker == other.speaker && participant?.identity == other.participant?.identity
        }
    }

    static func rowsForDisplay(_ snapshot: MeetingLiveTranscriptSnapshot) async throws -> [Row] {
        let work = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let rows = Self.rows(for: snapshot)
            try Task.checkCancellation()
            return rows
        }
        return try await withTaskCancellationHandler {
            let result = try await work.value
            try Task.checkCancellation()
            return result
        } onCancel: { work.cancel() }
    }

    static func rows(for snapshot: MeetingLiveTranscriptSnapshot) -> [Row] {
        var rows = snapshot.utterances.map {
            Row(id: $0.id, speaker: $0.speaker, text: $0.text, isPartial: false,
                showsLabel: false, participant: $0.participant, start: $0.start)
        }
        let activePartials = [MeetingLiveSpeaker.you, .them]
            .compactMap { speaker in snapshot.partials[speaker].map { (speaker, $0) } }
            .filter { pair in !snapshot.utterances.contains { $0.id == pair.1.id } }
            .sorted { $0.1.start < $1.1.start }
        for (speaker, partial) in activePartials {
            rows.append(Row(id: partial.id, speaker: speaker, text: partial.text, isPartial: true,
                            showsLabel: false, start: partial.start))
        }

        // A capture source can contain several voices. Only explicit participant evidence
        // continues a readable turn; unresolved words and source-only hypotheses cannot
        // borrow the previous participant's identity.
        var readingTurns: [MeetingLiveSpeaker: (participant: MeetingSpeakerPresentation, start: TimeInterval)] = [:]
        for index in rows.indices {
            let source = rows[index].speaker
            let previous = readingTurns[source]
            if rows[index].hasReadableParticipant, let participant = rows[index].participant {
                let start = previous.flatMap { $0.participant.identity == participant.identity ? $0.start : nil }
                    ?? rows[index].start
                readingTurns[source] = (participant, start)
                rows[index].readingTurnStart = start
            } else {
                readingTurns.removeValue(forKey: source)
                rows[index].readingTurnStart = rows[index].start
            }
        }

        var labelIndex = rows.startIndex
        for index in rows.indices {
            // A source header is useful before participant identification is available.
            rows[index].showsLabel = index == rows.startIndex || !rows[index].hasSameSpeaker(as: rows[index - 1])
            if rows[index].showsLabel { labelIndex = index }
            // The visible header belongs to the complete continuous reading turn, even
            // when long text is divided into several layout paragraphs below that header.
            if rows[index].participant?.isEstimated == true {
                rows[labelIndex].participant = rows[labelIndex].participant?.markingEstimated()
            }
        }
        return rows
    }
}

nonisolated enum MeetingLiveTimeConversion {
    /// Mirrors the batch pipeline: session time is capture PTS relative to the capture origin,
    /// clamped at zero. Never derived from converted-sample counts or wall-clock arrival time.
    static func sessionSeconds(pts: CMTime, origin: CMTime) -> TimeInterval {
        guard pts.isValid, pts.isNumeric, origin.isValid, origin.isNumeric else { return 0 }
        return max(0, CMTimeGetSeconds(pts - origin))
    }
}

/// Thread-safe, set-once-per-session capture origin shared by both source tracks so their
/// timestamps land on the same clock.
final nonisolated class MeetingLiveOriginBox: @unchecked Sendable {
    private let lock = NSLock()
    private var origin: CMTime?
    private var frozen = false

    /// A recording's master origin never follows a later packet or a restarted producer.
    @discardableResult
    func freeze(_ pts: CMTime) -> CMTime {
        self.lock.withLock {
            if self.frozen, let origin { return origin }
            self.origin = pts
            self.frozen = true
            return pts
        }
    }

    @discardableResult
    func establish(_ pts: CMTime) -> CMTime {
        self.lock.lock()
        defer { self.lock.unlock() }
        if let existing = self.origin {
            if self.frozen { return existing }
            let earliest = min(pts, existing)
            self.origin = earliest
            return earliest
        }
        self.origin = pts
        return pts
    }

    var current: CMTime? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.origin
    }
}

/// One immutable host-clock axis and ownership scope for a capture attempt. Frame positions
/// remain media coordinates; only measured host intervals determine recording time.
final nonisolated class MeetingRecordingClock: @unchecked Sendable {
    enum Failure: LocalizedError {
        case invalidTimebase, invalidPacket, retiredProducer, unprovenClock
        var errorDescription: String? { PichiLocalization.text("Audio timing could not be verified.") }
    }
    let id: UUID
    let origin: CMTime
    private let lock = NSLock()
    private var epochs: [MeetingAudioTrackID: UInt64] = [:]

    init(timebase: MeetingTimebaseMetadata, id: UUID = UUID()) throws {
        guard timebase.machTimebaseNumerator > 0, timebase.machTimebaseDenominator > 0 else {
            throw Failure.invalidTimebase
        }
        let seconds = Double(timebase.startedHostTime) * Double(timebase.machTimebaseNumerator)
            / Double(timebase.machTimebaseDenominator) / 1_000_000_000
        guard seconds.isFinite, seconds >= 0 else { throw Failure.invalidTimebase }
        self.id = id
        self.origin = CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
    }

    func source(_ sourceID: MeetingAudioTrackID) -> MeetingRecordingClockContext {
        MeetingRecordingClockContext(clock: self, sourceID: sourceID)
    }

    fileprivate func reserveEpoch(sourceID: MeetingAudioTrackID) -> UInt64 {
        self.lock.withLock {
            let next = (self.epochs[sourceID] ?? 0) + 1
            self.epochs[sourceID] = next
            return next
        }
    }
}

nonisolated struct MeetingRecordingClockContext: Sendable {
    let clock: MeetingRecordingClock
    let sourceID: MeetingAudioTrackID
    var clockID: UUID { self.clock.id }
    var origin: CMTime { self.clock.origin }

    func reserveEpoch() -> UInt64 { self.clock.reserveEpoch(sourceID: self.sourceID) }

    func accepts(_ packet: MeetingCaptureClockMetadata.Packet) -> Bool {
        packet.clockID == self.clockID && packet.sourceID == self.sourceID
    }

    func mapping(frameCount: Int, start: CMTime, end: CMTime,
                 discontinuityBefore: Bool) throws -> MeetingAudioClockMapping {
        guard frameCount > 0, frameCount <= 65_536,
              start.isNumeric, end.isNumeric, end > start,
              start >= self.origin else { throw MeetingRecordingClock.Failure.invalidPacket }
        return try MeetingAudioClockMapping(frameCount: Int64(frameCount), spans: [
            MeetingAudioClockSpan(frameStart: 0, frameEnd: Double(frameCount),
                hostStart: .init(value: start.convertScale(1_000_000_000, method: .default).value,
                                 timescale: 1_000_000_000),
                hostEnd: .init(value: end.convertScale(1_000_000_000, method: .default).value,
                               timescale: 1_000_000_000),
                discontinuityBefore: discontinuityBefore)
        ]).validated(expectedFrameCount: Int64(frameCount))
    }

    /// Copies only the bounded audio block. It never retains an arbitrary native backing store.
    static func ownedCopy(_ sample: CMSampleBuffer) throws -> CMSampleBuffer {
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0, frames <= 65_536, CMSampleBufferDataIsReady(sample),
              let format = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM, asbd.mBitsPerChannel == 32,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mSampleRate.isFinite, (8_000...192_000).contains(asbd.mSampleRate),
              (1...8).contains(asbd.mChannelsPerFrame),
              let block = CMSampleBufferGetDataBuffer(sample) else {
            throw MeetingRecordingClock.Failure.invalidPacket
        }
        let bytes = CMBlockBufferGetDataLength(block)
        guard bytes > 0, bytes <= 2 * 1024 * 1024 else { throw MeetingRecordingClock.Failure.invalidPacket }
        var copied: CMBlockBuffer?
        guard CMBlockBufferCreateContiguous(allocator: kCFAllocatorDefault, sourceBuffer: block,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: bytes, flags: kCMBlockBufferAlwaysCopyDataFlag, blockBufferOut: &copied) == noErr,
              let copied else { throw MeetingRecordingClock.Failure.invalidPacket }
        var timing = CMSampleTimingInfo()
        guard CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing) == noErr else {
            throw MeetingRecordingClock.Failure.invalidPacket
        }
        var result: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: copied,
            formatDescription: format, sampleCount: frames, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &result) == noErr, let result else { throw MeetingRecordingClock.Failure.invalidPacket }
        return result
    }

    func timedCopy(_ sample: CMSampleBuffer, mapping: MeetingAudioClockMapping,
                   producerEpoch: UInt64) throws -> CMSampleBuffer {
        if let previous = MeetingCaptureClockMetadata.read(from: sample), !self.accepts(previous) {
            throw MeetingRecordingClock.Failure.invalidPacket
        }
        let sample = try Self.ownedCopy(sample)
        let frames = CMSampleBufferGetNumSamples(sample)
        let mapping = try mapping.validated(expectedFrameCount: Int64(frames))
        guard let first = mapping.spans.first, let last = mapping.spans.last else {
            throw MeetingRecordingClock.Failure.invalidPacket
        }
        let start = CMTime(value: first.hostStart.value, timescale: first.hostStart.timescale)
        let end = CMTime(value: last.hostEnd.value, timescale: last.hostEnd.timescale)
        var timing = CMSampleTimingInfo(duration: CMTimeMultiplyByRatio(end - start, multiplier: 1,
            divisor: Int32(frames)), presentationTimeStamp: start, decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
            sampleBuffer: sample, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleBufferOut: &result) == noErr, let result else { throw MeetingRecordingClock.Failure.invalidPacket }
        try MeetingCaptureClockMetadata.attach(mapping: mapping, clockID: self.clockID,
            sourceID: self.sourceID, producerEpoch: producerEpoch, to: result)
        return result
    }
}

/// Finalizes one pending packet using the next measured acquisition anchor. Callback arrival
/// time is never an anchor. A real source gap closes the previous interval without filling it.
final nonisolated class MeetingCaptureSourceClock: @unchecked Sendable {
    private struct Pending {
        let sample: CMSampleBuffer
        let nativeStart: CMTime
        let nativeEnd: CMTime
        let hostStart: CMTime
        let projectedHostEnd: CMTime
        let rate: Double
        let frames: Int
        let sourceFrameStart: Int64?
        let epoch: UInt64
        let discontinuity: Bool
    }
    let context: MeetingRecordingClockContext
    private let lock = NSLock()
    private var pending: Pending?
    private var generation: UInt64?
    private var epoch: UInt64 = 0
    private var format: CMFormatDescription?

    init(context: MeetingRecordingClockContext) { self.context = context }

    func offer(_ input: CMSampleBuffer, producerGeneration: UInt64,
               sourceClock: CMClockOrTimebase? = nil, acquisitionStart: CMTime? = nil,
               sourceFrameStart: Int64? = nil) throws -> [CMSampleBuffer] {
        try self.lock.withLock {
            let sample = try MeetingRecordingClockContext.ownedCopy(input)
            guard let description = CMSampleBufferGetFormatDescription(sample),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else {
                throw MeetingRecordingClock.Failure.invalidPacket
            }
            if let generation, producerGeneration < generation { throw MeetingRecordingClock.Failure.retiredProducer }
            let frames = CMSampleBufferGetNumSamples(sample), rate = asbd.mSampleRate
            let nativeStart = CMSampleBufferGetPresentationTimeStamp(sample)
            let nativeEnd = nativeStart + CMTime(seconds: Double(frames) / rate, preferredTimescale: 1_000_000_000)
            let hostStart = acquisitionStart ?? sourceClock.map {
                CMSyncConvertTime(nativeStart, from: $0, to: CMClockGetHostTimeClock())
            } ?? nativeStart
            var hostEnd = sourceClock.map {
                CMSyncConvertTime(nativeEnd, from: $0, to: CMClockGetHostTimeClock())
            } ?? (hostStart + CMTime(seconds: Double(frames) / rate, preferredTimescale: 1_000_000_000))
            guard hostStart.isNumeric, hostEnd.isNumeric, hostStart >= self.context.origin, hostEnd > hostStart else {
                throw MeetingRecordingClock.Failure.unprovenClock
            }
            let formatChanged = self.format.map { !CMFormatDescriptionEqual($0, otherFormatDescription: description) } ?? false
            let changed = self.generation.map { $0 != producerGeneration } ?? true
            var continuous = self.pending != nil && !changed && !formatChanged
            if let prior = self.pending {
                if let a = prior.sourceFrameStart, let b = sourceFrameStart {
                    continuous = continuous && b == a + Int64(prior.frames)
                } else {
                    continuous = continuous && abs((nativeStart - prior.nativeEnd).seconds) <= 1.0 / rate + 1e-9
                }
                guard hostStart > prior.hostStart else { throw MeetingRecordingClock.Failure.unprovenClock }
                if continuous {
                    let measured = (hostStart - prior.hostStart).seconds
                    let nominal = Double(prior.frames) / prior.rate
                    // The host anchors are represented at nanosecond scale. Apply their two
                    // rounding units to the interval, rather than as a rate-dependent ratio.
                    guard measured.isFinite, measured >= nominal * 0.98 - 2e-9,
                          measured <= nominal * 1.02 + 2e-9 else {
                        throw MeetingRecordingClock.Failure.unprovenClock
                    }
                    if sourceClock == nil {
                        // Only the finite unpaired tail needs projection. Its rate comes from
                        // adjacent acquisition anchors, never accumulated nominal sample time.
                        hostEnd = hostStart + CMTime(seconds: measured / Double(prior.frames) * Double(frames),
                                                    preferredTimescale: 1_000_000_000)
                    }
                }
            }
            var output: [CMSampleBuffer] = []
            if let prior = self.pending {
                let end = continuous ? hostStart : min(prior.projectedHostEnd, hostStart)
                let mapping = try self.context.mapping(frameCount: prior.frames, start: prior.hostStart,
                    end: end, discontinuityBefore: prior.discontinuity)
                output.append(try self.context.timedCopy(prior.sample, mapping: mapping, producerEpoch: prior.epoch))
            }
            if changed || formatChanged { self.epoch = self.context.reserveEpoch() }
            self.generation = producerGeneration; self.format = description
            self.pending = Pending(sample: sample, nativeStart: nativeStart, nativeEnd: nativeEnd,
                hostStart: hostStart, projectedHostEnd: hostEnd, rate: rate, frames: frames,
                sourceFrameStart: sourceFrameStart, epoch: self.epoch, discontinuity: !continuous)
            return output
        }
    }

    func finish() throws -> [CMSampleBuffer] {
        try self.lock.withLock {
            guard let prior = self.pending else { return [] }
            self.pending = nil
            let mapping = try self.context.mapping(frameCount: prior.frames, start: prior.hostStart,
                end: prior.projectedHostEnd, discontinuityBefore: prior.discontinuity)
            return [try self.context.timedCopy(prior.sample, mapping: mapping, producerEpoch: prior.epoch)]
        }
    }
}

/// Echo suppression: on speakers, the far end bleeds into the microphone track. This is text-only
/// (the offline signal scorer needs data live capture can't produce), comparing a mic utterance
/// against recently finalized application-audio text.
nonisolated enum MeetingLiveEchoFilter {
    static func recentThemText(
        from themUtterances: [MeetingLiveUtterance],
        before cutoff: TimeInterval,
        windowSeconds: TimeInterval
    ) -> String {
        themUtterances
            .filter { $0.end > cutoff - windowSeconds && $0.start < cutoff }
            .sorted { $0.start < $1.start }
            .map(\.text)
            .joined(separator: " ")
    }

    static func shouldSuppress(micText: String, recentThemText: String) -> Bool {
        guard !recentThemText.isEmpty else { return false }
        return MeetingEchoDetector.isLikelyEcho(micText: micText, remoteText: recentThemText)
    }
}

/// Copies PCM data out of a `CMSampleBuffer` immediately so nothing captured on the capture queue
/// outlives this call. Never throws into the capture callback — invalid buffers are simply dropped.
nonisolated enum MeetingLiveSampleCopy {
    struct Sample: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        let pts: CMTime
        let duration: CMTime
        var clockPacket: MeetingCaptureClockMetadata.Packet? = nil
    }

    static func copy(_ sampleBuffer: CMSampleBuffer) -> Sample? {
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else { return nil }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let sourceFormat = try? MeetingPCMFormatResolver.resolve(formatDescription)
        else { return nil }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount)
        else { return nil }
        buffer.frameLength = frameCount

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else { return nil }

        let copiedBuffer: AVAudioPCMBuffer
        if sourceFormat.channelCount > 2,
           MeetingPCMFormatContract.layoutData(formatDescription) == nil
        {
            guard let mono = self.downmixLayoutlessMultichannel(buffer) else { return nil }
            copiedBuffer = mono
        } else {
            copiedBuffer = buffer
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid, pts.isNumeric else { return nil }

        var duration = CMSampleBufferGetDuration(sampleBuffer)
        let clockPacket = MeetingCaptureClockMetadata.read(from: sampleBuffer)
        if let first = clockPacket?.mapping.spans.first, let last = clockPacket?.mapping.spans.last {
            duration = CMTime(seconds: last.hostEnd.seconds - first.hostStart.seconds, preferredTimescale: 1_000_000_000)
        } else if !duration.isValid || !duration.isNumeric || duration <= .zero {
            duration = CMTime(value: CMTimeValue(frameCount), timescale: CMTimeScale(copiedBuffer.format.sampleRate.rounded()))
        }
        return Sample(buffer: copiedBuffer, pts: pts, duration: duration,
                      clockPacket: clockPacket)
    }

    private static func downmixLayoutlessMultichannel(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let channelCount = Int(source.format.channelCount)
        guard channelCount > 1,
              source.format.commonFormat == .pcmFormatFloat32,
              let monoFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: source.format.sampleRate,
                  channels: 1,
                  interleaved: false
              ),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: source.frameLength),
              let destination = mono.floatChannelData?[0]
        else { return nil }

        let frameCount = Int(source.frameLength)
        let buffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        if source.format.isInterleaved {
            guard buffers.count == 1,
                  buffers[0].mNumberChannels == source.format.channelCount,
                  let data = buffers[0].mData?.assumingMemoryBound(to: Float.self)
            else { return nil }
            for frame in 0..<frameCount {
                var sum: Double = 0
                let offset = frame * channelCount
                for channel in 0..<channelCount {
                    sum += Double(data[offset + channel])
                }
                destination[frame] = Float(sum / Double(channelCount))
            }
        } else {
            guard buffers.count == channelCount,
                  buffers.allSatisfy({ $0.mNumberChannels == 1 && $0.mData != nil })
            else { return nil }
            let channelData = buffers.compactMap { $0.mData?.assumingMemoryBound(to: Float.self) }
            guard channelData.count == channelCount else { return nil }
            for frame in 0..<frameCount {
                var sum: Double = 0
                for channel in 0..<channelCount {
                    sum += Double(channelData[channel][frame])
                }
                destination[frame] = Float(sum / Double(channelCount))
            }
        }
        mono.frameLength = source.frameLength
        return mono
    }
}


// MARK: - Pending capture presentation

/// Visual capture progress only. These estimates are neither recognized words nor speaker
/// evidence and never enter a MeetingSession, privacy payload, Copy or Export.
nonisolated struct MeetingPendingSpeechToken: Identifiable, Sendable, Equatable {
    var id: UInt64
    var source: MeetingLiveSpeaker
    var start: TimeInterval
    var end: TimeInterval
    /// Relative word-shaped width, independent of any transcript contents.
    var widthHint: Double
    var level: Float
}

/// Evidence for capture presentation only. Unknown is distinct from confirmed non-speech;
/// neither state proves that audio has been recognized or can be discarded.
nonisolated enum MeetingSpeechActivity: Sendable, Equatable {
    case speech, nonSpeech, unknown
}

nonisolated struct MeetingPendingSpeechSnapshot: Sendable, Equatable {
    var tokens: [MeetingPendingSpeechToken] = []
    var isCapturing = false
    var activityBySource: [MeetingLiveSpeaker: MeetingSpeechActivity] = [:]

    /// Both native inline attachments and standalone waves share this bounded animation set.
    /// Retained audio remains visible while recognition or privacy publication is delayed.
    var animatedTokenIDs: Set<UInt64> {
        guard isCapturing else { return [] }
        var result: Set<UInt64> = []
        for source in [MeetingLiveSpeaker.you, .them] where activityBySource[source] == .speech {
            result.formUnion(tokens.lazy.filter { $0.source == source }.suffix(3).map(\.id))
        }
        return result
    }

    /// Separate from live-transcript revisions: capture progress cannot invalidate an async
    /// privacy-filtered recognition update.
    var revision: UInt64 = 0
    static let empty = MeetingPendingSpeechSnapshot()
}

/// Scalar-only projection. Mobile capture supplies activity from its single model worker;
/// legacy capture can still use the inexpensive signal heuristic below. Positive model
/// windows mean speech somewhere in that window, not exact voiced duration or word counts.
/// Wave cadence is a bounded presentation estimate, never recognized words.
nonisolated struct MeetingPendingSpeechProjection {
    static let maximumTokens = 64
    private let maximumIntervals: Int
    static let minimumActivityRMS: Float = 0.0042
    static let quietWaitingSeconds: TimeInterval = 5
    private static let cadenceResetSeconds: TimeInterval = 0.24

    /// Bounded scalar evidence for the existing debug logger. No audio or transcript
    /// content crosses this callback, including when publication is held by privacy.
    nonisolated struct DiagnosticEvent: Sendable {
        enum Kind: String, Sendable {
            case created, replaced, trimmed, stopped, extended
            case processedCoverage = "processed_coverage"
            case quietWaiting = "quiet_waiting"
            case capacityReached = "capacity_reached"
            case reconciled, staleTranscript = "stale_transcript", capturePublished = "capture_published"
        }
        let kind: Kind
        let uptime: TimeInterval
        let source: MeetingLiveSpeaker?
        let tokens: [MeetingPendingSpeechToken]
        let remainingIDs: [UInt64]
        let pendingRevision: UInt64
        let transcriptRevision: UInt64?
        let captionID: UUID?
        let visibleUTF16: Int
        let start: TimeInterval?
        let end: TimeInterval?

        var logFields: String {
            func time(_ value: TimeInterval?) -> String {
                value.map { String(format: "%.6f", $0) } ?? "none"
            }
            func tag(_ source: MeetingLiveSpeaker?) -> String {
                switch source { case .you: "microphone"; case .them: "meeting_audio"; case nil: "all" }
            }
            let intervals = tokens.map { "\($0.id):\(tag($0.source)):\(time($0.start))-\(time($0.end))" }.joined(separator: ",")
            return "event=\(kind.rawValue) eventUptime=\(time(uptime)) source=\(tag(source)) "
                + "pendingRevision=\(pendingRevision) transcriptRevision=\(transcriptRevision.map(String.init) ?? "none") "
                + "captionID=\(captionID?.uuidString ?? "none") visibleUTF16=\(visibleUTF16) "
                + "coverageStart=\(time(start)) coverageEnd=\(time(end)) "
                + "tokens=[\(intervals)] remainingIDs=[\(remainingIDs.map(String.init).joined(separator: ","))]"
        }
    }

    /// Unresolved speech duration, rather than a solid envelope spanning source gaps.
    /// The same interval subtraction is used for cadence debt and rendered token support.
    private struct Cadence {
        var intervals: [Range<Double>] = []
        mutating func append(_ ranges: [Range<Double>]) {
            intervals = MeetingPendingSpeechProjection.merged(intervals + ranges)
        }
        mutating func consume(_ seconds: Double) -> [Range<Double>]? {
            guard intervals.reduce(0, { $0 + $1.upperBound - $1.lowerBound }) >= seconds - 0.000_001 else { return nil }
            var remaining = seconds
            var consumed: [Range<Double>] = []
            while remaining > 0.000_001, let first = intervals.first {
                let count = min(remaining, first.upperBound - first.lowerBound)
                consumed.append(first.lowerBound..<(first.lowerBound + count))
                remaining -= count
                if count >= first.upperBound - first.lowerBound - 0.000_001 { intervals.removeFirst() }
                else { intervals[0] = (first.lowerBound + count)..<first.upperBound }
            }
            return consumed
        }
    }

    private struct Track {
        var energies: [Float] = []
        var consecutiveActivity = 0
        var pending = Cadence()
        var lastEnd: Double?
        var lastActivityEnd: Double?
        var lastProgressEnd: Double?
        var reportedQuietWaiting = false
        var cadenceSeconds: Double = 0.4
        var cadenceObservedThrough: Double?
        var protectedThrough: Double = 0
        var processedIntervals: [Range<Double>] = []
    }
    private var tracks: [MeetingLiveSpeaker: Track] = [:]
    /// Public tokens retain only their display envelope. Private support records which
    /// measured speech still belongs to that token, including after the 64-view coalescing.
    private var tokenSupport: [UInt64: [Range<Double>]] = [:]
    private var nextID: UInt64 = 0
    private var visibleRevision: UInt64 = 0
    private var reportedCapacity = false
    private let onDiagnostic: (@Sendable (DiagnosticEvent) -> Void)?
    private(set) var snapshot = MeetingPendingSpeechSnapshot(isCapturing: true)

    init(maximumIntervals: Int = 8_192, diagnostics: (@Sendable (DiagnosticEvent) -> Void)? = nil) {
        precondition((1...8_192).contains(maximumIntervals))
        self.maximumIntervals = maximumIntervals
        self.onDiagnostic = diagnostics
    }

    #if DEBUG
    var retainedIntervalCounts: [Int] {
        self.tracks.values.flatMap { [$0.pending.intervals.count, $0.processedIntervals.count] }
            + self.tokenSupport.values.map(\.count)
    }
    #endif

    /// Exactly one short scalar frame from admitted PCM, using its capture PTS timeline.
    mutating func observe(source: MeetingLiveSpeaker, start: Double, end: Double,
                          rms: Float, peak: Float, zeroCrossingRate: Float) {
        guard self.snapshot.isCapturing, start.isFinite, end.isFinite, start >= 0,
              end > start, end - start <= 0.05, rms.isFinite, peak.isFinite,
              zeroCrossingRate.isFinite, rms >= 0, peak >= rms,
              (0...1).contains(zeroCrossingRate) else { return }
        var track = self.tracks[source] ?? Track()
        if let lastEnd = track.lastEnd {
            // Duplicate and late frames never mint another visual word. A capture gap resets
            // only activity hysteresis; it does not erase audio already awaiting recognition.
            guard start >= lastEnd - 0.000_001 else { return }
            if start - lastEnd > 0.06 {
                track.energies.removeAll(keepingCapacity: true)
                track.consecutiveActivity = 0
                track.pending.intervals.removeAll(keepingCapacity: true)
            }
        }
        track.lastEnd = end
        track.energies.append(rms)
        if track.energies.count > 12 { track.energies.removeFirst() }
        let mean = track.energies.reduce(Float(0), +) / Float(track.energies.count)
        let variance = track.energies.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / Float(track.energies.count)
        let modulation = mean > 0 ? sqrt(variance) / mean : 0
        // 40ms onset keeps ordinary quiet syllables; modulation rejects a constant fan/tone; high ZCR
        // rejects broadband hiss. These thresholds classify an animation candidate only.
        let candidate = rms >= Self.minimumActivityRMS && modulation >= 0.12 && zeroCrossingRate < 0.34 && peak <= max(0.02, rms * 9)
        track.consecutiveActivity = candidate ? min(2, track.consecutiveActivity + 1) : 0
        let isSpeech = track.consecutiveActivity >= 2
        if isSpeech { track.lastActivityEnd = end }
        // Short intra-syllable dips must not toggle every 20ms. A real detector's explicit
        // non-speech decision below bypasses this heuristic hangover entirely.
        let activity: MeetingSpeechActivity = isSpeech || track.lastActivityEnd.map {
            end - $0 < Self.cadenceResetSeconds - 0.000_001
        } == true ? .speech : .nonSpeech
        self.advance(source: source, start: start, end: end, activity: activity,
            contributesSpeech: isSpeech, level: min(1, max(0.08, sqrt(rms / 0.08))), track: &track)
        self.tracks[source] = track
    }

    /// Scalar seam for an admitted detector. No model or audio is retained here, and confirmed
    /// decisions do not pass through the energy/modulation heuristic. Callers choose one
    /// evidence stream per source and preserve the same capture-relative time contract.
    mutating func observeSpeechActivity(source: MeetingLiveSpeaker, start: Double, end: Double,
                                       activity: MeetingSpeechActivity, level: Float = 0.5) {
        guard self.snapshot.isCapturing, start.isFinite, end.isFinite, start >= 0,
              end > start, end - start <= 0.256_001, level.isFinite, (0...1).contains(level) else { return }
        var track = self.tracks[source] ?? Track()
        if let lastEnd = track.lastEnd {
            guard start >= lastEnd - 0.000_001 else { return }
            if start - lastEnd > 0.06 { track.pending.intervals.removeAll(keepingCapacity: true) }
        }
        track.lastEnd = end
        if activity == .speech { track.lastActivityEnd = end }
        else { track.pending.intervals.removeAll(keepingCapacity: true) }
        self.advance(source: source, start: start, end: end, activity: activity,
            contributesSpeech: activity == .speech, level: level, track: &track)
        self.tracks[source] = track
    }

    private mutating func advance(source: MeetingLiveSpeaker, start: Double, end: Double,
                                  activity: MeetingSpeechActivity, contributesSpeech: Bool,
                                  level: Float, track: inout Track) {
        if (self.snapshot.activityBySource[source] ?? .unknown) != activity {
            self.snapshot.activityBySource[source] = activity
            self.snapshot.revision &+= 1
        }
        if contributesSpeech, end > track.protectedThrough + 0.000_001 {
            let measured = max(start, track.protectedThrough)..<end
            track.pending.append(Self.subtract([measured], coveredBy: track.processedIntervals))
            guard track.pending.intervals.count <= self.maximumIntervals else {
                track.pending.intervals.removeAll(keepingCapacity: true)
                self.emit(.capacityReached, source: source, start: start, end: end)
                return
            }
            // Start at 150 shapes/minute, then gently follow newly visible native speech
            // timing. Activity decides when to mint; cadence is still only a UI estimate.
            if let speech = track.pending.consume(track.cadenceSeconds),
               let first = speech.first, let last = speech.last {
                track.lastProgressEnd = end
                track.reportedQuietWaiting = false
                if self.snapshot.tokens.count < Self.maximumTokens {
                    let widths: [Double] = [0.72, 1.02, 0.56, 0.88, 0.64, 1.10, 0.80]
                    self.nextID &+= 1
                    self.snapshot.tokens.append(MeetingPendingSpeechToken(
                        id: self.nextID, source: source, start: first.lowerBound, end: last.upperBound,
                        widthHint: widths[Int((self.nextID - 1) % UInt64(widths.count))], level: level))
                    self.tokenSupport[self.nextID] = speech
                    self.snapshot.revision &+= 1
                    self.reportedCapacity = false
                    self.emit(.created, source: source, tokens: [self.snapshot.tokens.last!])
                } else if let index = self.snapshot.tokens.lastIndex(where: { $0.source == source }) {
                    // Preserve the same bounded display token and its complete outstanding
                    // source envelope when recognition falls behind. Later speech must not
                    // disappear merely because the renderer reached its view budget.
                    let id = self.snapshot.tokens[index].id
                    let support = Self.merged((self.tokenSupport[id] ?? []) + speech)
                    guard support.count <= self.maximumIntervals else {
                        self.emit(.capacityReached, source: source, start: start, end: end)
                        return
                    }
                    self.tokenSupport[id] = support
                    self.snapshot.tokens[index].end = last.upperBound
                    self.snapshot.revision &+= 1
                    self.emit(.extended, source: source, tokens: [self.snapshot.tokens[index]])
                } else if !self.reportedCapacity {
                    self.reportedCapacity = true
                    self.emit(.capacityReached, source: source, start: start, end: end)
                }
            }
        }
        if let lastActivityEnd = track.lastActivityEnd,
           end - lastActivityEnd >= Self.cadenceResetSeconds { track.pending.intervals.removeAll(keepingCapacity: true) }
        // Older decisions cannot return after monotonic source observation. Pending
        // cadence/token support has already had every acknowledged part subtracted.
        track.processedIntervals.removeAll { $0.upperBound <= end + 0.000_001 }
        if let lastProgressEnd = track.lastProgressEnd, end - lastProgressEnd >= Self.quietWaitingSeconds,
           !track.reportedQuietWaiting {
            track.reportedQuietWaiting = true
            self.emit(.quietWaiting, source: source,
                tokens: self.snapshot.tokens.filter { $0.source == source }, start: lastProgressEnd, end: end)
        }
    }

    /// Recognition-based retirement uses only caller-approved, actually visible captions. PII-held words and
    /// unavailable/empty hypotheses cannot clear captured progress. Timed closed turns remove
    /// their own coverage. Untimed prefixes retain progress until coverage is known.
    mutating func reconcile(visible: MeetingLiveTranscriptSnapshot) {
        guard visible.revision > self.visibleRevision else {
            self.emit(.staleTranscript, transcriptRevision: visible.revision)
            return
        }
        self.visibleRevision = visible.revision
        // Full reading history must not turn each preview into a text scan and token
        // retirement pass over the whole meeting. Pending capture itself stays bounded.
        let pendingBounds = Dictionary(grouping: self.snapshot.tokens, by: \.source).mapValues { tokens in
            (start: tokens.map(\.start).min()!, end: tokens.map(\.end).max()!)
        }
        for utterance in visible.utterances {
            if self.snapshot.tokens.isEmpty { break }
            guard let bounds = pendingBounds[utterance.speaker],
                  utterance.end > bounds.start, utterance.start < bounds.end,
                  !utterance.hasIncompleteTextCoverage,
                  utterance.start.isFinite, utterance.start >= 0,
                  utterance.end.isFinite, utterance.end > utterance.start,
                  !utterance.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            self.observeCadence(source: utterance.speaker, start: utterance.start,
                end: utterance.end, text: utterance.text)
            self.applyCoverage(source: utterance.speaker, start: utterance.start, end: utterance.end,
                captionID: utterance.id, visibleUTF16: utterance.text.utf16.count)
        }
        for (source, partial) in visible.partials {
            guard partial.start.isFinite, partial.start >= 0,
                  let end = partial.end, end.isFinite, end > partial.start,
                  !partial.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !visible.finalizedTurnIDs.contains(partial.id),
                  !visible.utterances.contains(where: { $0.id == partial.id }) else { continue }
            self.applyCoverage(source: source, start: partial.start, end: end,
                captionID: partial.id, visibleUTF16: partial.text.utf16.count)
        }
        if self.onDiagnostic != nil {
            let visibleUTF16 = visible.utterances.reduce(0) { $0 + $1.text.utf16.count }
                + visible.partials.values.reduce(0) { $0 + $1.text.utf16.count }
            self.emit(.reconciled, transcriptRevision: visible.revision, visibleUTF16: visibleUTF16)
        }
    }

    /// The pipeline supplies exact normalized source progress only after its protected
    /// checkpoint is visible. Unlike word-shaped estimates this includes scored gaps
    /// and complete empty ASR windows. It never acknowledges later queued audio.
    mutating func acknowledgeProtectedSource(source: MeetingLiveSpeaker, throughSample: Int,
                                             transcriptRevision: UInt64) {
        guard snapshot.isCapturing, transcriptRevision == visibleRevision,
              throughSample >= 0, throughSample <= Int.max / 2 else { return }
        let end = Double(throughSample) / 16_000
        var track = tracks[source] ?? Track()
        guard end > track.protectedThrough else { return }
        let start = track.protectedThrough
        guard applyCoverage(source: source, start: start, end: end, captionID: nil, visibleUTF16: 0) else { return }
        track = tracks[source] ?? track
        track.protectedThrough = end
        tracks[source] = track
        emit(.processedCoverage, source: source, transcriptRevision: transcriptRevision, start: start, end: end)
    }

    mutating func acknowledgeProtectedIntervals(source: MeetingLiveSpeaker,
        intervals: [Range<Double>], transcriptRevision: UInt64) {
        guard snapshot.isCapturing, transcriptRevision == visibleRevision,
              intervals.count <= self.maximumIntervals,
              intervals.allSatisfy({ $0.lowerBound.isFinite && $0.upperBound.isFinite
                  && $0.lowerBound >= 0 && $0.upperBound > $0.lowerBound }) else { return }
        applyCoverage(source: source, intervals: Self.merged(intervals), captionID: nil, visibleUTF16: 0)
    }

    /// A caption worker completed this interval without a visible caption (empty final
    /// or admitted echo suppression). A cleared partial or silence is not completion.
    /// It cannot advance a source prefix across earlier queued or privacy-held speech.
    mutating func acknowledgeResolvedAudio(source: MeetingLiveSpeaker, start: Double, end: Double) {
        guard snapshot.isCapturing, start.isFinite, end.isFinite, start >= 0, end > start else { return }
        guard applyCoverage(source: source, start: start, end: end, captionID: nil, visibleUTF16: 0) else { return }
        emit(.processedCoverage, source: source, start: start, end: end)
    }

    private mutating func observeCadence(source: MeetingLiveSpeaker, start: Double, end: Double, text: String) {
        guard var track = self.tracks[source], end.isFinite, start.isFinite, end > start,
              track.cadenceObservedThrough.map({ end > $0 + 0.000_001 }) != false else { return }
        // Do not retain text or word counts. A speaker-only revision cannot train twice,
        // and a long pause is not a slow speaking rate. Single native words use spacing
        // between successive endpoints rather than their much shorter phonation length.
        let words = text.split(whereSeparator: { $0.isWhitespace }).filter {
            $0.contains(where: { $0.isLetter || $0.isNumber })
        }.count
        guard words > 0 else { return }
        defer { track.cadenceObservedThrough = end; self.tracks[source] = track }
        let span: Double
        if words == 1, let previous = track.cadenceObservedThrough { span = end - previous }
        else if words > 1 { span = end - start }
        else { return }
        guard span > 0, span <= max(1.5, Double(words)), end - start <= 30 else { return }
        let observed = min(1, max(0.256, span / Double(words)))
        track.cadenceSeconds = track.cadenceSeconds * 0.8 + observed * 0.2
    }

    @discardableResult
    private mutating func applyCoverage(source: MeetingLiveSpeaker, start: TimeInterval, end: TimeInterval,
                                       captionID: UUID?, visibleUTF16: Int) -> Bool {
        guard end > start else { return false }
        return applyCoverage(source: source, intervals: [start..<end], captionID: captionID, visibleUTF16: visibleUTF16)
    }

    /// Preflight the complete acknowledgement before changing any retained proof.
    /// Subtraction can fragment a bounded interval list just as append can grow it.
    /// On overflow retain the old proof, without bridging already acknowledged holes.
    @discardableResult
    private mutating func applyCoverage(source: MeetingLiveSpeaker, intervals: [Range<Double>],
                                       captionID: UUID?, visibleUTF16: Int) -> Bool {
        guard let first = intervals.first, let last = intervals.last else { return true }
        let start = first.lowerBound, end = last.upperBound
        var track = self.tracks[source] ?? Track()
        let remembered = Self.merged(track.processedIntervals + intervals)
            .filter { $0.upperBound > (track.lastEnd ?? 0) + 0.000_001 }
        let pending = Self.subtract(track.pending.intervals, coveredBy: intervals)
        guard remembered.count <= self.maximumIntervals, pending.count <= self.maximumIntervals else {
            self.emit(.capacityReached, source: source, start: start, end: end)
            return false
        }
        var supports: [UInt64: [Range<Double>]] = [:]
        var nextTokens: [MeetingPendingSpeechToken] = []
        var removed: [MeetingPendingSpeechToken] = []
        var trimmed: [MeetingPendingSpeechToken] = []
        for token in self.snapshot.tokens {
            guard token.source == source, token.end > start, token.start < end else {
                nextTokens.append(token); continue
            }
            let support = Self.subtract(self.tokenSupport[token.id] ?? [token.start..<token.end], coveredBy: intervals)
            guard support.count <= self.maximumIntervals else {
                self.emit(.capacityReached, source: source, start: start, end: end)
                return false
            }
            supports[token.id] = support
            guard let first = support.first, let last = support.last else {
                removed.append(token); continue
            }
            var retained = token
            retained.start = first.lowerBound
            retained.end = last.upperBound
            if retained != token { trimmed.append(token) }
            nextTokens.append(retained)
        }
        track.processedIntervals = remembered
        track.pending.intervals = pending
        self.tracks[source] = track
        for (id, support) in supports { self.tokenSupport[id] = support.isEmpty ? nil : support }
        self.snapshot.tokens = nextTokens
        guard !removed.isEmpty || !trimmed.isEmpty else { return true }
        self.snapshot.revision &+= 1
        self.reportedCapacity = false
        if !removed.isEmpty {
            self.emit(.replaced, source: source, tokens: removed, transcriptRevision: self.visibleRevision,
                captionID: captionID, visibleUTF16: visibleUTF16, start: start, end: end)
        }
        if !trimmed.isEmpty {
            self.emit(.trimmed, source: source, tokens: trimmed, transcriptRevision: self.visibleRevision,
                captionID: captionID, visibleUTF16: visibleUTF16, start: start, end: end)
        }
        return true
    }

    private static func merged(_ ranges: [Range<Double>]) -> [Range<Double>] {
        var result: [Range<Double>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound <= last.upperBound + 0.000_001 {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else { result.append(range) }
        }
        return result
    }

    private static func subtract(_ ranges: [Range<Double>], coveredBy coverage: [Range<Double>]) -> [Range<Double>] {
        var result: [Range<Double>] = []
        for range in ranges {
            var cursor = range.lowerBound
            for covered in coverage where covered.upperBound > cursor && covered.lowerBound < range.upperBound {
                if covered.lowerBound > cursor + 0.000_001 { result.append(cursor..<min(covered.lowerBound, range.upperBound)) }
                cursor = max(cursor, covered.upperBound)
                if cursor >= range.upperBound - 0.000_001 { break }
            }
            if cursor < range.upperBound - 0.000_001 { result.append(cursor..<range.upperBound) }
        }
        return result
    }

    private func emit(_ kind: DiagnosticEvent.Kind, source: MeetingLiveSpeaker? = nil,
                      tokens: [MeetingPendingSpeechToken] = [], transcriptRevision: UInt64? = nil,
                      captionID: UUID? = nil, visibleUTF16: Int = 0, start: TimeInterval? = nil, end: TimeInterval? = nil) {
        guard onDiagnostic != nil || MeetingTimelineTrace.enabled else { return }
        let event = DiagnosticEvent(kind: kind, uptime: ProcessInfo.processInfo.systemUptime,
            source: source, tokens: tokens, remainingIDs: self.snapshot.tokens.map(\.id),
            pendingRevision: self.snapshot.revision, transcriptRevision: transcriptRevision,
            captionID: captionID, visibleUTF16: visibleUTF16, start: start, end: end)
        onDiagnostic?(event)
        MeetingTimelineTrace.shared?.record("wave_" + kind.rawValue, fields: ["metadata": event.logFields],
            words: tokens.map { .init(text: String($0.id), start: $0.start, end: $0.end) })
    }

    mutating func stop() {
        guard self.snapshot.isCapturing else { return }
        let removed = self.snapshot.tokens
        self.tracks.removeAll()
        self.tokenSupport.removeAll()
        self.snapshot.tokens.removeAll()
        self.snapshot.isCapturing = false
        self.snapshot.activityBySource.removeAll()
        self.snapshot.revision &+= 1
        self.emit(.stopped, tokens: removed)
    }

}

/// Synchronous metadata tee. Reads the caller-owned PCM once without retaining or copying
/// unbounded audio, retains fixed-size scalar statistics, and coalesces main-runloop delivery.
/// Optional model inference has a separate bounded worker; the projection lock never guards it.
final nonisolated class MeetingPendingSpeechCapture: @unchecked Sendable {
    private struct Meter {
        var count = 0
        var squares: Double = 0
        var peak: Float = 0
        var crossings = 0
        var previous: Float = 0
        var start: Double = 0
        var lastEnd: Double?
    }
    private let lock = NSLock()
    private let originBox: MeetingLiveOriginBox
    private let onUpdate: @Sendable (MeetingPendingSpeechSnapshot) -> Void
    private var projection: MeetingPendingSpeechProjection
    /// Recurrent state and silence evidence belong to a physical source, not a participant.
    /// The source set is frozen at initialization and never grows with transcript history.
    private var activityWorkers: [MeetingLiveSpeaker: MeetingCaptureSpeechActivityWorker] = [:]
    private let onDiagnostic: (@Sendable (MeetingPendingSpeechProjection.DiagnosticEvent) -> Void)?
    private var meters: [MeetingLiveSpeaker: Meter] = [:]
    private var publicationScheduled = false
    private var lastPublishedRevision: UInt64 = 0

    init(originBox: MeetingLiveOriginBox,
         activityModel: MeetingCaptureSpeechActivityWorker.Factory? = nil,
         activitySources: Set<MeetingLiveSpeaker> = [.you],
         diagnostics: (@Sendable (MeetingPendingSpeechProjection.DiagnosticEvent) -> Void)? = nil,
         onUpdate: @escaping @Sendable (MeetingPendingSpeechSnapshot) -> Void) {
        self.originBox = originBox
        self.onUpdate = onUpdate
        self.onDiagnostic = diagnostics
        self.projection = MeetingPendingSpeechProjection(diagnostics: diagnostics)
        if let activityModel {
            for source in activitySources {
                self.activityWorkers[source] = MeetingCaptureSpeechActivityWorker(factory: activityModel, source: source) { [weak self] start, end, activity in
                    guard let self, self.activityWorkers[source]?.isUnavailable != true else { return }
                    let publish = self.lock.withLock {
                        self.projection.observeSpeechActivity(source: source, start: start, end: end, activity: activity)
                        return self.reservePublication()
                    }
                    if publish { self.schedulePublication() }
                }
            }
        }
    }

    func confidentlyNonSpeech(source: MeetingLiveSpeaker = .you, start: Double, end: Double) -> Bool {
        self.activityWorkers[source]?.confidentlyNonSpeech(start: start, end: end) ?? false
    }

    func awaitConfidentNonSpeech(source: MeetingLiveSpeaker = .you, start: Double, end: Double) async -> Bool {
        await self.activityWorkers[source]?.awaitConfidentNonSpeech(start: start, end: end) ?? false
    }

    func stopAndWait() async {
        self.stop()
        await withTaskGroup(of: Void.self) { group in
            for worker in self.activityWorkers.values { group.addTask { await worker.join() } }
        }
        MeetingTimelineTrace.shared?.record("capture_joined")
        await MeetingTimelineTrace.shared?.flush()
    }

    func offer(kind: MeetingAudioTrackKind, sampleBuffer: CMSampleBuffer) {
        let source: MeetingLiveSpeaker = kind == .microphone ? .you : .them
        let activityWorker = self.activityWorkers[source]
        if let activityWorker, !activityWorker.isUnavailable {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard pts.isNumeric else { return }
            let start = MeetingLiveTimeConversion.sessionSeconds(pts: pts, origin: self.originBox.establish(pts))
            MeetingTimelineTrace.shared?.record("capture_pcm", fields: ["source": String(describing: kind),
                "sourceStartSeconds": String(start), "sampleCount": String(CMSampleBufferGetNumSamples(sampleBuffer)),
                "vadState": "worker-present"])
            activityWorker.offer(sampleBuffer, start: start)
            return
        }
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer),
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              let _ = try? MeetingPCMFormatContract(formatDescription: description),
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.mBitsPerChannel == 32,
              asbd.mSampleRate.isFinite, (8_000...192_000).contains(asbd.mSampleRate),
              (1...8).contains(asbd.mChannelsPerFrame) else { return }
        let count = CMSampleBufferGetNumSamples(sampleBuffer)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard count > 0, count <= 65_536, pts.isNumeric else { return }
        let origin = self.originBox.establish(pts)
        let start = MeetingLiveTimeConversion.sessionSeconds(pts: pts, origin: origin)
        let clockMapping = MeetingCaptureClockMetadata.read(from: sampleBuffer)?.mapping
        func time(at frame: Int, side: MeetingAudioClockMapping.BoundarySide = .start) -> Double {
            clockMapping?.hostTime(atFrame: Double(min(frame, count)), side: side).map { $0.seconds - origin.seconds }
                ?? (start + Double(min(frame, count)) / asbd.mSampleRate)
        }
        MeetingTimelineTrace.shared?.record("capture_pcm", fields: ["source": String(describing: kind),
            "sourceStartSeconds": String(start), "sampleCount": String(count),
            "vadState": activityWorker == nil ? "not-configured" : "capture-fallback-see-vad-events"])
        var needed = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer,
            bufferListSizeNeededOut: &needed, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil) == noErr,
            needed > 0, needed <= 1024 else { return }
        let allocation = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { allocation.deallocate() }
        let list = allocation.bindMemory(to: AudioBufferList.self, capacity: 1)
        var retained: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer,
            bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: needed,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &retained) == noErr else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let channels = Int(asbd.mChannelsPerFrame)
        let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        guard buffers.count == (interleaved ? 1 : channels),
              buffers.allSatisfy({ $0.mData != nil && Int($0.mDataByteSize) >= count * MemoryLayout<Float>.stride * (interleaved ? channels : 1) }) else { return }
        let schedule = self.lock.withLock { () -> Bool in
            guard self.projection.snapshot.isCapturing else { return false }
            var meter = self.meters[source] ?? Meter()
            if clockMapping?.spans.first?.discontinuityBefore == true { meter = Meter() }
            if let lastEnd = meter.lastEnd {
                guard start >= lastEnd - 0.000_01 else { return false }
                if start - lastEnd > 0.01 { meter = Meter() }
            }
            let stride = max(1, Int(asbd.mSampleRate / 8_000))
            let bufferEnd = time(at: count, side: .end)
            for frame in Swift.stride(from: 0, to: count, by: stride) {
                var value: Float = 0
                for channel in 0..<channels {
                    let data = buffers[interleaved ? 0 : channel].mData!.assumingMemoryBound(to: Float.self)
                    value += data[interleaved ? frame * channels + channel : frame] / Float(channels)
                }
                guard value.isFinite else { self.meters[source] = Meter(); return false }
                if meter.count == 0 { meter.start = time(at: frame) }
                if meter.count > 0, (value < 0) != (meter.previous < 0) { meter.crossings += 1 }
                meter.previous = value
                meter.count += 1; meter.squares += Double(value) * Double(value)
                meter.peak = max(meter.peak, abs(value))
                let measuredEnd = min(bufferEnd, time(at: frame + stride, side: .end))
                if measuredEnd - meter.start >= 0.02 - 0.000_001 {
                    self.projection.observe(source: source, start: meter.start,
                        end: measuredEnd,
                        rms: Float(sqrt(meter.squares / Double(meter.count))), peak: meter.peak,
                        zeroCrossingRate: Float(meter.crossings) / Float(meter.count))
                    meter.count = 0; meter.squares = 0; meter.peak = 0; meter.crossings = 0
                }
            }
            meter.lastEnd = bufferEnd
            self.meters[source] = meter
            return self.reservePublication()
        }
        if schedule { self.schedulePublication() }
    }

    func reconcile(visible: MeetingLiveTranscriptSnapshot) -> MeetingPendingSpeechSnapshot {
        self.lock.withLock {
            self.projection.reconcile(visible: visible)
            return self.projection.snapshot
        }
    }

    func acknowledgeProtectedSource(source: MeetingLiveSpeaker, throughSample: Int,
                                    transcriptRevision: UInt64) -> MeetingPendingSpeechSnapshot {
        MeetingTimelineTrace.shared?.record("wave_source_ack_request", fields: ["source": String(describing: source),
            "throughSample": String(throughSample), "transcriptRevision": String(transcriptRevision)])
        return self.lock.withLock {
            self.projection.acknowledgeProtectedSource(source: source, throughSample: throughSample,
                transcriptRevision: transcriptRevision)
            return self.projection.snapshot
        }
    }

    func acknowledgeResolvedAudio(source: MeetingLiveSpeaker, start: Double, end: Double) -> MeetingPendingSpeechSnapshot {
        self.lock.withLock {
            self.projection.acknowledgeResolvedAudio(source: source, start: start, end: end)
            return self.projection.snapshot
        }
    }

    func acknowledgeProtectedIntervals(source: MeetingLiveSpeaker, intervals: [Range<Double>],
                                      transcriptRevision: UInt64) -> MeetingPendingSpeechSnapshot {
        self.lock.withLock {
            self.projection.acknowledgeProtectedIntervals(source: source, intervals: intervals,
                transcriptRevision: transcriptRevision)
            return self.projection.snapshot
        }
    }

    func stop() {
        for worker in self.activityWorkers.values { worker.stop() }
        self.lock.withLock { self.projection.stop(); self.meters.removeAll() }
    }

    private func reservePublication() -> Bool {
        guard !self.publicationScheduled, self.projection.snapshot.revision > self.lastPublishedRevision else { return false }
        self.publicationScheduled = true
        return true
    }

    private func schedulePublication() {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { [weak self] in
            guard let self else { return }
            let snapshot = self.lock.withLock {
                self.publicationScheduled = false
                let snapshot = self.projection.snapshot
                self.lastPublishedRevision = snapshot.revision
                return snapshot
            }
            self.onDiagnostic?(.init(kind: .capturePublished, uptime: ProcessInfo.processInfo.systemUptime,
                source: nil, tokens: [], remainingIDs: snapshot.tokens.map(\.id), pendingRevision: snapshot.revision,
                transcriptRevision: nil, captionID: nil, visibleUTF16: 0, start: nil, end: nil))
            self.onUpdate(snapshot)
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
}


/// The mobile tee supplies normalized 16kHz mono PCM; desktop native PCM is converted
/// through the existing capture converter on this worker. One source-owned worker
/// loads one optional model and owns its recurrent state. Admission only retains
/// bounded sample buffers; conversion, inference and model loading never run on capture.
/// Unknown coverage always fails open for ASR. No audio file or model download is created.
final nonisolated class MeetingCaptureSpeechActivityWorker: @unchecked Sendable {
    typealias Factory = @Sendable () throws -> any MeetingSpeechActivityFrameModel
    private struct Model: MeetingSpeechActivityFrameModel {
        var value: any MeetingSpeechActivityFrameModel
        mutating func probability(samples: [Float], reset: Bool) throws -> Float {
            try value.probability(samples: samples, reset: reset)
        }
    }
    private struct Input: @unchecked Sendable {
        let buffer: CMSampleBuffer
        let start: Double
        let count: Int
        let format: MeetingPCMFormatContract
        var seconds: Double { Double(count) / format.sampleRate }
        var bytes: Int { count * format.channelCount * MemoryLayout<Float>.stride }
        let epoch: UInt64
        var clockPacket: MeetingCaptureClockMetadata.Packet? = nil
        var mappedOrigin: Double? {
            clockPacket?.mapping.spans.first.map { $0.hostStart.seconds - start }
        }
        var end: Double {
            guard let origin = mappedOrigin, let last = clockPacket?.mapping.spans.last else { return start + seconds }
            return last.hostEnd.seconds - origin
        }
    }
    private struct Evidence {
        let start: Double
        let end: Double
        let activity: MeetingSpeechActivity
    }
    private struct NonSpeechAssessment {
        let result: Bool
        let reason: String
        let scoredThrough: Double
        let mayAwaitRightTail: Bool
        let generation: UInt64
    }
    private let queue = DispatchQueue(label: "meeting.speech-activity", qos: .utility)
    private let lock = NSLock()
    private var inputs: [Input] = []
    private var pendingSeconds: Double = 0
    private var pendingBytes = 0
    private var scheduled = false
    private var closed = false
    private var unavailable = false
    private var epoch: UInt64 = 0
    private var evidence: [Evidence] = []
    private var evidenceGeneration: UInt64 = 0
    private var detector: MeetingSpeechActivityDetector<Model>?
    private var samples: [Float] = []
    private var sampleStart = 0.0
    private var previousEnd: Double?
    private var previousEpoch: UInt64?
    private var previousFormat: MeetingPCMFormatContract?
    private var converter: MeetingCapturePCMConverter?
    private var sampleMapping: MeetingAudioClockMapping?
    private var mappingOrigin: Double?
    private var previousClockPacket: MeetingCaptureClockMetadata.Packet?
    private var detectorEpoch: UInt64 = 0
    private var detectorFrames: Int64 = 0
    private let session = UUID()
    private let source: MeetingLiveSpeaker
    private let publish: @Sendable (Double, Double, MeetingSpeechActivity) -> Void

    init(factory: @escaping Factory,
         source: MeetingLiveSpeaker = .you,
         clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
         publish: @escaping @Sendable (Double, Double, MeetingSpeechActivity) -> Void) {
        self.publish = publish
        self.source = source
        queue.async { [self] in
            guard !lock.withLock({ closed }) else { return }
            // A missing or invalid model leaves the whole attempt unknown. Capture and
            // recognition continue. The next explicit recording can try again.
            let began = ProcessInfo.processInfo.systemUptime
            MeetingTimelineTrace.shared?.record("vad_model_load_begin", fields: ["captureID": session.uuidString])
            do {
                detector = MeetingSpeechActivityDetector(model: Model(value: try factory()), clock: clock)
                MeetingTimelineTrace.shared?.record("vad_model_load_end", fields: ["captureID": session.uuidString,
                    "outcome": "loaded", "wallMilliseconds": String((ProcessInfo.processInfo.systemUptime - began) * 1_000)])
            } catch {
                detector = nil
                MeetingTimelineTrace.shared?.record("vad_model_load_end", fields: ["captureID": session.uuidString,
                    "outcome": "unavailable", "errorType": String(reflecting: type(of: error)),
                    "wallMilliseconds": String((ProcessInfo.processInfo.systemUptime - began) * 1_000)])
            }
            lock.withLock { unavailable = detector == nil }
        }
    }

    /// A missing/disabled optional model restores capture-only UI feedback. Its heuristic
    /// can never authorize ASR suppression or be treated as neural speech evidence.
    var isUnavailable: Bool { lock.withLock { unavailable } }

    func offer(_ buffer: CMSampleBuffer, start: Double) {
        let count = CMSampleBufferGetNumSamples(buffer)
        guard start.isFinite, start >= 0, count > 0, count <= 65_536,
              CMSampleBufferIsValid(buffer), CMSampleBufferDataIsReady(buffer),
              let description = CMSampleBufferGetFormatDescription(buffer),
              let format = try? MeetingPCMFormatContract(formatDescription: description),
              (8_000...192_000).contains(format.sampleRate), (1...8).contains(format.channelCount),
              Double(count) / format.sampleRate <= 1,
              let block = CMSampleBufferGetDataBuffer(buffer),
              CMBlockBufferGetDataLength(block) <= count * format.channelCount * MemoryLayout<Float>.stride else {
            MeetingTimelineTrace.shared?.record("vad_input_rejected", fields: ["captureID": session.uuidString,
                "reason": "native-pcm-contract", "sampleCount": String(count)])
            return
        }
        let shouldSchedule = lock.withLock { () -> Bool in
            guard !closed else { return false }
            // At most two seconds of admitted PCM and sixteen retained buffers. Overflow
            // invalidates evidence immediately; recognition never waits for this worker.
            let packet = MeetingCaptureClockMetadata.read(from: buffer)
            let input = Input(buffer: buffer, start: start, count: count, format: format, epoch: epoch, clockPacket: packet)
            if inputs.count >= 16 || pendingSeconds + input.seconds > 2 || pendingBytes + input.bytes > 2 * 1024 * 1024 {
                MeetingTimelineTrace.shared?.record("vad_queue_overflow", fields: ["captureID": session.uuidString,
                    "discardedBuffers": String(inputs.count), "discardedBytes": String(pendingBytes), "epoch": String(epoch)])
                inputs.removeAll(); pendingSeconds = 0; pendingBytes = 0; epoch &+= 1; evidence.removeAll(); evidenceGeneration &+= 1
            }
            inputs.append(Input(buffer: buffer, start: start, count: count, format: format, epoch: epoch, clockPacket: packet))
            pendingSeconds += input.seconds; pendingBytes += input.bytes
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
        if shouldSchedule { queue.async { [self] in drain() } }
    }

    func confidentlyNonSpeech(start: Double, end: Double) -> Bool {
        let query = self.nonSpeechAssessment(start: start, end: end)
        self.recordNonSpeechQuery(query, start: start, end: end)
        return query.result
    }

    /// A growing ASR window can arrive with one capture block still queued and a partial
    /// 256ms VAD frame. Allow up to two right-edge frames to catch up within the existing
    /// 350ms wait, after an entirely measured quiet prefix. Unknown, interior gaps and speech
    /// never become silence through waiting; acceptance still requires complete measured coverage.
    func awaitConfidentNonSpeech(start: Double, end: Double) async -> Bool {
        let began = ProcessInfo.processInfo.systemUptime
        var query = self.nonSpeechAssessment(start: start, end: end)
        let generation = query.generation
        var waited = false
        func finish(_ result: Bool, reason: String? = nil) -> Bool {
            self.recordNonSpeechQuery(query, start: start, end: end, result: result, reason: reason,
                waitMilliseconds: waited ? (ProcessInfo.processInfo.systemUptime - began) * 1_000 : 0)
            return result
        }
        while true {
            guard !Task.isCancelled else { return finish(false, reason: "cancelled") }
            guard query.generation == generation else { return finish(false, reason: "source-reset") }
            if waited, ProcessInfo.processInfo.systemUptime - began >= 0.35 {
                return finish(false, reason: "right-tail-timeout")
            }
            if query.result { return finish(true) }
            guard query.mayAwaitRightTail else { return finish(false) }
            guard ProcessInfo.processInfo.systemUptime - began < 0.35 else { return finish(false, reason: "right-tail-timeout") }
            waited = true
            do { try await Task.sleep(for: .milliseconds(5)) }
            catch { return finish(false, reason: "cancelled") }
            query = self.nonSpeechAssessment(start: start, end: end)
        }
    }

    private func nonSpeechAssessment(start: Double, end: Double) -> NonSpeechAssessment {
        lock.withLock {
            let scoredThrough = evidence.last?.end ?? 0
            func result(_ value: Bool = false, _ reason: String, mayAwait: Bool = false) -> NonSpeechAssessment {
                .init(result: value, reason: reason, scoredThrough: scoredThrough,
                      mayAwaitRightTail: mayAwait, generation: evidenceGeneration)
            }
            guard start.isFinite, end.isFinite, start >= 0, end > start else { return result(false, "invalid-range") }
            guard !closed, !unavailable else { return result(false, closed ? "closed" : "unavailable") }
            var cursor = start, overlaps = 0
            // Adjacent 256ms windows can differ by a floating-point rounding unit.
            // Use the same microsecond tolerance as the gap/coverage checks below.
            for item in evidence where item.end > start + 0.000_001 && item.start < end - 0.000_001 {
                guard item.start <= cursor + 0.000_001 else { return result(false, "unscored-gap") }
                guard item.activity == .nonSpeech else { return result(false, "speech-or-unknown") }
                cursor = max(cursor, item.end); overlaps += 1
            }
            if overlaps > 0, cursor >= end - 0.000_001 { return result(true, "complete-nonspeech") }
            let mayAwait = overlaps > 0 && end - cursor <= 2 * 0.256 + 0.000_001
            return result(false, "unscored-tail", mayAwait: mayAwait)
        }
    }

    private func recordNonSpeechQuery(_ query: NonSpeechAssessment, start: Double, end: Double,
                                     result: Bool? = nil, reason: String? = nil, waitMilliseconds: Double = 0) {
        MeetingTimelineTrace.shared?.record("vad_policy_query", fields: ["captureID": session.uuidString,
            "source": source == .you ? "microphone" : "applicationAudio",
            "sourceStartSeconds": String(start), "sourceEndSeconds": String(end), "result": String(result ?? query.result),
            "reason": reason ?? query.reason, "scoredThroughSeconds": String(query.scoredThrough),
            "waitMilliseconds": String(waitMilliseconds)])
    }

    func stop() {
        lock.withLock { closed = true; inputs.removeAll(); pendingSeconds = 0; pendingBytes = 0; evidence.removeAll(); evidenceGeneration &+= 1 }
    }

    /// Queue barrier joins an in-flight non-preemptible CoreML prediction and releases its
    /// model before the attempt is declared finished. Never synchronously blocks main.
    func join() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                detector = nil; converter = nil; samples.removeAll(); previousEnd = nil; previousFormat = nil
                sampleMapping = nil; mappingOrigin = nil; previousClockPacket = nil
                continuation.resume()
            }
        }
    }

    #if DEBUG
    func drainForTesting() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
    #endif

    private func drain() {
        while let input = lock.withLock({ () -> Input? in
            guard !closed, !inputs.isEmpty else { scheduled = false; return nil }
            let next = inputs.removeFirst()
            pendingSeconds = max(0, pendingSeconds - next.seconds); pendingBytes = max(0, pendingBytes - next.bytes)
            return next
        }) {
            autoreleasepool { process(input) }
        }
    }

    private func process(_ input: Input) {
        let expectedEnd = input.end
        let clockChanged = (previousClockPacket != nil) != (input.clockPacket != nil)
            || input.clockPacket.map { packet in
                previousClockPacket.map { previous in
                    previous.clockID != packet.clockID || previous.sourceID != packet.sourceID
                        || previous.producerEpoch != packet.producerEpoch
                } ?? false
            } == true || input.clockPacket?.mapping.spans.first?.discontinuityBefore == true
        let changed = previousEpoch != input.epoch || previousFormat != input.format
            || clockChanged || previousEnd.map { abs($0 - input.start) > (input.clockPacket == nil ? 1.0 / 32_000 : 1e-8) } != false
        if changed {
            detectorEpoch &+= 1
            detectorFrames = 0
            MeetingTimelineTrace.shared?.record("vad_reset", fields: ["captureID": session.uuidString,
                "epoch": String(input.epoch), "sourceStartSeconds": String(input.start)])
            samples.removeAll(keepingCapacity: true); converter = nil; sampleStart = input.start
            sampleMapping = nil; mappingOrigin = input.mappedOrigin
            lock.withLock { evidence.removeAll(); evidenceGeneration &+= 1 }
        }
        previousEpoch = input.epoch; previousEnd = expectedEnd; previousFormat = input.format
        previousClockPacket = input.clockPacket
        let copied: MeetingLiveSampleCopy.Sample?
        let normalizedStart: Double
        do {
            guard let native = MeetingLiveSampleCopy.copy(input.buffer) else { throw MeetingCapturePCMError.invalidBuffer }
            if input.format.sampleRate == 16_000, input.format.channelCount == 1 {
                copied = native
                normalizedStart = input.start
            } else {
                if converter == nil { converter = try MeetingCapturePCMConverter() }
                let mono = try MeetingCapturePCMConverter.ownedMonoCopy(of: native.buffer)
                guard let normalized = try converter?.convert(mono,
                    presentationTime: input.clockPacket == nil ? CMTime(seconds: input.start, preferredTimescale: 1_000_000_000) : native.pts,
                    clockPacket: input.clockPacket) else { return }
                copied = MeetingLiveSampleCopy.copy(normalized)
                normalizedStart = CMSampleBufferGetPresentationTimeStamp(normalized).seconds - (input.mappedOrigin ?? 0)
            }
        } catch { copied = nil; normalizedStart = input.start }
        guard let copied,
              let pcm = copied.buffer.floatChannelData?[0] else {
            samples.removeAll(keepingCapacity: true); converter = nil; previousEnd = nil
            sampleMapping = nil
            emit(start: input.start, end: expectedEnd, activity: .unknown, epoch: input.epoch)
            return
        }
        if samples.isEmpty { sampleStart = normalizedStart }
        if let packet = copied.clockPacket {
            do { sampleMapping = try sampleMapping.map { try $0.appending(packet.mapping) } ?? packet.mapping }
            catch {
                samples.removeAll(keepingCapacity: true); sampleMapping = nil; converter = nil; previousEnd = nil
                emit(start: input.start, end: expectedEnd, activity: .unknown, epoch: input.epoch)
                return
            }
        }
        samples.append(contentsOf: UnsafeBufferPointer(start: pcm, count: Int(copied.buffer.frameLength)))
        while samples.count >= 4096 {
            let frame = Array(samples.prefix(4096))
            samples.removeFirst(4096)
            let start = sampleMapping?.hostTime(atFrame: 0).map { $0.seconds - (mappingOrigin ?? 0) } ?? sampleStart
            let end = sampleMapping?.hostTime(atFrame: 4096, side: .end).map { $0.seconds - (mappingOrigin ?? 0) } ?? (start + 0.256)
            if let mapping = sampleMapping {
                sampleMapping = samples.isEmpty ? nil : try? mapping.sliced(frames: 4096..<Double(mapping.frameCount))
            }
            sampleStart = end
            let began = ProcessInfo.processInfo.systemUptime
            let result = detector?.process(samples: frame, valid: [Bool](repeating: true, count: 4096),
                start: input.clockPacket == nil ? start : Double(detectorFrames) / 16_000,
                session: session, epoch: detectorEpoch,
                route: source == .you ? "normalized-microphone-16k" : "normalized-application-audio-16k",
                cancelled: { self.lock.withLock { self.closed || self.epoch != input.epoch } })
            detectorFrames += 4096
            MeetingTimelineTrace.shared?.record("vad_frame", fields: ["captureID": session.uuidString,
                "epoch": String(input.epoch), "sourceStartSeconds": String(start), "sourceEndSeconds": String(end),
                "probability": result?.probability.map { String($0) } ?? "unavailable",
                "unknownReason": result?.unknown?.rawValue ?? (result == nil ? "no-detector" : "none"),
                "budgetExceeded": String(result?.budgetExceeded ?? false),
                "wallMilliseconds": String((ProcessInfo.processInfo.systemUptime - began) * 1_000),
                "detectorPolicyVersion": MeetingSpeechActivityDetector<Model>.version,
                "probabilityScope": "OR-aggregate-8x32ms" ])
            if result?.unknown == .disabled {
                // Only repeated actual model failures disable the attempt. Transient
                // budget cooldown frames remain unknown and keep this worker available.
                lock.withLock {
                    unavailable = true; evidence.removeAll(); evidenceGeneration &+= 1; inputs.removeAll(); pendingSeconds = 0; pendingBytes = 0
                }
                detector = nil; samples.removeAll(keepingCapacity: false)
                return
            }
            let activity: MeetingSpeechActivity
            // The graph OR-aggregates eight internal frames. A low aggregate bounds
            // every internal probability; intermediate activity remains explicitly unknown.
            if let p = result?.probability { activity = p >= 0.85 ? .speech : (p <= 0.1 ? .nonSpeech : .unknown) }
            else { activity = .unknown }
            // This is activity anywhere in a 256ms window, never an estimate of voiced
            // milliseconds or recognized words. Partial tails remain unscored/fail-open.
            emit(start: start, end: end, activity: activity, epoch: input.epoch)
        }
    }

    private func emit(start: Double, end: Double, activity: MeetingSpeechActivity, epoch: UInt64) {
        let admitted = lock.withLock { () -> Bool in
            guard !closed, self.epoch == epoch else { return false }
            evidence.append(Evidence(start: start, end: end, activity: activity))
            evidence.removeAll { $0.end < end - 90 }
            if evidence.count > 512 { evidence.removeFirst(evidence.count - 512) }
            return true
        }
        if admitted { publish(start, end, activity) }
    }
}
