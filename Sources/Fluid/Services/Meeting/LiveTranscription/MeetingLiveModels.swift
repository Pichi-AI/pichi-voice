import AVFoundation
import CoreMedia
import Foundation

/// Internal live-only source tags: `.you` is the microphone track and `.them` is application audio.
/// The UI deliberately presents neutral source labels because live capture has no speaker identity;
/// the offline pipeline resolves speakers and replaces this transcript on completion.
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
        if let partial, !partial.text.isEmpty {
            guard !copy.finalizedTurnIDs.contains(partial.id) else { return copy }
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
        if self.utterances != earlier.utterances, !self.utterances.isEmpty { return true }
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
    nonisolated struct Row: Identifiable, Equatable {
        var id: UUID
        var speaker: MeetingLiveSpeaker
        var text: String
        var isPartial: Bool
        var showsLabel: Bool
    }

    static func rows(for snapshot: MeetingLiveTranscriptSnapshot) -> [Row] {
        var rows = snapshot.utterances.map {
            Row(id: $0.id, speaker: $0.speaker, text: $0.text, isPartial: false, showsLabel: false)
        }
        let activePartials = [MeetingLiveSpeaker.you, .them]
            .compactMap { speaker in snapshot.partials[speaker].map { (speaker, $0) } }
            .sorted { $0.1.start < $1.1.start }
        for (speaker, partial) in activePartials {
            rows.append(Row(id: partial.id, speaker: speaker, text: partial.text, isPartial: true, showsLabel: false))
        }

        var previousSpeaker: MeetingLiveSpeaker?
        for index in rows.indices {
            rows[index].showsLabel = rows[index].speaker != previousSpeaker
            previousSpeaker = rows[index].speaker
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

    @discardableResult
    func establish(_ pts: CMTime) -> CMTime {
        self.lock.lock()
        defer { self.lock.unlock() }
        if let existing = self.origin {
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
        if !duration.isValid || !duration.isNumeric || duration <= .zero {
            duration = CMTime(value: CMTimeValue(frameCount), timescale: CMTimeScale(copiedBuffer.format.sampleRate.rounded()))
        }
        return Sample(buffer: copiedBuffer, pts: pts, duration: duration)
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

nonisolated struct MeetingPendingSpeechSnapshot: Sendable, Equatable {
    var tokens: [MeetingPendingSpeechToken] = []
    var isCapturing = false
    /// Separate from live-transcript revisions: capture progress cannot invalidate an async
    /// privacy-filtered recognition update.
    var revision: UInt64 = 0
    static let empty = MeetingPendingSpeechSnapshot()
}

/// A small signal heuristic for capture animation, not a calibrated VAD. The existing Silero
/// detector is an offline model with its own residency; this path must not load a second model.
/// Silence, steady background and impulses do not create progress. Modulated non-speech can
/// still resemble speech, so the UI must describe audio capture, never recognized words.
nonisolated struct MeetingPendingSpeechProjection {
    static let maximumTokens = 64
    static let minimumActivityRMS: Float = 0.006
    static let quietExpirySeconds: TimeInterval = 5
    private static let cadenceResetSeconds: TimeInterval = 0.24
    private struct Track {
        var energies: [Float] = []
        var consecutiveActivity = 0
        var pendingDuration: Double = 0
        var lastEnd: Double?
        var lastActivityEnd: Double?
    }
    private var tracks: [MeetingLiveSpeaker: Track] = [:]
    private var nextID: UInt64 = 0
    private var visibleRevision: UInt64 = 0
    private(set) var snapshot = MeetingPendingSpeechSnapshot(isCapturing: true)

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
                track.pendingDuration = 0
            }
        }
        track.lastEnd = end
        track.energies.append(rms)
        if track.energies.count > 12 { track.energies.removeFirst() }
        let mean = track.energies.reduce(Float(0), +) / Float(track.energies.count)
        let variance = track.energies.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / Float(track.energies.count)
        let modulation = mean > 0 ? sqrt(variance) / mean : 0
        // 120ms onset rejects isolated taps; modulation rejects a constant fan/tone; high ZCR
        // rejects broadband hiss. These thresholds classify an animation candidate only.
        let candidate = rms >= Self.minimumActivityRMS && modulation >= 0.12 && zeroCrossingRate < 0.34 && peak <= max(0.02, rms * 9)
        track.consecutiveActivity = candidate ? min(6, track.consecutiveActivity + 1) : 0
        if track.consecutiveActivity >= 6 {
            track.lastActivityEnd = end
            track.pendingDuration += end - start
            // Baseline presentation cadence: 150 words/minute, not a claim about actual words.
            if track.pendingDuration >= 0.4 - 0.000_001 {
                track.pendingDuration -= 0.4
                if self.snapshot.tokens.count < Self.maximumTokens {
                    let widths: [Double] = [0.72, 1.02, 0.56, 0.88, 0.64, 1.10, 0.80]
                    self.nextID &+= 1
                    self.snapshot.tokens.append(MeetingPendingSpeechToken(
                        id: self.nextID, source: source, start: max(0, end - 0.4), end: end,
                        widthHint: widths[Int((self.nextID - 1) % UInt64(widths.count))],
                        level: min(1, max(0.08, sqrt(rms / 0.08)))))
                    self.snapshot.revision &+= 1
                }
            }
        }
        if let lastActivityEnd = track.lastActivityEnd {
            // Unminted cadence must not accumulate across separate background bumps.
            if end - lastActivityEnd >= Self.cadenceResetSeconds { track.pendingDuration = 0 }
            if end - lastActivityEnd >= Self.quietExpirySeconds {
                let before = self.snapshot.tokens.count
                self.snapshot.tokens.removeAll { $0.source == source && $0.end <= lastActivityEnd }
                if self.snapshot.tokens.count != before { self.snapshot.revision &+= 1 }
            }
        }
        self.tracks[source] = track
    }

    /// Only caller-approved, actually visible captions retire blocks. PII-held words and
    /// unavailable/empty hypotheses cannot clear captured progress. Timed closed turns remove
    /// their own coverage. Untimed prefixes retain progress until coverage is known.
    mutating func reconcile(visible: MeetingLiveTranscriptSnapshot) {
        guard visible.revision > self.visibleRevision else { return }
        self.visibleRevision = visible.revision
        let before = self.snapshot.tokens
        for utterance in visible.utterances where !utterance.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard utterance.start.isFinite, utterance.end.isFinite, utterance.end > utterance.start else { continue }
            self.snapshot.tokens.removeAll {
                $0.source == utterance.speaker && $0.end <= utterance.end + 0.000_001 && $0.end > utterance.start
            }
        }
        for (source, partial) in visible.partials {
            guard partial.start.isFinite, partial.start >= 0,
                  let end = partial.end, end.isFinite, end > partial.start,
                  !partial.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !visible.finalizedTurnIDs.contains(partial.id),
                  !visible.utterances.contains(where: { $0.id == partial.id }) else { continue }
            self.snapshot.tokens.removeAll {
                $0.source == source && $0.end > partial.start && $0.end <= end + 0.000_001
            }
        }
        if self.snapshot.tokens != before { self.snapshot.revision &+= 1 }
    }

    mutating func stop() {
        self.tracks.removeAll()
        self.snapshot.tokens.removeAll()
        self.snapshot.isCapturing = false
        self.snapshot.revision &+= 1
    }

}

/// Synchronous metadata tee. Reads the caller-owned PCM once without retaining or copying
/// an audio buffer, retains fixed-size scalar statistics, and coalesces main-runloop delivery.
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
    private var projection = MeetingPendingSpeechProjection()
    private var meters: [MeetingLiveSpeaker: Meter] = [:]
    private var publicationScheduled = false
    private var lastPublishedRevision: UInt64 = 0

    init(originBox: MeetingLiveOriginBox, onUpdate: @escaping @Sendable (MeetingPendingSpeechSnapshot) -> Void) {
        self.originBox = originBox
        self.onUpdate = onUpdate
    }

    func offer(kind: MeetingAudioTrackKind, sampleBuffer: CMSampleBuffer) {
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
        let source: MeetingLiveSpeaker = kind == .microphone ? .you : .them
        let schedule = self.lock.withLock { () -> Bool in
            guard self.projection.snapshot.isCapturing else { return false }
            var meter = self.meters[source] ?? Meter()
            if let lastEnd = meter.lastEnd {
                guard start >= lastEnd - 0.000_01 else { return false }
                if start - lastEnd > 0.01 { meter = Meter() }
            }
            let stride = max(1, Int(asbd.mSampleRate / 8_000))
            let bufferEnd = start + Double(count) / asbd.mSampleRate
            for frame in Swift.stride(from: 0, to: count, by: stride) {
                var value: Float = 0
                for channel in 0..<channels {
                    let data = buffers[interleaved ? 0 : channel].mData!.assumingMemoryBound(to: Float.self)
                    value += data[interleaved ? frame * channels + channel : frame] / Float(channels)
                }
                guard value.isFinite else { self.meters[source] = Meter(); return false }
                if meter.count == 0 { meter.start = start + Double(frame) / asbd.mSampleRate }
                if meter.count > 0, (value < 0) != (meter.previous < 0) { meter.crossings += 1 }
                meter.previous = value
                meter.count += 1; meter.squares += Double(value) * Double(value)
                meter.peak = max(meter.peak, abs(value))
                let measuredEnd = min(bufferEnd, start + Double(frame + stride) / asbd.mSampleRate)
                if measuredEnd - meter.start >= 0.02 - 0.000_001 {
                    self.projection.observe(source: source, start: meter.start,
                        end: measuredEnd,
                        rms: Float(sqrt(meter.squares / Double(meter.count))), peak: meter.peak,
                        zeroCrossingRate: Float(meter.crossings) / Float(meter.count))
                    meter.count = 0; meter.squares = 0; meter.peak = 0; meter.crossings = 0
                }
            }
            meter.lastEnd = start + Double(count) / asbd.mSampleRate
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

    func stop() {
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
            self.onUpdate(snapshot)
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
}
