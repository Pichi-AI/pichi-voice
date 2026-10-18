import AVFoundation
import CoreMedia
import Foundation

/// Owns the two live-transcription engines for one meeting recording and publishes a snapshot for
/// the UI. Entirely additive to the recording path: `offer(kind:sampleBuffer:)` is the only entry
/// point invoked from the capture tee, and it never blocks or throws into the capture callback.
///
/// Not `@MainActor` on purpose — `offer` must be callable synchronously from the SCStream callback
/// thread. `onUpdate` is responsible for hopping to the main actor if the caller needs that.
final nonisolated class MeetingLiveTranscriptionCoordinator: @unchecked Sendable {
    /// Two `StreamingEouAsrManager` instances measured at ~470MB RSS each. Below this, skip live
    /// entirely rather than risk contending with the recording or the later batch model.
    static let minimumPhysicalMemoryBytes: UInt64 = 8 * 1024 * 1024 * 1024
    static let echoWindowSeconds: TimeInterval = 20

    static func isMemorySufficient(physicalMemory: UInt64) -> Bool {
        physicalMemory >= self.minimumPhysicalMemoryBytes
    }

    private let stateLock = NSLock()
    private let diagnosticsEnabled: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.environment["FLUIDVOICE_MEETING_LIVE_DIAGNOSTICS"] == "1"
        #else
        false
        #endif
    }()

    private func diag(_ message: @autoclosure () -> String) {
        guard self.diagnosticsEnabled else { return }
        DebugLogger.shared.info(message(), source: "MeetingLive")
    }

    private var snapshot: MeetingLiveTranscriptSnapshot = .empty
    private var recentThemUtterances: [MeetingLiveUtterance] = []
    private var offerCounts: [MeetingAudioTrackKind: Int] = [:]
    /// nil (fail-safe) keeps the echo filter ON; guarded by `stateLock` on both sides.
    private var microphoneCaptureMethod: MeetingAudioTrackCaptureMethod?
    private let originBox: MeetingLiveOriginBox
    private let onUpdate: @Sendable (MeetingLiveTranscriptSnapshot) -> Void

    private var bufferedMicrophoneEngine: PichiMeetingBufferedTrackEngine?
    private var bufferedApplicationEngine: PichiMeetingBufferedTrackEngine?
    private var bufferedRecognizer: (any PichiMeetingCaptionRecognizing)?
    private var captionMemoryMonitor: PichiMeetingCaptionMemoryMonitor?
    private var isStopped = false
    private var bufferedStopTask: Task<Void, Never>?

    #if arch(arm64)
    private var microphoneEngine: MeetingLiveTrackEngine?
    private var applicationEngine: MeetingLiveTrackEngine?
    #endif

    init(originBox: MeetingLiveOriginBox = MeetingLiveOriginBox(), onUpdate: @escaping @Sendable (MeetingLiveTranscriptSnapshot) -> Void) {
        self.originBox = originBox
        self.onUpdate = onUpdate
    }

    /// Read one immutable source value for bounded privacy paging. The publisher must
    /// release this value after selecting its page, before awaiting native inference.
    func latestSnapshot() -> MeetingLiveTranscriptSnapshot {
        self.stateLock.withLock { self.snapshot }
    }

    /// Clears any in-progress microphone partial at a capture-side splice, so it can't straddle eras.
    func resetMicrophoneUtterance() {
        let buffered = self.stateLock.withLock { self.bufferedMicrophoneEngine }
        buffered?.requestReset()
        self.publish { $0.settingPartial(nil, for: .you) }
    }

    func setMicrophoneCaptureMethod(_ method: MeetingAudioTrackCaptureMethod?) {
        self.stateLock.withLock { self.microphoneCaptureMethod = method }
        self.diag(
            "[live/ECHO] setter-armed captureMethod=\(method.map(String.init(describing:)) ?? "nil")"
        )
    }

    func start(mode: MeetingCaptureMode, languageCode: String = "en", modelID: String? = nil, artifactFingerprint: String? = nil) {
        guard !self.stateLock.withLock({ self.isStopped }) else { return }
        if let modelID, let supportedLanguages = PichiMeetingProviderFactory.registeredLanguageCodes(for: modelID) {
            guard supportedLanguages.contains(languageCode) else {
                self.publish { $0.settingAvailability(.unavailable(reason: "The selected model does not support live captions in this meeting language.")) }
                return
            }
            self.startBuffered(mode: mode, languageCode: languageCode, modelID: modelID, artifactFingerprint: artifactFingerprint)
            return
        }
        if languageCode != "en" {
            #if arch(arm64)
            self.startBuffered(mode: mode, languageCode: languageCode, modelID: "parakeet-tdt")
            #else
            self.publish { $0.settingAvailability(.unavailable(reason: "Live captions for this language on Intel require a compatible local model. Your recording is preserved.")) }
            #endif
            return
        }
        #if arch(arm64)
        guard Self.isMemorySufficient(physicalMemory: ProcessInfo.processInfo.physicalMemory) else {
            self.diag(
                "Live meeting transcription skipped: below memory threshold."
            )
            self.publish { $0.settingAvailability(.unavailable(reason: "Not enough memory available for live captions.")) }
            return
        }

        self.diag(
            "[live] starting engines mode=\(mode) physicalMemory=\(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)GB"
        )
        let microphone = MeetingLiveTrackEngine(kind: .microphone)
        self.stateLock.withLock { self.microphoneEngine = microphone }
        self.launch(microphone)

        if mode == .onlineCall {
            let application = MeetingLiveTrackEngine(kind: .applicationAudio)
            self.stateLock.withLock { self.applicationEngine = application }
            self.launch(application)
        }
        self.publish { $0.settingAvailability(.unavailable(reason: "Live captions are loading…")) }
        #else
        self.publish { $0.settingAvailability(.unavailable(reason: "Live captions require Apple Silicon.")) }
        #endif
    }

    /// The capture-tee entry point. Copies PCM only for an active engine, then hands it to the
    /// track's bounded queue — never retains the `CMSampleBuffer` beyond this call.
    func offer(kind: MeetingAudioTrackKind, sampleBuffer: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isNumeric else { return }
        // Keep the shared capture clock even when this track has no caption engine.
        self.originBox.establish(pts)
        let buffered = self.stateLock.withLock {
            kind == .microphone ? self.bufferedMicrophoneEngine : self.bufferedApplicationEngine
        }
        if let buffered {
            if let sample = MeetingLiveSampleCopy.copy(sampleBuffer) { buffered.offer(sample) }
            return
        }
        #if arch(arm64)
        guard self.stateLock.withLock({ kind == .microphone ? self.microphoneEngine != nil : self.applicationEngine != nil }) else { return }
        guard let sample = MeetingLiveSampleCopy.copy(sampleBuffer) else {
            self.diag("[live/tee] sample copy FAILED kind=\(kind)")
            return
        }
        let engine: MeetingLiveTrackEngine? = self.stateLock.withLock { () -> MeetingLiveTrackEngine? in
            let count = (self.offerCounts[kind] ?? 0) + 1
            self.offerCounts[kind] = count
            if count == 1 {
                self.diag(
                    "[live/tee] first sample kind=\(kind) pts=\(String(format: "%.3f", sample.pts.seconds)) sr=\(sample.buffer.format.sampleRate) ch=\(sample.buffer.format.channelCount)"
                )
            }
            let engine = kind == .microphone ? self.microphoneEngine : self.applicationEngine
            if engine == nil, count == 1 {
                self.diag("[live/tee] no engine for kind=\(kind) — samples discarded")
            }
            return engine
        }
        engine?.offer(sample)
        #endif
    }

    /// Must complete before the batch pipeline calls `ensureAsrReady()`, so both engines' CoreML
    /// models are released before the offline model loads.
    func stop() async {
        self.stateLock.withLock { self.isStopped = true }
        await self.stopBuffered()
        #if arch(arm64)
        let (microphone, application) = self.stateLock.withLock { () -> (MeetingLiveTrackEngine?, MeetingLiveTrackEngine?) in
            defer {
                self.microphoneEngine = nil
                self.applicationEngine = nil
            }
            return (self.microphoneEngine, self.applicationEngine)
        }
        self.diag(
            "[live] stopping engines offers=\(self.stateLock.withLock { self.offerCounts.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ") })"
        )
        await microphone?.stop()
        await application?.stop()
        self.diag("[live] engines stopped, models released")
        #endif
    }

    private func startBuffered(mode: MeetingCaptureMode, languageCode: String, modelID: String, artifactFingerprint: String? = nil) {
        let admission = PichiMeetingProviderFactory.registeredLiveAdmission(for: modelID)
        let requiredMemory = admission?.minimumPhysicalMemoryBytes ?? Self.minimumPhysicalMemoryBytes
        let trackCount = mode == .onlineCall ? 2 : 1
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        self.diag("[live/buffered] admission model=\(modelID) physicalMemoryBytes=\(physicalMemory) requiredMemoryBytes=\(requiredMemory) tracks=\(trackCount)")
        guard trackCount <= (admission?.maximumTrackCount ?? 2),
              physicalMemory >= requiredMemory else {
            self.publish { $0.settingAvailability(.unavailable(reason: "Not enough memory available for live captions.")) }
            return
        }
        self.publish { $0.settingAvailability(.unavailable(reason: "Buffered captions are loading…")) }
        Task { [weak self] in
            guard let self else { return }
            do {
                let recognizer = try await MainActor.run {
                    try PichiMeetingCaptionRecognizer(modelID: modelID, languageCode: languageCode, artifactFingerprint: artifactFingerprint)
                }
                let microphone = PichiMeetingBufferedTrackEngine(kind: .microphone, recognizer: recognizer)
                let application = mode == .onlineCall
                    ? PichiMeetingBufferedTrackEngine(kind: .applicationAudio, recognizer: recognizer) : nil
                let installed = self.stateLock.withLock {
                    guard !self.isStopped else { return false }
                    self.bufferedRecognizer = recognizer
                    self.bufferedMicrophoneEngine = microphone
                    self.bufferedApplicationEngine = application
                    self.captionMemoryMonitor = PichiMeetingCaptionMemoryMonitor { [weak self] in
                        guard let self else { return }
                        self.publish { $0.settingAvailability(.degraded(reason: "Live captions paused under memory pressure. The recording continues.")) }
                        Task { await self.stopBuffered() }
                    }
                    return true
                }
                guard installed else { await recognizer.unload(); return }
                self.launchBuffered(microphone)
                if let application { self.launchBuffered(application) }
            } catch {
                guard !self.stateLock.withLock({ self.isStopped }) else { return }
                self.publish { $0.settingAvailability(.degraded(reason: "Buffered captions could not start: \(error.localizedDescription)")) }
            }
        }
    }

    private func launchBuffered(_ engine: PichiMeetingBufferedTrackEngine) {
        Task { [weak self] in
            guard let self else { return }
            await engine.configure(
                onPartial: { [weak self] kind, id, text, start, end in
                    self?.handlePartial(kind: kind, id: id, text: text, start: start, end: end)
                },
                onUtterance: { [weak self] kind, id, text, start, end in
                    self?.handleUtterance(kind: kind, id: id, text: text, start: start, end: end)
                },
                onDegraded: { [weak self] kind, reason in
                    self?.handleDegraded(kind: kind, reason: reason)
                },
                onReady: { [weak self] kind in self?.handleReady(kind: kind) }
            )
            await engine.start()
        }
    }

    private func stopBuffered() async {
        let task = self.stateLock.withLock {
            if let existing = self.bufferedStopTask { return existing }
            let microphone = self.bufferedMicrophoneEngine
            let application = self.bufferedApplicationEngine
            let recognizer = self.bufferedRecognizer
            let monitor = self.captionMemoryMonitor
            self.bufferedMicrophoneEngine = nil
            self.bufferedApplicationEngine = nil
            self.bufferedRecognizer = nil
            self.captionMemoryMonitor = nil
            let task = Task {
                monitor?.stop()
                async let microphoneStop: Void? = microphone?.stop()
                async let applicationStop: Void? = application?.stop()
                _ = await (microphoneStop, applicationStop)
                await recognizer?.unload()
            }
            self.bufferedStopTask = task
            return task
        }
        await task.value
    }

    #if arch(arm64)
    private func launch(_ engine: MeetingLiveTrackEngine) {
        Task { [weak self] in
            guard let self else { return }
            await engine.configure(
                onPartial: { [weak self] kind, id, text, start, end in
                    self?.handlePartial(kind: kind, id: id, text: text, start: start, end: end)
                },
                onUtterance: { [weak self] kind, id, text, start, end in
                    self?.handleUtterance(kind: kind, id: id, text: text, start: start, end: end)
                },
                onDegraded: { [weak self] kind, reason in
                    self?.handleDegraded(kind: kind, reason: reason)
                },
                onReady: { [weak self] kind in
                    self?.handleReady(kind: kind)
                }
            )
            await engine.start()
        }
    }
    #endif

    private func handlePartial(kind: MeetingAudioTrackKind, id: UUID, text: String, start: CMTime, end: CMTime) {
        guard let origin = self.originBox.current else { return }
        let startSeconds = MeetingLiveTimeConversion.sessionSeconds(pts: start, origin: origin)
        let speaker = Self.speaker(for: kind)
        let partial = MeetingLivePartial(id: id, text: text, start: startSeconds,
            end: end.isNumeric ? MeetingLiveTimeConversion.sessionSeconds(pts: end, origin: origin) : nil)
        self.publish { $0.settingPartial(partial, for: speaker) }
    }

    /// Not `private`: Phase 4 tests drive it directly, predating the solidify UUID — hence the default.
    func handleUtterance(kind: MeetingAudioTrackKind, id: UUID = UUID(), text: String, start: CMTime, end: CMTime) {
        guard let origin = self.originBox.current else { return }
        let startSeconds = MeetingLiveTimeConversion.sessionSeconds(pts: start, origin: origin)
        let endSeconds = MeetingLiveTimeConversion.sessionSeconds(pts: end, origin: origin)
        let speaker = Self.speaker(for: kind)

        let updated: MeetingLiveTranscriptSnapshot = self.stateLock.withLock {
            self.snapshot.revision &+= 1
            if speaker == .you {
                if self.microphoneCaptureMethod != .voiceProcessing {
                    let recentThem = MeetingLiveEchoFilter.recentThemText(
                        from: self.recentThemUtterances,
                        before: startSeconds,
                        windowSeconds: Self.echoWindowSeconds
                    )
                    if MeetingLiveEchoFilter.shouldSuppress(micText: text, recentThemText: recentThem) {
                        self.snapshot = self.snapshot.settingPartial(nil, for: .you).markingFinalized(id)
                        return self.snapshot
                    }
                }
            } else {
                let record = MeetingLiveUtterance(id: id, speaker: .them, text: text, start: startSeconds, end: endSeconds)
                self.recentThemUtterances.append(record)
                self.recentThemUtterances.removeAll { $0.end < startSeconds - Self.echoWindowSeconds }
            }
            let utterance = MeetingLiveUtterance(id: id, speaker: speaker, text: text, start: startSeconds, end: endSeconds)
            self.snapshot = self.snapshot.inserting(utterance).settingPartial(nil, for: speaker)
            return self.snapshot
        }
        self.onUpdate(updated)
    }

    private func handleDegraded(kind: MeetingAudioTrackKind, reason: String) {
        DebugLogger.shared.warning("Live captions degraded: \(reason)", source: "MeetingLive")
        self.publish { $0.settingAvailability(.degraded(reason: reason)) }
    }

    private func handleReady(kind: MeetingAudioTrackKind) {
        self.publish { snapshot in
            guard case .unavailable = snapshot.availability else { return snapshot }
            return snapshot.settingAvailability(.available)
        }
    }

    private static func speaker(for kind: MeetingAudioTrackKind) -> MeetingLiveSpeaker {
        kind == .microphone ? .you : .them
    }

    private func publish(_ transform: (MeetingLiveTranscriptSnapshot) -> MeetingLiveTranscriptSnapshot) {
        let updated: MeetingLiveTranscriptSnapshot = self.stateLock.withLock {
            self.snapshot = transform(self.snapshot)
            self.snapshot.revision &+= 1
            return self.snapshot
        }
        self.onUpdate(updated)
    }
}
