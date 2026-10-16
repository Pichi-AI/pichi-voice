#if os(iOS)
@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// iPad/iPhone adapter for the existing meeting lifecycle. Only the microphone is captured;
/// another application's presentation audio is never represented as a system-audio track.
actor IOSMeetingCaptureEngine: MeetingCaptureControlling {
    typealias MemoryConsumerFactory = @MainActor @Sendable (
        MeetingSession, MeetingCaptureConfiguration, MeetingAudioTrack, @escaping @Sendable (MeetingCaptureEvent) -> Void
    ) async throws -> any MeetingMemoryAudioConsuming

    private struct Capture: Sendable {
        let sessionID: MeetingSessionID
        let runtime: IOSMeetingMicrophoneRuntime
        let writer: MeetingAudioChunkWriter?
        let memoryConsumer: (any MeetingMemoryAudioConsuming)?
        var track: MeetingAudioTrack
    }

    private let memoryConsumerFactory: MemoryConsumerFactory?
    private var active: Capture?
    private var starting = false
    private var terminating = false
    private var stopTask: Task<MeetingCaptureStopResult, Error>?
    private var startTask: Task<MeetingCaptureStartResult, Error>?

    init(memoryConsumerFactory: MemoryConsumerFactory? = nil) {
        self.memoryConsumerFactory = memoryConsumerFactory
    }

    func preflightPermissions() async throws {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return
        case .denied: throw MeetingCaptureError.microphonePermissionDenied
        case .undetermined:
            let granted = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
            }
            guard granted else { throw MeetingCaptureError.microphonePermissionDenied }
        @unknown default: throw MeetingCaptureError.microphonePermissionDenied
        }
    }

    func start(
        session: MeetingSession,
        configuration: MeetingCaptureConfiguration,
        sessionDirectory: URL,
        eventHandler: @escaping @Sendable (MeetingCaptureEvent) -> Void,
        liveAudioHandler: (@Sendable (MeetingAudioTrackKind, CMSampleBuffer) -> Void)? = nil
    ) async throws -> MeetingCaptureStartResult {
        guard !self.terminating else { throw CancellationError() }
        guard self.startTask == nil else { throw MeetingCaptureError.captureAlreadyActive }
        let operation = Task {
            try await self.performStart(session: session, configuration: configuration,
                sessionDirectory: sessionDirectory, eventHandler: eventHandler, liveAudioHandler: liveAudioHandler)
        }
        self.startTask = operation
        defer { self.startTask = nil }
        return try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
    }

    private func performStart(
        session: MeetingSession,
        configuration: MeetingCaptureConfiguration,
        sessionDirectory: URL,
        eventHandler: @escaping @Sendable (MeetingCaptureEvent) -> Void,
        liveAudioHandler: (@Sendable (MeetingAudioTrackKind, CMSampleBuffer) -> Void)?
    ) async throws -> MeetingCaptureStartResult {
        try Task.checkCancellation()
        try configuration.validate()
        guard !self.terminating else { throw MeetingCaptureError.captureStartFailed(PichiLocalization.text("The app is shutting down.")) }
        guard self.active == nil, !self.starting, self.stopTask == nil else { throw MeetingCaptureError.captureAlreadyActive }
        guard configuration.mode == .inRoom, configuration.application == nil else {
            throw MeetingCaptureError.captureStartFailed(PichiLocalization.text("Only in-room microphone capture is available on this platform."))
        }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw MeetingCaptureError.microphonePermissionDenied
        }
        self.starting = true
        defer { self.starting = false }
        let track = MeetingAudioTrack(id: UUID(), kind: .microphone,
                                      sourceIdentifier: configuration.microphone.captureDeviceID,
                                      sourceDisplayName: configuration.microphone.displayName,
                                      format: MeetingAudioFormat(codec: "lpcm-f32", sampleRate: 16_000, channelCount: 1, bitRate: nil),
                                      timebase: session.timebase, health: .waiting, chunks: [],
                                      captureMethod: .audioEngine)
        let writer: MeetingAudioChunkWriter?
        let memoryConsumer: (any MeetingMemoryAudioConsuming)?
        switch configuration.audioStorageMode ?? .retainedFiles {
        case .retainedFiles:
            // This branch is the only place that constructs any audio-file owner.
            try Self.protectSessionDirectory(sessionDirectory)
            let values = try sessionDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            guard let available = values.volumeAvailableCapacityForImportantUsage,
                  available >= MeetingPCMStoragePolicy.requiredFreeBytes(trackCount: 1)
            else { throw MeetingCaptureError.insufficientDiskSpace }
            writer = try MeetingAudioChunkWriter(track: track, sessionDirectory: sessionDirectory,
                                                chunkDuration: configuration.chunkDuration, eventHandler: eventHandler)
            memoryConsumer = nil
        case .memoryOnly:
            guard let memoryConsumerFactory else {
                throw MeetingCaptureError.captureStartFailed(PichiLocalization.text("In-memory transcription is not available for this attempt."))
            }
            writer = nil
            memoryConsumer = try await memoryConsumerFactory(session, configuration, track, eventHandler)
        }
        let runtime = try IOSMeetingMicrophoneRuntime(trackID: track.id, microphone: configuration.microphone,
                                                     writer: writer, memoryConsumer: memoryConsumer,
                                                     eventHandler: eventHandler, liveAudioHandler: liveAudioHandler)
        do {
            try Task.checkCancellation()
            guard !self.terminating else { throw CancellationError() }
            try await runtime.start()
            try Task.checkCancellation()
            guard !self.terminating else { throw CancellationError() }
        } catch {
            try? await runtime.stop()
            _ = await writer?.stop()
            try? await memoryConsumer?.finish()
            throw error
        }
        self.active = Capture(sessionID: session.id, runtime: runtime, writer: writer,
                              memoryConsumer: memoryConsumer, track: track)
        return MeetingCaptureStartResult(tracks: [track], firstPresentationTime: nil)
    }

    func stop(sessionID: MeetingSessionID) async throws -> MeetingCaptureStopResult {
        guard let active = self.active else { throw MeetingCaptureError.noActiveCapture }
        guard active.sessionID == sessionID else { throw MeetingCaptureError.wrongActiveSession }
        if let stopTask { return try await stopTask.value }
        let task = Task<MeetingCaptureStopResult, Error> {
            var failure: Error?
            do { try await active.runtime.stop() } catch { failure = error }
            var track: MeetingAudioTrack
            if let writer = active.writer { track = await writer.stop() } else {
                track = active.track
                track.health = active.runtime.healthSnapshot()
                track.health.status = .stopped
            }
            do { try await active.memoryConsumer?.finish() } catch { failure = failure ?? error }
            let result = MeetingCaptureStopResult(tracks: [track], stoppedAt: Date())
            if let failure { throw MeetingCaptureError.captureStopFailed(failure.localizedDescription, partialResult: result) }
            return result
        }
        self.stopTask = task
        do {
            let result = try await task.value
            self.active = nil
            self.stopTask = nil
            return result
        } catch {
            self.active = nil
            self.stopTask = nil
            throw error
        }
    }

    func shutdownForTermination() async {
        self.terminating = true
        let starting = self.startTask
        starting?.cancel()
        _ = await starting?.result
        if let active { _ = try? await self.stop(sessionID: active.sessionID) }
    }

    /// Input discovery uses the same identity value as macOS. The selected UID is frozen in
    /// configuration; capture refuses silent substitution if a wired/Bluetooth input disappears.
    @MainActor static func microphoneSnapshot() async -> MeetingMicrophoneCatalogSnapshot {
        let session = AVAudioSession.sharedInstance()
#if DEBUG
        let traceID = UUID().uuidString
        IOSMeetingCaptureTrace.emit("catalog.begin", owner: traceID)
#endif
        let savedCategory = session.category
        let savedMode = session.mode
        let savedOptions = session.categoryOptions
        var temporarilyConfigured = false
        if (session.availableInputs ?? []).isEmpty, session.category != .playAndRecord, session.category != .record {
            // Input enumeration depends on the category. Do not activate the session or open the
            // microphone merely to display Settings; start() owns actual activation after consent.
            do {
#if DEBUG
                IOSMeetingCaptureTrace.emit("catalog.configure.before", owner: traceID)
#endif
                try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetoothHFP])
                temporarilyConfigured = true
#if DEBUG
                IOSMeetingCaptureTrace.emit("catalog.configure.after", owner: traceID)
#endif
            } catch { return MeetingMicrophoneCatalogSnapshot(identities: [], defaultCoreAudioUID: nil) }
        }
        defer {
            if temporarilyConfigured {
#if DEBUG
                IOSMeetingCaptureTrace.emit("catalog.restore.before", owner: traceID)
#endif
                try? session.setCategory(savedCategory, mode: savedMode, options: savedOptions)
#if DEBUG
                IOSMeetingCaptureTrace.emit("catalog.restore.after", owner: traceID)
#endif
            }
        }
        let inputs = session.availableInputs ?? session.currentRoute.inputs
        return MeetingMicrophoneCatalogSnapshot(identities: inputs.map {
            MeetingMicrophoneIdentity(captureDeviceID: $0.uid, coreAudioUID: $0.uid,
                                      displayName: $0.portName)
        }, defaultCoreAudioUID: session.preferredInput?.uid ?? session.currentRoute.inputs.first?.uid)
    }

    @MainActor static func defaultMicrophone(preferredUID: String? = nil) async throws -> MeetingMicrophoneIdentity {
        let snapshot = await self.microphoneSnapshot()
        return try self.resolveDefaultMicrophone(in: snapshot, preferredUID: preferredUID)
    }

    /// A saved explicit input must not silently become the tablet microphone after disconnection.
    @MainActor static func resolveDefaultMicrophone(in snapshot: MeetingMicrophoneCatalogSnapshot,
                                                  preferredUID: String?) throws -> MeetingMicrophoneIdentity {
        if let preferredUID {
            guard let identity = snapshot.identities.first(where: { $0.captureDeviceID == preferredUID }) else {
                throw MeetingCaptureError.microphoneUnavailable
            }
            return identity
        }
        if let uid = snapshot.defaultCoreAudioUID,
           let identity = snapshot.identities.first(where: { $0.captureDeviceID == uid }) { return identity }
        guard let identity = snapshot.identities.first else { throw MeetingCaptureError.microphoneUnavailable }
        return identity
    }

    /// HFP couples headset input and output and has priority over A2DP. Enabling it for a
    /// different frozen input lets iOS replace that input while the engine starts. Select only
    /// the required input capability; A2DP remains available for presentation playback.
    nonisolated static func captureCategoryOptions(for selectedInputPort: AVAudioSession.Port) -> AVAudioSession.CategoryOptions {
        var options: AVAudioSession.CategoryOptions = [.mixWithOthers, .allowAirPlay, .defaultToSpeaker]
        options.insert(selectedInputPort == .bluetoothHFP ? .allowBluetoothHFP : .allowBluetoothA2DP)
        return options
    }

    private static func protectSessionDirectory(_ directory: URL) throws {
        // `.complete` would make new chunks unavailable while the screen is locked. This policy
        // permits an ongoing recording after first unlock and still enables OS data protection.
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                             ofItemAtPath: directory.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try mutableDirectory.setResourceValues(values)
    }
}

/// Shared microphone runtime, also used for explicit RAM-only voice enrollment.
final nonisolated class IOSMeetingMicrophoneRuntime: @unchecked Sendable {
    private struct OwnedInput: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        let pts: CMTime
        let reservation: MeetingPCMIntakeGate.Reservation
    }

    private let engine = AVAudioEngine()
    private let controlQueue = DispatchQueue(label: "com.fluidvoice.meeting.ios.control", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private let pcmQueue = DispatchQueue(label: "com.fluidvoice.meeting.ios.pcm", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private let gate = MeetingPCMIntakeGate()
    private let producerGroup = DispatchGroup()
    private let lock = NSLock()
    private let converter: MeetingCapturePCMConverter
    private let trackID: MeetingAudioTrackID
    private let microphone: MeetingMicrophoneIdentity
    private let writer: MeetingAudioChunkWriter?
    private let memoryConsumer: (any MeetingMemoryAudioConsuming)?
    private let eventHandler: @Sendable (MeetingCaptureEvent) -> Void
    private let liveAudioHandler: (@Sendable (MeetingAudioTrackKind, CMSampleBuffer) -> Void)?
    // Pauses only when explicitly supplied by a deterministic producer/drain test.
    private let afterAdmission: (@Sendable () -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var stopping = false
    private var terminalFailure: Error?
    private var health = MeetingTrackHealth.waiting
    private var lastHealthTime = Date.distantPast
    private var savedCategory: AVAudioSession.Category?
    private var savedMode: AVAudioSession.Mode?
    private var savedOptions: AVAudioSession.CategoryOptions?
    private var savedPreferredInput: AVAudioSessionPortDescription?
    private var savedPreferredSampleRate: Double?
    private var savedPreferredIOBufferDuration: TimeInterval?
    private var configuredSession = false
    private var installedTap = false
#if DEBUG
    // Record only the format already read by start; tracing must not create engine nodes.
    private var traceInputFormat: (sampleRate: Double, channels: UInt32)?
#endif

    init(trackID: MeetingAudioTrackID, microphone: MeetingMicrophoneIdentity,
         writer: MeetingAudioChunkWriter?, memoryConsumer: (any MeetingMemoryAudioConsuming)?,
         eventHandler: @escaping @Sendable (MeetingCaptureEvent) -> Void,
         liveAudioHandler: (@Sendable (MeetingAudioTrackKind, CMSampleBuffer) -> Void)?,
         afterAdmission: (@Sendable () -> Void)? = nil) throws {
        self.trackID = trackID
        self.microphone = microphone
        self.writer = writer
        self.memoryConsumer = memoryConsumer
        self.eventHandler = eventHandler
        self.liveAudioHandler = liveAudioHandler
        self.afterAdmission = afterAdmission
        self.converter = try MeetingCapturePCMConverter()
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.controlQueue.async { [self] in
                do {
                    let audioSession = AVAudioSession.sharedInstance()
#if DEBUG
                    self.trace("runtime.begin")
#endif
                    self.savedCategory = audioSession.category
                    self.savedMode = audioSession.mode
                    self.savedOptions = audioSession.categoryOptions
                    self.savedPreferredInput = audioSession.preferredInput
                    self.savedPreferredSampleRate = audioSession.preferredSampleRate
                    self.savedPreferredIOBufferDuration = audioSession.preferredIOBufferDuration
                    // Default mode avoids voice-chat processing that would alter in-room speech.
                    // Mixing keeps other apps' presentation playback eligible; actual routing and
                    // interruption behavior must still be verified on each physical device.
#if DEBUG
                    self.trace("runtime.category.before")
#endif
                    var selectedInput = audioSession.availableInputs?.first(where: { $0.uid == self.microphone.captureDeviceID })
                    if selectedInput == nil {
                        // A saved HFP input can be hidden by a playback-only category. Enumerate
                        // without activation, then require the exact requested UID before routing.
                        try audioSession.setCategory(.playAndRecord, mode: .default,
                                                     options: [.mixWithOthers, .allowBluetoothHFP])
                        self.configuredSession = true
                        selectedInput = audioSession.availableInputs?.first(where: { $0.uid == self.microphone.captureDeviceID })
                    }
                    guard let selectedInput else { throw MeetingCaptureError.microphoneUnavailable }
                    try audioSession.setCategory(.playAndRecord, mode: .default,
                                                 options: IOSMeetingCaptureEngine.captureCategoryOptions(for: selectedInput.portType))
                    self.configuredSession = true
#if DEBUG
                    self.trace("runtime.category.after")
#endif
                    try audioSession.setPreferredSampleRate(48_000)
                    try audioSession.setPreferredIOBufferDuration(0.02)
#if DEBUG
                    self.trace("runtime.activate.before")
#endif
                    try audioSession.setActive(true)
#if DEBUG
                    self.trace("runtime.activate.after")
#endif
                    guard let input = audioSession.availableInputs?.first(where: { $0.uid == self.microphone.captureDeviceID }) else {
                        throw MeetingCaptureError.microphoneUnavailable
                    }
#if DEBUG
                    self.trace("runtime.preferred.before")
#endif
                    try audioSession.setPreferredInput(input)
#if DEBUG
                    self.trace("runtime.preferred.after")
#endif
                    guard audioSession.currentRoute.inputs.contains(where: { $0.uid == input.uid }) else {
                        throw MeetingCaptureError.microphoneUnavailable
                    }
                    let inputNode = self.engine.inputNode
                    let format = inputNode.outputFormat(forBus: 0)
#if DEBUG
                    self.lock.withLock { self.traceInputFormat = (format.sampleRate, format.channelCount) }
                    self.trace("runtime.inputFormat")
#endif
                    guard format.sampleRate > 0, format.channelCount > 0 else { throw MeetingCaptureError.unsupportedAudioFormat }
                    inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, time in
                        self?.accept(buffer, time: time)
                    }
                    self.installedTap = true
                    self.engine.prepare()
#if DEBUG
                    self.trace("runtime.engineStart.before")
#endif
                    try self.engine.start()
#if DEBUG
                    self.trace("runtime.engineStart.after")
#endif
                    guard audioSession.currentRoute.inputs.contains(where: { $0.uid == self.microphone.captureDeviceID }) else {
                        throw MeetingCaptureError.microphoneUnavailable
                    }
                    self.observeLifecycle()
                    continuation.resume()
                } catch {
#if DEBUG
                    self.trace("runtime.start.failed")
#endif
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async throws {
#if DEBUG
        self.trace("runtime.stop.begin")
#endif
        self.lock.withLock { self.stopping = true }
        await withCheckedContinuation { continuation in
            self.controlQueue.async {
                self.engine.stop()
                if self.installedTap { self.engine.inputNode.removeTap(onBus: 0); self.installedTap = false }
                self.engine.reset()
                for observer in self.observers { NotificationCenter.default.removeObserver(observer) }
                self.observers.removeAll()
                continuation.resume()
            }
        }
        // A tap already admitted before stop may still be copying. Join those producers before
        // placing the PCM-queue drain, so no owned copy can arrive after the barrier.
        await withCheckedContinuation { continuation in
            self.producerGroup.notify(queue: self.controlQueue) {
                // Stop rejects new taps under the same lock as producer admission. A tap
                // already admitted may still need its reservation before it can copy PCM.
                self.gate.close()
                continuation.resume()
            }
        }
        // Enqueued copies and the finite resampling tail must finish before model/file ownership
        // is released. No callback task outlives this join.
        await withCheckedContinuation { continuation in
            self.pcmQueue.async {
                if self.lock.withLock({ self.terminalFailure == nil }) {
                    do { if let tail = try self.converter.finish() { self.deliver(tail) } }
                    catch { self.fail(error, kind: .clockDiscontinuity) }
                }
                continuation.resume()
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.controlQueue.async { [self] in
                do {
                    if self.configuredSession {
                        let session = AVAudioSession.sharedInstance()
#if DEBUG
                        self.trace("runtime.restore.before")
#endif
                        var restorationFailure: Error?
                        func restore(_ stage: String, _ operation: () throws -> Void) {
                            do { try operation() } catch {
                                restorationFailure = restorationFailure ?? error
                                DebugLogger.shared.warning("audio_restore_failed stage=\(stage) code=\((error as NSError).code)", source: "IOSMeetingCaptureEngine")
                            }
                        }
                        // Attempt every restoration even when one setter fails. The engine/tap
                        // are already stopped, so restoring a vanished input to automatic is safe.
                        // Deactivate before preference changes can start a hardware route change.
                        restore("deactivate") { try session.setActive(false, options: .notifyOthersOnDeactivation) }
                        let priorInput = self.savedPreferredInput.flatMap { prior in
                            session.availableInputs?.first(where: { $0.uid == prior.uid })
                        }
                        restore("preferred_input") { try session.setPreferredInput(priorInput) }
                        if let rate = self.savedPreferredSampleRate, rate > 0 {
                            restore("sample_rate") { try session.setPreferredSampleRate(rate) }
                        }
                        if let duration = self.savedPreferredIOBufferDuration, duration > 0 {
                            restore("buffer_duration") { try session.setPreferredIOBufferDuration(duration) }
                        }
                        if let category = self.savedCategory, let mode = self.savedMode, let options = self.savedOptions {
                            restore("category") { try session.setCategory(category, mode: mode, options: options) }
                        }
                        self.configuredSession = false
#if DEBUG
                        self.trace("runtime.restore.after")
#endif
                        if let restorationFailure { throw restorationFailure }
                    }
                    if let failure = self.lock.withLock({ self.terminalFailure }) { throw failure }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func healthSnapshot() -> MeetingTrackHealth { self.lock.withLock { self.health } }

#if DEBUG
    // Inject synthetic native PCM without opening the microphone or activating a session.
    func acceptForTesting(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) { self.accept(buffer, time: time) }
    var hasClosedAdmissionForTesting: Bool { self.lock.withLock { self.stopping } }
#endif

    private func accept(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        let admitted = self.lock.withLock {
            guard !self.stopping else { return false }
            self.producerGroup.enter()
            return true
        }
        guard admitted else { return }
        defer { self.producerGroup.leave() }
        self.afterAdmission?()
        guard let reservation = self.gate.reserve(frames: Int(buffer.frameLength),
                                                   channels: Int(buffer.format.channelCount), sampleRate: buffer.format.sampleRate) else {
            self.fail(MeetingCapturePCMError.conversionFailed(PichiLocalization.text("The bounded microphone queue is full.")), kind: .writerBackpressure)
            return
        }
        do {
            guard time.isHostTimeValid else { throw MeetingCapturePCMError.invalidPresentationTime }
            let copy = try MeetingCapturePCMConverter.ownedMonoCopy(of: buffer)
            let pts = CMTime(seconds: AVAudioTime.seconds(forHostTime: time.hostTime), preferredTimescale: 1_000_000_000)
            let input = OwnedInput(buffer: copy, pts: pts, reservation: reservation)
            self.pcmQueue.async {
                defer { self.gate.release(input.reservation) }
                guard self.lock.withLock({ self.terminalFailure == nil }) else { return }
                do {
                    if let converted = try self.converter.convert(input.buffer, presentationTime: input.pts) { self.deliver(converted) }
                } catch { self.fail(error, kind: .clockDiscontinuity) }
            }
        } catch {
            self.gate.release(reservation)
            self.fail(error, kind: .clockDiscontinuity)
        }
    }

    private func deliver(_ sample: CMSampleBuffer) {
#if DEBUG
        let firstPCM = self.lock.withLock { self.health.lastSampleAt == nil }
#endif
        if let writer, !writer.enqueue(sample) {
            self.fail(MeetingCaptureError.writerFailed(PichiLocalization.text("The bounded audio writer rejected microphone PCM.")), kind: .writerBackpressure)
            return
        }
        if let memoryConsumer, !memoryConsumer.enqueue(sample) {
            let error = memoryConsumer.rejectionReason.map(MeetingCapturePCMError.transcriptionRejected)
                ?? .transcriptionStopped
            self.fail(error,
                      kind: .writerBackpressure)
            return
        }
        // Tee only after the selected sink accepted this PCM. The coordinator uses this for
        // scalar capture progress in strict mode, without starting a second recognizer.
        self.liveAudioHandler?(.microphone, sample)
        let now = Date()
        let snapshot: MeetingTrackHealth? = self.lock.withLock {
            self.health.status = .healthy
            self.health.lastSampleAt = now
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            self.health.lastPresentationTime = MeetingMediaTime(value: pts.value, timescale: pts.timescale)
            if let buffer = MeetingLiveSampleCopy.copy(sample)?.buffer, let samples = buffer.floatChannelData?[0] {
                var peak: Float = 0
                for index in 0..<Int(buffer.frameLength) { peak = max(peak, abs(samples[index])) }
                self.health.level = min(1, peak)
            }
            guard now.timeIntervalSince(self.lastHealthTime) >= 0.1 else { return nil }
            self.lastHealthTime = now
            return self.health
        }
#if DEBUG
        if firstPCM { self.trace("runtime.firstPCM") }
#endif
        if let snapshot { self.eventHandler(.trackHealth(trackID: self.trackID, health: snapshot)) }
    }

    private func observeLifecycle() {
        let center = NotificationCenter.default
        self.observers = [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification,
                          AVAudioSession.mediaServicesWereResetNotification, AVAudioSession.mediaServicesWereLostNotification,
                          Notification.Name.AVAudioEngineConfigurationChange].map { name in
            center.addObserver(forName: name, object: name == .AVAudioEngineConfigurationChange ? self.engine : AVAudioSession.sharedInstance(), queue: nil) { [weak self] notification in
                guard let self, !self.lock.withLock({ self.stopping }) else { return }
#if DEBUG
                self.trace("runtime.notification", notification: notification)
#endif
                if notification.name == AVAudioSession.interruptionNotification {
                    guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                          AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
                    self.fail(MeetingCaptureError.captureStartFailed(PichiLocalization.text("The audio session was interrupted by the operating system.")), kind: .sourceLost)
                } else if notification.name == AVAudioSession.routeChangeNotification {
                    guard !AVAudioSession.sharedInstance().currentRoute.inputs.contains(where: { $0.uid == self.microphone.captureDeviceID }) else { return }
                    self.fail(MeetingCaptureError.microphoneUnavailable, kind: .microphoneDisconnected)
                } else {
                    self.fail(MeetingCaptureError.captureStartFailed(PichiLocalization.text("The microphone audio configuration changed.")), kind: .sourceLost)
                }
            }
        }
    }

#if DEBUG
    private func trace(_ phase: String, notification: Notification? = nil) {
        let state = self.lock.withLock { (self.health.lastSampleAt != nil, self.traceInputFormat) }
        IOSMeetingCaptureTrace.emit(phase, owner: String(describing: self.trackID),
            selectedUID: self.microphone.captureDeviceID, engineRunning: self.engine.isRunning,
            firstPCM: state.0, inputFormat: state.1, notification: notification)
    }
#endif

    private func fail(_ error: Error, kind: MeetingInterruptionKind) {
        let first = self.lock.withLock {
            guard self.terminalFailure == nil else { return false }
            self.terminalFailure = error
            self.health.status = .unavailable
            self.health.detail = error.localizedDescription
            return true
        }
        self.gate.close()
        guard first else { return }
        DebugLogger.shared.error("capture_stopped sessionTrack=\(self.trackID) interruption=\(kind.rawValue) errorType=\(String(reflecting: type(of: error)))", source: "IOSMeetingCaptureEngine")
        self.eventHandler(.interrupted(kind: kind, trackID: self.trackID, detail: error.localizedDescription))
        self.eventHandler(.interrupted(kind: .captureStoppedUnexpectedly, trackID: self.trackID, detail: error.localizedDescription))
    }
}

#if DEBUG
/// File-local diagnostics for the category ownership race. No session setters, engine nodes,
/// audio buffers or transcript data are touched. The process-wide lock caps output at 32 lines.
private nonisolated enum IOSMeetingCaptureTrace {
    static let enabled = ProcessInfo.processInfo.environment["PICHI_IOS_CAPTURE_TRACE"] == "1"
    private static let lock = NSLock()
    private nonisolated(unsafe) static var emitted = 0

    static func emit(_ phase: String, owner: String, selectedUID: String? = nil,
                     engineRunning: Bool? = nil, firstPCM: Bool? = nil,
                     inputFormat: (sampleRate: Double, channels: UInt32)? = nil,
                     notification: Notification? = nil) {
        guard self.enabled else { return }
        self.lock.withLock {
            guard self.emitted < 32 else { return }
            self.emitted += 1
            let session = AVAudioSession.sharedInstance()
            var payload: [String: Any] = [
                "event": self.emitted, "uptime": ProcessInfo.processInfo.systemUptime,
                "phase": phase, "owner": owner,
                "category": session.category.rawValue, "mode": session.mode.rawValue,
                "categoryOptions": session.categoryOptions.rawValue,
                "inputs": session.currentRoute.inputs.map(\.uid),
                "outputs": session.currentRoute.outputs.map(\.portType.rawValue),
                "availableInputs": (session.availableInputs ?? []).map(\.uid),
                "preferredInput": session.preferredInput?.uid ?? "",
                "sampleRate": session.sampleRate, "ioBufferDuration": session.ioBufferDuration,
            ]
            if let selectedUID { payload["selectedUID"] = selectedUID }
            if let engineRunning { payload["engineRunning"] = engineRunning }
            if let firstPCM { payload["firstPCM"] = firstPCM }
            if let inputFormat {
                payload["inputSampleRate"] = inputFormat.sampleRate
                payload["inputChannels"] = inputFormat.channels
            }
            if let notification {
                payload["notification"] = notification.name.rawValue
                payload["routeChangeReason"] = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber
                payload["interruptionType"] = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber
                if let previous = notification.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription {
                    payload["previousInputs"] = previous.inputs.map(\.uid)
                    payload["previousOutputs"] = previous.outputs.map(\.portType.rawValue)
                }
            }
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) { print("[IOS_CAPTURE_TRACE] \(text)") }
        }
    }
}
#endif
#endif
