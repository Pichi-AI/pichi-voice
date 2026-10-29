#if DEBUG

import AVFoundation
import CoreGraphics
import CoreMedia
import CryptoKit
import Darwin
@testable import FluidVoice_Debug
import Foundation
import XCTest

/// Opt-in capture of synthetic speech played by an external browser through the real meeting
/// engine. The normal suite skips this test. The parent interactive session owns all UI/audio.
///
/// Run only the test below against the exact frozen, normally signed/authorized test host, with
/// FLUIDVOICE_MIC_PHASE1=disabled. Set PICHI_BROWSER_CAPTURE_CONSENT=1, TARGET_BUNDLE_ID (for
/// example com.google.Chrome), ROOT (an absolute, private_assets child in this worktree), and
/// RUN_ID (a fresh UUID), each prefixed PICHI_BROWSER_CAPTURE_. DURATION_SECONDS defaults to 25
/// and must be in 5...30. ROOT must have no capture-ready.json or outcome.json from an older run.
///
/// After capture-ready.json contains the expected RUN_ID, play the approved synthetic spoken WAV
/// in the selected browser, preferably through the same WebRTC receive path as a meeting. Do not
/// play it with AVAudioPlayer in the test host: the runtime excludes current-process audio. Keep
/// headphones connected when practical, remain quiet, and capture native screenshots externally.
/// Both real meeting tracks and session.json are retained under ROOT/sessions. Numeric outcome
/// proves signal in applicationAudio alone; microphone energy cannot satisfy that assertion.
///
/// Optional GIGAAM_MODEL_DIR and EXPECTED_TEXT (same prefix) verify the saved browser speech with
/// the existing provider. Only an installed pinned artifact is read; no downloads/default changes
/// occur. The optional transcript stays in the private outcome, never stdout or an attachment.
/// Start/stop deadlines cancel cooperatively and join ownership before returning; the caller must
/// retain the outer XCTest/process watchdog for an unresponsive OS audio service.
/// CONTINUITY=1 extends this same selected-application probe to 60...150 seconds, permits a
/// silent application track, and requires continuous microphone delivery to the live PCM hook.
/// This mode checks capture/delivery during externally operated sharing, not ASR word accuracy.
@MainActor
final class MeetingBrowserAudioHardwareTests: XCTestCase {
    func testSelectedBrowserSpeechIsSavedInApplicationTrackWhenEnabled() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PICHI_BROWSER_CAPTURE_CONSENT"] == "1" else {
            throw XCTSkip("Set PICHI_BROWSER_CAPTURE_CONSENT=1 and explicit target/root/run ID for browser capture.")
        }
        let options = try BrowserCaptureOptions(environment: environment)
        try options.preparePrivateRoot()
        do {
            // Never call engine.preflightPermissions(): an automated test must not request TCC.
            try Self.require(CGPreflightScreenCaptureAccess(), "Screen recording is not preflight-authorized.")
            try Self.require(
                AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                "Microphone recording is not preflight-authorized."
            )
            let report = try await self.capture(options: options)
            try Self.write(report, to: options.root.appendingPathComponent("outcome.json"))
            XCTAssertTrue(report.failures.isEmpty, report.failures.joined(separator: " "))
        } catch {
            try? Self.write(BrowserCaptureReport(
                runID: options.runID, targetBundleID: options.bundleID,
                durationSeconds: options.durationSeconds, status: "failed",
                failures: [error.localizedDescription], sessionDirectory: nil,
                captureScope: nil, tracks: [], events: nil, speechText: nil
            ), to: options.root.appendingPathComponent("outcome.json"))
            throw error
        }
    }

    private func capture(options: BrowserCaptureOptions) async throws -> BrowserCaptureReport {
        let applications = try await Self.withDeadline(seconds: 8) {
            try await MeetingCaptureSourceCatalog.availableApplications()
        }
        let application = try MeetingCaptureSourceCatalog.resolveApplication(
            from: applications, preferredBundleIdentifier: options.bundleID,
            requirePreferredApplication: true
        )
        let processID = try XCTUnwrap(application.processID)
        try Self.require(processID > 0, "Selected application has no process identity.")
        let microphone = try await MeetingCaptureSourceCatalog.defaultMicrophone()
        let configuration = MeetingCaptureConfiguration(
            mode: .onlineCall, title: "Synthetic browser capture", languageCode: "ru",
            application: application, microphone: microphone
        )
        var machTimebase = mach_timebase_info_data_t()
        mach_timebase_info(&machTimebase)
        var session = MeetingSession(configuration: configuration, timebase: MeetingTimebaseMetadata(
            startedHostTime: mach_absolute_time(), machTimebaseNumerator: machTimebase.numer,
            machTimebaseDenominator: machTimebase.denom, firstPresentationTime: nil
        ))
        let store = MeetingSessionStore(rootDirectory: options.root.appendingPathComponent("sessions"))
        try await store.create(session)
        let directory = try await store.sessionDirectory(for: session.id)
        let engine = MeetingCaptureEngine()
        let events = BrowserCaptureEvents()
        let live = BrowserCaptureLiveInput()
        var finalLiveInput: [String: BrowserCaptureLiveTrack] = [:]
        let immutableSession = session
        let start: MeetingCaptureStartResult
        do {
            start = try await Self.withDeadline(seconds: 8) {
                try await engine.start(
                    session: immutableSession, configuration: configuration,
                    sessionDirectory: directory, eventHandler: { events.record($0) },
                    liveAudioHandler: { kind, sample in live.record(kind, sample: sample) }
                )
            }
            session.audioTracks = start.tracks
            session.state = .recording
            session.updatedAt = Date()
            try await store.save(session)
            try Self.write(BrowserCaptureReady(
                runID: options.runID, targetBundleID: application.bundleIdentifier,
                processID: processID, sessionID: session.id,
                sessionDirectory: directory.path, durationSeconds: options.durationSeconds,
                readyAt: Date()
            ), to: options.root.appendingPathComponent("capture-ready.json"))
            if options.continuity {
                let deadline = ProcessInfo.processInfo.systemUptime + options.durationSeconds
                while ProcessInfo.processInfo.systemUptime < deadline {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    try Self.write(live.snapshot(includeCurrentGap: true), to: options.root.appendingPathComponent("live-input.json"))
                }
            } else {
                try await Task.sleep(nanoseconds: UInt64(options.durationSeconds * 1_000_000_000))
            }
            // Freeze before Stop/decode so intentional teardown cannot look like capture starvation.
            finalLiveInput = live.snapshot(includeCurrentGap: true)
            try Task.checkCancellation()
            let sessionID = session.id
            let stop = try await Self.withDeadline(seconds: 8) {
                try await engine.stop(sessionID: sessionID)
            }
            session.audioTracks = stop.tracks
            session.endedAt = stop.stoppedAt
            // This test validates capture only. It must not claim a processed/completed meeting.
            session.state = .interrupted
            session.recoveryResolvedAt = stop.stoppedAt
            session.updatedAt = stop.stoppedAt
            session.events = events.interruptions()
            try await store.save(session)
            await engine.shutdownForTermination()
        } catch {
            // Joins active runtime and writer teardown even if cancellation/failure interrupts
            // the ready write, bounded wait, or stop operation. Never leave a capture running.
            await engine.shutdownForTermination()
            if case let MeetingCaptureError.captureStopFailed(_, partialResult) = error {
                session.audioTracks = partialResult.tracks
                session.endedAt = partialResult.stoppedAt
            }
            session.state = .failed
            session.updatedAt = Date()
            session.events = events.interruptions()
            try? await store.save(session)
            throw error
        }

        // The legacy browser probe includes startup/ready/drain time outside its 5...30-second
        // stimulus wait. Preserve its original 60-second decode cap rather than using that wait.
        let tracks = try session.audioTracks.map {
            try Self.measure($0, in: directory, maximumCaptureDuration: options.continuity ? options.durationSeconds + 20 : 60)
        }
        let eventSummary = events.summary()
        var failures: [String] = []
        let terminalInterruptions: [MeetingInterruptionKind] = [
            .writerFailure, .diskExhausted, .permissionRevoked, .captureStoppedUnexpectedly,
            .applicationExited, .microphoneDisconnected,
        ]
        for kind in terminalInterruptions where eventSummary.interruptionsByKind[kind.rawValue, default: 0] > 0 {
            failures.append("Capture reported \(kind.rawValue) before finalization.")
        }
        if eventSummary.droppedInterruptionDetails > 0 {
            failures.append("Capture exceeded the bounded interruption evidence limit.")
        }
        if Set(tracks.map(\.kind)) != Set(["applicationAudio", "microphone"]) {
            failures.append("Real meeting capture did not produce both tracks.")
        }
        for track in tracks where (!options.continuity || track.kind == "microphone") && (track.chunkCount == 0 || track.finalizedChunkCount != track.chunkCount
            || track.persistedBytes == 0 || track.decodedFrames == 0 || track.nonFiniteSamples > 0) {
            failures.append("\(track.kind) has missing, unfinalized, empty, or invalid audio.")
        }
        if let browser = tracks.first(where: { $0.kind == "applicationAudio" }) {
            if browser.sourceIdentifier != options.bundleID || (!options.continuity && (browser.rms <= 0.001
                || browser.peak <= 0.01 || browser.nonSilentSeconds < 0.5)) {
                failures.append("Selected applicationAudio did not contain the externally played speech signal.")
            }
        }
        let liveInput = finalLiveInput
        if options.continuity {
            if let microphone = liveInput["microphone"], microphone.callbacks > 0 {
                if microphone.maximumArrivalGapSeconds > 3 || microphone.maximumPresentationGapSeconds > 3 {
                    failures.append("Live microphone PCM delivery stalled for more than three seconds.")
                }
                if microphone.deliveredDurationSeconds < options.durationSeconds - 3 {
                    failures.append("Live microphone PCM coverage is shorter than the controlled capture interval.")
                }
            } else {
                failures.append("Production capture did not deliver microphone PCM to its live handler.")
            }
            try Self.write(liveInput, to: options.root.appendingPathComponent("live-input.json"))
        }
        var speechText: String?
        do {
            speechText = try await Self.verifySpeechIfRequested(options: options, session: session, directory: directory)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            failures.append("Saved applicationAudio speech verification failed: \(error.localizedDescription)")
        }
        if let speechText, speechText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            failures.append("Saved applicationAudio produced an empty speech transcript.")
        }
        if let expectedText = options.expectedText, let speechText,
           !speechText.localizedCaseInsensitiveContains(expectedText) {
            failures.append("Saved applicationAudio transcript did not contain the expected synthetic phrase.")
        }
        return BrowserCaptureReport(
            runID: options.runID, targetBundleID: options.bundleID, durationSeconds: options.durationSeconds,
            status: failures.isEmpty ? "passed" : "failed", failures: failures,
            sessionDirectory: directory.path, captureScope: start.captureScope.map { String(describing: $0) },
            tracks: tracks, events: eventSummary, speechText: speechText,
            liveInput: liveInput
        )
    }

    private static func verifySpeechIfRequested(
        options: BrowserCaptureOptions, session: MeetingSession, directory: URL
    ) async throws -> String? {
        guard let modelDirectory = options.modelDirectory else { return nil }
        let modelStore = PichiGigaAMModelStore(directory: modelDirectory)
        let fingerprint = try modelStore.installedModelFingerprint()
        // A nonnil expected fingerprint uses installedModel(), never ensureInstalled/download.
        let provider = PichiGigaAMProvider(modelStore: modelStore, expectedModelFingerprint: fingerprint)
        do {
            let text = try await Self.withDeadline(seconds: 30) { @MainActor in
                try await provider.prepare()
                let applicationTrack = try XCTUnwrap(session.audioTracks.first { $0.kind == .applicationAudio })
                var samples: [Float] = []
                for chunk in applicationTrack.chunks.sorted(by: { $0.sequence < $1.sequence }) {
                    let reader = try LocalAPIAudioDecoder.ChunkReader(
                        fileURL: directory.appendingPathComponent(chunk.relativeFilePath), chunkDurationSeconds: 30
                    )
                    while true {
                        try Task.checkCancellation()
                        let next = try await reader.nextSamples()
                        if next.isEmpty { break }
                        try Self.require(samples.count + next.count <= 16_000 * 60, "Speech decoder exceeded its sample bound.")
                        samples.append(contentsOf: next)
                    }
                }
                return try await provider.transcribeFinal(samples).text
            }
            await provider.unloadModel()
            return text
        } catch {
            await provider.unloadModel()
            throw error
        }
    }

    fileprivate nonisolated static func measure(
        _ track: MeetingAudioTrack, in directory: URL, maximumCaptureDuration: Double
    ) throws -> BrowserCaptureTrackMetrics {
        try Self.require(maximumCaptureDuration.isFinite && (5...180).contains(maximumCaptureDuration),
                         "Capture decoding duration must be in the supported 5...180-second probe range.")
        var result = BrowserCaptureTrackMetrics(
            kind: track.kind.rawValue, sourceIdentifier: track.sourceIdentifier,
            captureMethod: track.captureMethod?.rawValue, health: track.health.status.rawValue,
            chunkCount: track.chunks.count, finalizedChunkCount: 0, persistedBytes: 0,
            decodedFrames: 0, decodedSamples: 0, nonFiniteSamples: 0, nonSilentSeconds: 0, rms: 0, peak: 0
        )
        var squaredSum = 0.0
        for chunk in track.chunks {
            guard chunk.finalizationState == .finalized else { continue }
            result.finalizedChunkCount += 1
            let fileURL = directory.appendingPathComponent(chunk.relativeFilePath)
            try Self.require(fileURL.pathExtension.lowercased() == "caf", "Meeting analysis chunk is not CAF.")
            let byteCount = (try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
            try Self.require(byteCount == chunk.byteCount && byteCount > 0, "Finalized CAF size disagrees with its manifest.")
            result.persistedBytes += byteCount
            let file = try AVAudioFile(forReading: fileURL, commonFormat: .pcmFormatFloat32, interleaved: false)
            let format = file.processingFormat
            try Self.require(format.sampleRate.isFinite && format.sampleRate > 0 && format.sampleRate <= 192_000,
                             "CAF has an invalid or unsupported decoding sample rate.")
            let startSeconds = chunk.presentationStart.seconds
            let endSeconds = chunk.presentationEnd.seconds
            // Subtract rational media times before converting to Double. Subtracting large
            // host-second Doubles first loses precision that can falsely exceed one frame.
            let interval = CMTimeSubtract(
                CMTime(value: chunk.presentationEnd.value, timescale: chunk.presentationEnd.timescale),
                CMTime(value: chunk.presentationStart.value, timescale: chunk.presentationStart.timescale)
            )
            let declaredDuration = CMTimeGetSeconds(interval)
            let declaredFrames = declaredDuration * format.sampleRate
            let frameLimit = maximumCaptureDuration * format.sampleRate
            try Self.require(chunk.presentationStart.timescale > 0 && chunk.presentationEnd.timescale > 0
                             && startSeconds.isFinite && endSeconds.isFinite && startSeconds >= 0 && declaredDuration > 0
                             && declaredFrames.isFinite && declaredFrames <= frameLimit + 1
                             && file.length > 0 && Double(file.length) <= frameLimit + 1,
                             "CAF exceeds its configured capture decoding bound or has an invalid declared time range.")
            // The writer rotates BEFORE an incoming packet, then appends that packet whole.
            // Sixty seconds is a rotation target, not a hard CAF frame cap. For contiguous chunks,
            // trust the declared canonical interval only when its frame count agrees with disk.
            // The one-frame allowance accounts for timestamp quantization, not packet overshoot.
            let hasTimelineBoundary = chunk.discontinuities.contains {
                $0.kind == .clockDiscontinuity || ($0.gapSeconds ?? 0) > 0
            }
            if !hasTimelineBoundary {
                let roundingAllowance = 1 + max(abs(declaredFrames), Double(file.length)).ulp * 8
                try Self.require(abs(Double(file.length) - declaredFrames) <= roundingAllowance,
                                 "CAF frame count disagrees with its contiguous canonical chunk duration.")
            }
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192))
            while file.framePosition < file.length {
                try file.read(into: buffer, frameCount: 8192)
                let channels = try XCTUnwrap(buffer.floatChannelData)
                let frameCount = Int(buffer.frameLength)
                try Self.require(frameCount > 0, "CAF decoder made no progress.")
                var nonSilentFrames = 0
                for frame in 0..<frameCount {
                    var nonSilent = false
                    for channel in 0..<Int(format.channelCount) {
                        let sample = Double(channels[channel][frame])
                        result.decodedSamples += 1
                        guard sample.isFinite else { result.nonFiniteSamples += 1; continue }
                        squaredSum += sample * sample
                        result.peak = max(result.peak, abs(sample))
                        nonSilent = nonSilent || abs(sample) > 0.0001
                    }
                    if nonSilent { nonSilentFrames += 1 }
                }
                result.decodedFrames += Int64(frameCount)
                result.nonSilentSeconds += Double(nonSilentFrames) / format.sampleRate
            }
        }
        result.rms = result.decodedSamples > 0 ? sqrt(squaredSum / Double(result.decodedSamples)) : 0
        try Self.require(result.nonFiniteSamples == 0, "CAF contains \(result.nonFiniteSamples) non-finite PCM samples.")
        return result
    }

    fileprivate nonisolated static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    fileprivate nonisolated static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw BrowserCaptureFailure(message: message) }
    }

    fileprivate nonisolated static func withDeadline<T: Sendable>(
        seconds: Double, operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw BrowserCaptureFailure(message: "Browser capture operation exceeded \(seconds) seconds.")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw BrowserCaptureFailure(message: "Browser capture operation returned no result.")
            }
            return result
        }
    }
}

private struct BrowserCaptureFailure: LocalizedError {
    let message: String
    var errorDescription: String? { self.message }
}

private struct BrowserCaptureOptions {
    let bundleID: String
    let root: URL
    let runID: UUID
    let durationSeconds: Double
    let modelDirectory: URL?
    let expectedText: String?
    let continuity: Bool

    init(environment: [String: String]) throws {
        func required(_ suffix: String) throws -> String {
            guard let value = environment["PICHI_BROWSER_CAPTURE_" + suffix]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { throw BrowserCaptureFailure(message: "Missing PICHI_BROWSER_CAPTURE_" + suffix) }
            return value
        }
        self.bundleID = try required("TARGET_BUNDLE_ID")
        let rootPath = try required("ROOT")
        guard rootPath.hasPrefix("/") else { throw BrowserCaptureFailure(message: "ROOT must be an absolute path.") }
        self.root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let privateAssets = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("private_assets").standardizedFileURL.resolvingSymlinksInPath()
        guard self.root.path.hasPrefix(privateAssets.path + "/") else {
            throw BrowserCaptureFailure(message: "ROOT must be inside this worktree's ignored private_assets directory.")
        }
        guard let runID = UUID(uuidString: try required("RUN_ID")) else {
            throw BrowserCaptureFailure(message: "RUN_ID must be a fresh UUID.")
        }
        self.runID = runID
        self.continuity = environment["PICHI_BROWSER_CAPTURE_CONTINUITY"] == "1"
        let rawDuration = environment["PICHI_BROWSER_CAPTURE_DURATION_SECONDS"] ?? (self.continuity ? "120" : "25")
        let allowedDuration = self.continuity ? 60.0...150.0 : 5.0...30.0
        guard let duration = Double(rawDuration), duration.isFinite, allowedDuration.contains(duration) else {
            throw BrowserCaptureFailure(message: "DURATION_SECONDS is outside the selected bounded capture range.")
        }
        self.durationSeconds = duration
        let modelPath = environment["PICHI_BROWSER_CAPTURE_GIGAAM_MODEL_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.modelDirectory = modelPath.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        self.expectedText = environment["PICHI_BROWSER_CAPTURE_EXPECTED_TEXT"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if self.expectedText != nil && (self.modelDirectory == nil || self.expectedText?.isEmpty == true) {
            throw BrowserCaptureFailure(message: "EXPECTED_TEXT requires an installed GIGAAM_MODEL_DIR and nonempty text.")
        }
    }

    func preparePrivateRoot() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try manager.attributesOfItem(atPath: self.root.path)
        guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
              let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue, permissions & 0o077 == 0 else {
            throw BrowserCaptureFailure(message: "ROOT must be owned by this user with mode 0700.")
        }
        for name in ["capture-ready.json", "outcome.json"] where manager.fileExists(atPath: self.root.appendingPathComponent(name).path) {
            throw BrowserCaptureFailure(message: "ROOT contains a stale \(name); choose a fresh run directory.")
        }
    }
}

private struct BrowserCaptureReady: Encodable {
    let runID: UUID
    let targetBundleID: String
    let processID: Int32
    let sessionID: UUID
    let sessionDirectory: String
    let durationSeconds: Double
    let readyAt: Date
}

private struct BrowserCaptureReport: Encodable {
    let runID: UUID
    let targetBundleID: String
    let durationSeconds: Double
    let status: String
    let failures: [String]
    let sessionDirectory: String?
    let captureScope: String?
    let tracks: [BrowserCaptureTrackMetrics]
    let events: BrowserCaptureEventSummary?
    let speechText: String?
    var liveInput: [String: BrowserCaptureLiveTrack]? = nil
}

private struct BrowserCaptureLiveTrack: Encodable {
    var callbacks = 0
    var frames: Int64 = 0
    var deliveredDurationSeconds = 0.0
    var maximumArrivalGapSeconds = 0.0
    var maximumPresentationGapSeconds = 0.0
    var firstPresentationSeconds: Double?
    var lastPresentationEndSeconds: Double?
    var lastArrivalUptime: Double?
}

/// Numeric-only, bounded evidence of the actual production capture-to-live-callback boundary.
private final nonisolated class BrowserCaptureLiveInput: @unchecked Sendable {
    private let lock = NSLock()
    private var tracks: [String: BrowserCaptureLiveTrack] = [:]

    func record(_ kind: MeetingAudioTrackKind, sample: CMSampleBuffer) {
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0, let description = CMSampleBufferGetFormatDescription(sample),
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              format.pointee.mSampleRate.isFinite, format.pointee.mSampleRate > 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let start = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
        guard start.isFinite else { return }
        let end = start + Double(frames) / format.pointee.mSampleRate
        self.lock.withLock {
            var value = self.tracks[kind.rawValue] ?? BrowserCaptureLiveTrack()
            value.callbacks += 1
            value.frames += Int64(frames)
            value.deliveredDurationSeconds += Double(frames) / format.pointee.mSampleRate
            if let previous = value.lastArrivalUptime {
                value.maximumArrivalGapSeconds = max(value.maximumArrivalGapSeconds, now - previous)
            }
            if let previous = value.lastPresentationEndSeconds {
                value.maximumPresentationGapSeconds = max(value.maximumPresentationGapSeconds, start - previous)
            }
            value.firstPresentationSeconds = value.firstPresentationSeconds ?? start
            value.lastPresentationEndSeconds = end
            value.lastArrivalUptime = now
            self.tracks[kind.rawValue] = value
        }
    }

    func snapshot(includeCurrentGap: Bool = false) -> [String: BrowserCaptureLiveTrack] {
        self.lock.withLock {
            guard includeCurrentGap else { return self.tracks }
            let now = ProcessInfo.processInfo.systemUptime
            return self.tracks.mapValues { original in
                var value = original
                if let last = value.lastArrivalUptime {
                    value.maximumArrivalGapSeconds = max(value.maximumArrivalGapSeconds, now - last)
                }
                return value
            }
        }
    }
}

fileprivate struct BrowserCaptureTrackMetrics: Encodable {
    let kind: String
    let sourceIdentifier: String
    let captureMethod: String?
    let health: String
    let chunkCount: Int
    var finalizedChunkCount: Int
    var persistedBytes: Int64
    var decodedFrames: Int64
    var decodedSamples: Int64
    var nonFiniteSamples: Int64
    var nonSilentSeconds: Double
    var rms: Double
    var peak: Double
}

fileprivate struct BrowserCaptureEventSummary: Encodable {
    var trackHealthEvents = 0
    var finalizedChunkEvents = 0
    var captureMethodChanges = 0
    var interruptionsByKind: [String: Int] = [:]
    var droppedInterruptionDetails = 0
}

fileprivate final class BrowserCaptureEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var counts = BrowserCaptureEventSummary()
    private var retainedInterruptions: [MeetingSessionEvent] = []

    func record(_ event: MeetingCaptureEvent) {
        self.lock.withLock {
            switch event {
            case .audioComparisonProbeStarted:
                XCTFail("Ordinary continuity capture must not arm diagnostic recording")
            case .microphoneEchoProtectionChanged:
                break // Presentation status cannot change continuity counters or persisted interruptions.
            case .trackHealth: self.counts.trackHealthEvents += 1
            case .chunkFinalized: self.counts.finalizedChunkEvents += 1
            case let .captureMethodChanged(_, _, ack):
                self.counts.captureMethodChanges += 1
                ack?.resume()
            case let .interrupted(kind, trackID, _):
                self.counts.interruptionsByKind[kind.rawValue, default: 0] += 1
                if self.retainedInterruptions.count < 128 {
                    self.retainedInterruptions.append(MeetingSessionEvent(
                        id: UUID(), occurredAt: Date(), kind: kind, trackID: trackID, detail: nil
                    ))
                } else { self.counts.droppedInterruptionDetails += 1 }
            }
        }
    }

    func summary() -> BrowserCaptureEventSummary { self.lock.withLock { self.counts } }
    func interruptions() -> [MeetingSessionEvent] { self.lock.withLock { self.retainedInterruptions } }
}

/// Real system-audio continuity probe. The parent owns external stimulus/processes; this class
/// never operates UI, launches/kills a browser, changes defaults, or requests permissions.
/// See docs/development/system-audio-continuity-test.md for the atomic command/ack protocol.
@MainActor
final class MeetingSystemAudioContinuityHardwareTests: XCTestCase {
    private var phaseReplayProvider: (any TranscriptionProvider)?
    /// Run alone in the exact authorized XCTest application host. This exercises the same
    /// AppServices singleton composition as the app, but is not an ordinary UI interaction test.
    /// Add PICHI_SYSTEM_CAPTURE_COORDINATOR_CONSENT=1 to the existing ROOT/RUN_ID protocol.
    /// DURATION_SECONDS is bounded to 60...100 (default 100); admission and stop each allow 60.
    /// The host must already select an installed Parakeet v2/v3, enable meetings, and retain audio.
    /// No settings, provider, capture engine, store, or factory is replaced. Optional
    /// PICHI_SYSTEM_CAPTURE_VERIFY_ASR=1 requires EXPECTED_TEXT_JSON. It checks the normal
    /// final transcript and independently transcribes each exact persisted phase PCM range;
    /// coarse final utterance envelopes never supply phase-local evidence.
    func testAppServicesSystemAudioSurvivesExternalBrowserRestartWhenEnabled() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PICHI_SYSTEM_CAPTURE_COORDINATOR_CONSENT"] == "1" else {
            throw XCTSkip("Set PICHI_SYSTEM_CAPTURE_COORDINATOR_CONSENT=1 for the real AppServices coordinator probe.")
        }
        let options = try SystemContinuityOptions(environment: environment, requiresModelDirectoryForExpectedText: false)
        try MeetingBrowserAudioHardwareTests.require(options.durationSeconds <= 100, "Coordinator capture is bounded to 100 seconds.")
        try MeetingBrowserAudioHardwareTests.require(options.modelDirectory == nil, "Coordinator uses the installed selected model, not GIGAAM_MODEL_DIR.")
        let verifyASR = environment["PICHI_SYSTEM_CAPTURE_VERIFY_ASR"] == "1"
        try MeetingBrowserAudioHardwareTests.require(verifyASR == !options.expectedText.isEmpty,
            "VERIFY_ASR=1 and three distinct EXPECTED_TEXT_JSON phrases must be supplied together.")
        try options.prepareRoot()
        var report = SystemContinuityReport(runID: options.runID, status: "failed", failures: [])
        report.probeScope = "xctest-appservices-default-coordinator"
        var ownedSessionID: UUID?
        let ownedTitle = "Synthetic coordinator continuity \(options.runID.uuidString)"
        let coordinator = AppServices.shared.meetingSessionCoordinator
        let store = MeetingSessionStore.shared
        var protocolState = SystemContinuityProtocol(runID: options.runID)
        do {
            try MeetingBrowserAudioHardwareTests.require(CGPreflightScreenCaptureAccess(), "System audio is not preflight-authorized.")
            try MeetingBrowserAudioHardwareTests.require(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                "Microphone is not preflight-authorized.")
            let settings = SettingsStore.shared
            try MeetingBrowserAudioHardwareTests.require(settings.fluidMeetEnabled, "Meetings must already be enabled.")
            try MeetingBrowserAudioHardwareTests.require([.parakeetTDT, .parakeetTDTv2].contains(settings.selectedSpeechModel)
                && settings.selectedSpeechModel.isInstalled, "Select an already installed Parakeet v2/v3 before this probe.")
            let selectedModelID = settings.selectedSpeechModel.rawValue
            let replayDescriptor = try XCTUnwrap(settings.selectedSpeechModel.parakeetDescriptor)
            let replayDirectory = replayDescriptor.cacheDirectory(in: AppBrand.modelsDirectory)
            try MeetingBrowserAudioHardwareTests.require(replayDescriptor.artifactsAreComplete(at: replayDirectory),
                "The phase replay must use a complete installed export without downloading or repairing it.")
            let fingerprintTask = Task.detached(priority: .utility) {
                try replayDescriptor.installedArtifactFingerprint(at: replayDirectory)
            }
            let replayFingerprintValue = try await withTaskCancellationHandler {
                try await fingerprintTask.value
            } onCancel: { fingerprintTask.cancel() }
            let replayFingerprint = try XCTUnwrap(replayFingerprintValue, "The installed replay export must have a content fingerprint.")
            let replayConfiguration = MeetingFinalProcessingConfiguration(asrModel: selectedModelID,
                asrArtifactFingerprint: replayFingerprint, asrArtifactDirectory: replayDirectory,
                languageCode: "en", speakerLabelsEnabled: false)
            let expectedBackendID = PichiMeetingProviderFactory.selectedBackendID(languageCode: "en",
                selectedModelID: selectedModelID, savedBackendID: settings.meetingTranscriptionBackendID)
            try MeetingBrowserAudioHardwareTests.require(settings.meetingAudioRetentionPolicy != .afterTranscription,
                "Existing retention policy must preserve the finalized PCM evidence.")
            await coordinator.ensureRestored()
            try MeetingBrowserAudioHardwareTests.require(coordinator.activeSession == nil && !coordinator.hasPendingStart,
                "The singleton already owns a session or pending start; it cannot be used by this probe.")
            switch coordinator.state {
            case .idle, .completed: break
            default: throw BrowserCaptureFailure(message: "The singleton is not idle or completed.")
            }
            var configuration = try await coordinator.defaultConfiguration(mode: .onlineCall, title: ownedTitle)
            configuration.timestampDefaultTitle = false
            configuration.languageCode = "en"
            configuration.application = nil
            configuration.applicationAudioScope = .systemAudio
            configuration.audioStorageMode = .retainedFiles
            configuration.speakerLabelsEnabled = false
            configuration.speakerProcessingMode = nil
            configuration.piiRedactionEnabled = false
            let frozenConfiguration = configuration
            report.selectedSpeechModelID = selectedModelID
            let captureStart = SystemContinuityProtocol.hostSeconds()
            let session = try await Self.coordinatorOperation(coordinator, ownedTitle: ownedTitle) {
                try MeetingBrowserAudioHardwareTests.require(SettingsStore.shared.selectedSpeechModel.rawValue == selectedModelID,
                    "Selected model changed before ordinary recording admission.")
                return try await coordinator.startRecording(configuration: frozenConfiguration)
            }
            ownedSessionID = session.id
            try MeetingBrowserAudioHardwareTests.require(session.languageCode == "en"
                && session.recordingBackendID == expectedBackendID.rawValue,
                "Normal admission did not freeze the selected English Parakeet route.")
            report.recordingSessionID = session.id
            report.recordingBackendID = session.recordingBackendID
            report.recordingASRArtifactFingerprint = session.recordingASRArtifactFingerprint
            let directory = try await store.sessionDirectory(for: session.id)
            report.sessionDirectory = directory.path
            var observations: [SystemContinuityCoordinatorObservation] = []
            func observeRecording(_ sequence: Int) throws {
                try MeetingBrowserAudioHardwareTests.require(coordinator.state == .recording(session.id)
                    && coordinator.activeSession?.id == session.id && coordinator.activeSession?.state == .recording,
                    "Ordinary coordinator left recording or replaced the session during phase sequence \(sequence).")
                if observations.last?.sequence != sequence {
                    observations.append(SystemContinuityCoordinatorObservation(sequence: sequence, sessionID: session.id,
                        state: "recording", hostSeconds: SystemContinuityProtocol.hostSeconds()))
                    report.coordinatorObservations = observations
                }
            }
            try observeRecording(0)
            try MeetingBrowserAudioHardwareTests.write(
                SystemContinuityReady(runID: options.runID, sessionID: session.id, sessionDirectory: directory.path,
                    captureStartHostSeconds: captureStart, readyHostSeconds: SystemContinuityProtocol.hostSeconds(),
                    durationSeconds: options.durationSeconds), to: options.root.appendingPathComponent("capture-ready.json")
            )
            try await Self.waitForExternalPhases(options, protocolState: &protocolState, observeRecording: observeRecording)
            try observeRecording(8)
            let completed = try await Self.coordinatorOperation(coordinator, ownedTitle: ownedTitle) {
                try await coordinator.stopAndTranscribe()
            }
            try MeetingBrowserAudioHardwareTests.require(completed.id == session.id && completed.state == .completed
                && coordinator.state == .completed(session.id) && coordinator.activeSession == nil
                && coordinator.latestCompletedSession?.id == session.id, "Normal coordinator stop did not complete the same meeting.")
            let saved = try await store.load(id: session.id)
            let persisted = try XCTUnwrap(saved)
            let expectedStoredTracks = try Self.tracksUsingStoreDatePrecision(completed.audioTracks)
            try MeetingBrowserAudioHardwareTests.require(persisted.id == completed.id && persisted.state == .completed
                && persisted.audioTracks == expectedStoredTracks, "The ordinary store did not retain the completed tracks.")
            try MeetingBrowserAudioHardwareTests.require(persisted.recordingBackendID == session.recordingBackendID
                && persisted.recordingASRArtifactFingerprint == session.recordingASRArtifactFingerprint
                && persisted.processingAttempts.last?.asrModel == selectedModelID
                && (persisted.processingAttempts.last?.backendID == session.recordingBackendID
                    || (expectedBackendID == .legacyCompatibility && persisted.processingAttempts.last?.backendID == nil)),
                "Normal processing did not retain the admitted model and backend.")
            let observationsBeforeReport = report.coordinatorObservations
            report = Self.report(session: persisted, directory: directory, runID: options.runID, captureScope: nil,
                protocolState: protocolState, events: nil, failures: [], maximumCaptureDuration: options.durationSeconds)
            report.probeScope = "xctest-appservices-default-coordinator"
            report.recordingSessionID = session.id
            report.selectedSpeechModelID = selectedModelID
            report.recordingBackendID = persisted.recordingBackendID
            report.recordingASRArtifactFingerprint = persisted.recordingASRArtifactFingerprint
            report.coordinatorObservations = observationsBeforeReport
            report.finalProcessingCompleted = true
            report.transcriptCoverageGaps = persisted.transcriptCoverageGaps ?? []
            // The coordinator owns capture events. Report its persisted events rather than
            // installing a second event handler or claiming observed engine diagnostics.
            report.events = nil
            var eventSummary = BrowserCaptureEventSummary()
            for event in persisted.events { eventSummary.interruptionsByKind[event.kind.rawValue, default: 0] += 1 }
            report.events = eventSummary
            let phaseSamples = try await Self.validateSavedPCM(session: persisted, directory: directory, protocolState: protocolState,
                report: &report, requiresEngineScope: false)
            if verifyASR {
                let track = try XCTUnwrap(persisted.audioTracks.first { $0.kind == .applicationAudio })
                let origin = persisted.transcriptTimeDomain == .meetingRelative
                    ? try XCTUnwrap(persisted.timebase.firstPresentationTime).seconds : 0
                for gap in report.transcriptCoverageGaps where gap.trackID == track.id && protocolState.phases.contains(where: {
                    gap.end + origin > $0.startHostSeconds && gap.start + origin < $0.endHostSeconds
                }) {
                    report.failures.append("Final system transcript has a \(gap.reason.rawValue) coverage gap during a speech phase.")
                }
                let systemSegments = persisted.transcriptSegments.filter { $0.sourceTrackID == track.id }
                let finalText = systemSegments.sorted { $0.start < $1.start }.map(\.text).joined(separator: " ")
                for index in report.phases.indices {
                    let phase = report.phases[index].phase
                    let candidates = systemSegments.filter {
                        $0.end.seconds + origin > phase.startHostSeconds
                            && $0.start.seconds + origin < phase.endHostSeconds
                    }
                    report.normalFinalCrossingSegmentCounts[phase.name] = candidates.filter {
                        !phase.containsTranscript(start: $0.start.seconds, end: $0.end.seconds, origin: origin)
                    }.count
                    if let expected = options.expectedText[phase.name] {
                        let present = finalText.localizedCaseInsensitiveContains(expected)
                        report.normalFinalTranscriptMarkers[phase.name] = present
                        if !present { report.failures.append("Normal finalized system transcript lacks the \(phase.name) marker.") }
                    }
                }
                // Join the ordinary owner before a separate, task-owned provider verifies the
                // saved PCM. Its pinned directory forces local-only loading through the existing adapter.
                await Self.shutdownOwnedCoordinator(coordinator, title: ownedTitle)
                self.phaseReplayProvider = try PichiMeetingProviderFactory.make(replayConfiguration)
                do {
                    try await MeetingBrowserAudioHardwareTests.withDeadline(seconds: 30) { @MainActor [self] in
                        try await XCTUnwrap(self.phaseReplayProvider).prepare(progressHandler: nil)
                    }
                    let names = report.phases.map { $0.phase.name }
                    let texts = try await Self.verifyPhaseSpeech(samples: phaseSamples, names: names,
                        expected: options.expectedText) { @MainActor [self] samples in
                        try await MeetingBrowserAudioHardwareTests.withDeadline(seconds: 30) { @MainActor [self] in
                            try await XCTUnwrap(self.phaseReplayProvider).transcribeFinal(samples).text
                        }
                    }
                    for index in texts.indices { report.phases[index].speechText = texts[index] }
                    report.phaseASREvidenceSource = "persisted-system-pcm-replay"
                    report.phaseReplayArtifactFingerprint = replayFingerprint
                    await self.phaseReplayProvider?.releaseResidency()
                    self.phaseReplayProvider = nil
                } catch {
                    await self.phaseReplayProvider?.releaseResidency()
                    self.phaseReplayProvider = nil
                    throw error
                }
            }
            await Self.shutdownOwnedCoordinator(coordinator, title: ownedTitle)
        } catch {
            let ownedActiveID = coordinator.activeSession.flatMap { $0.title == ownedTitle ? $0.id : nil }
            if ownedSessionID != nil || ownedActiveID != nil {
                await Self.shutdownOwnedCoordinator(coordinator, title: ownedTitle)
                let sessionID = ownedSessionID ?? ownedActiveID
                if let sessionID, let saved = try? await store.load(id: sessionID) {
                    report.sessionState = saved.state.rawValue
                    report.endedAt = saved.endedAt
                    report.sessionDirectory = try? await store.sessionDirectory(for: sessionID).path
                }
            }
            report.failures.append(error.localizedDescription)
        }
        report.protocolComplete = protocolState.isComplete
        report.commands = protocolState.commands
        report.acknowledgements = protocolState.acknowledgements
        report.phaseWindows = protocolState.phases
        report.browserAbsentSeconds = protocolState.browserAbsentSeconds
        report.status = report.failures.isEmpty ? "passed" : "failed"
        try MeetingBrowserAudioHardwareTests.write(report, to: options.root.appendingPathComponent("outcome.json"))
        XCTAssertTrue(report.failures.isEmpty, report.failures.joined(separator: " "))
    }

    /// A final transcript marker alone cannot prove where its coarse utterance was captured.
    /// Only transcription of that phase's already validated, cropped PCM supplies this evidence.
    fileprivate static func verifyPhaseSpeech(
        samples: [[Float]], names: [String], expected: [String: String],
        transcribe: @MainActor ([Float]) async throws -> String
    ) async throws -> [String] {
        try MeetingBrowserAudioHardwareTests.require(samples.count == names.count && Set(names).count == names.count
            && names.allSatisfy { expected[$0]?.isEmpty == false }, "Phase PCM or expected-marker count is inconsistent.")
        var texts: [String] = []
        for index in samples.indices {
            let pcm = samples[index]
            try MeetingBrowserAudioHardwareTests.require((8_000...960_000).contains(pcm.count)
                && pcm.allSatisfy(\.isFinite), "Phase replay PCM is empty, oversized or non-finite.")
            let text = try await transcribe(pcm)
            let own = try XCTUnwrap(expected[names[index]])
            try MeetingBrowserAudioHardwareTests.require(text.localizedCaseInsensitiveContains(own)
                && names.filter { $0 != names[index] }.allSatisfy {
                    expected[$0].map { !text.localizedCaseInsensitiveContains($0) } ?? false
                },
                "\(names[index]) exact saved PCM lacks its own marker or contains another phase marker.")
            texts.append(text)
        }
        return texts
    }

    /// Use the shared store codec while retaining every date, timing and chunk field exactly.
    fileprivate static func tracksUsingStoreDatePrecision(_ tracks: [MeetingAudioTrack]) throws -> [MeetingAudioTrack] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = MeetingSessionDateCodec.encodingStrategy
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = MeetingSessionDateCodec.decodingStrategy
        return try decoder.decode([MeetingAudioTrack].self, from: encoder.encode(tracks))
    }

    /// The real coordinator owns an unstructured stop task. A deadline must shut down that
    /// owner before the task group joins, otherwise cancelling the wrapper can hang on inference.
    private static func coordinatorOperation(
        _ coordinator: MeetingSessionCoordinator, ownedTitle: String,
        operation: @escaping @MainActor @Sendable () async throws -> MeetingSession
    ) async throws -> MeetingSession {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: MeetingSession.self) { group in
                group.addTask { try await operation() }
                group.addTask {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                    await Self.shutdownOwnedCoordinator(coordinator, title: ownedTitle)
                    throw BrowserCaptureFailure(message: "Ordinary coordinator operation exceeded 60 seconds.")
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw CancellationError() }
                return result
            }
        } onCancel: {
            Task { @MainActor in await Self.shutdownOwnedCoordinator(coordinator, title: ownedTitle) }
        }
    }

    private static func shutdownOwnedCoordinator(_ coordinator: MeetingSessionCoordinator, title: String) async {
        if let active = coordinator.activeSession {
            guard active.title == title else { return }
        } else {
            guard !coordinator.hasPendingStart, coordinator.latestCompletedSession?.title == title else { return }
        }
        await coordinator.shutdownForTermination()
    }

    func testSystemAudioSurvivesExternalBrowserRestartWhenEnabled() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PICHI_SYSTEM_CAPTURE_CONSENT"] == "1" else {
            throw XCTSkip("Set PICHI_SYSTEM_CAPTURE_CONSENT=1 and explicit private ROOT/RUN_ID.")
        }
        let options = try SystemContinuityOptions(environment: environment)
        try options.prepareRoot()
        var capturedReport: SystemContinuityReport?
        do {
            try MeetingBrowserAudioHardwareTests.require(CGPreflightScreenCaptureAccess(), "System audio is not preflight-authorized.")
            try MeetingBrowserAudioHardwareTests.require(
                AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, "Microphone is not preflight-authorized."
            )
            let report = try await self.capture(options)
            capturedReport = report
            try MeetingBrowserAudioHardwareTests.write(report, to: options.root.appendingPathComponent("outcome.json"))
            XCTAssertTrue(report.failures.isEmpty, report.failures.joined(separator: " "))
        } catch {
            var report = capturedReport ?? SystemContinuityReport(runID: options.runID, status: "failed", failures: [])
            report.status = "failed"
            report.failures.append(error.localizedDescription)
            try? MeetingBrowserAudioHardwareTests.write(report, to: options.root.appendingPathComponent("outcome.json"))
            throw error
        }
    }

    private func capture(_ options: SystemContinuityOptions) async throws -> SystemContinuityReport {
        let microphone = try await MeetingCaptureSourceCatalog.defaultMicrophone()
        let configuration = MeetingCaptureConfiguration(
            mode: .onlineCall, title: "Synthetic system audio continuity", languageCode: "ru",
            application: nil, applicationAudioScope: .systemAudio, microphone: microphone
        )
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        var session = MeetingSession(configuration: configuration, timebase: MeetingTimebaseMetadata(
            startedHostTime: mach_absolute_time(), machTimebaseNumerator: timebase.numer,
            machTimebaseDenominator: timebase.denom, firstPresentationTime: nil
        ))
        let store = MeetingSessionStore(rootDirectory: options.root.appendingPathComponent("sessions"))
        try await store.create(session)
        let directory = try await store.sessionDirectory(for: session.id)
        let engine = MeetingCaptureEngine()
        let events = BrowserCaptureEvents()
        var protocolState = SystemContinuityProtocol(runID: options.runID)
        let immutableSession = session
        var start: MeetingCaptureStartResult?
        var stopped: MeetingCaptureStopResult?
        let captureStart = SystemContinuityProtocol.hostSeconds()
        do {
            let started = try await MeetingBrowserAudioHardwareTests.withDeadline(seconds: 12) {
                try await engine.start(session: immutableSession, configuration: configuration,
                                       sessionDirectory: directory, eventHandler: { events.record($0) })
            }
            start = started
            session.audioTracks = started.tracks
            session.state = .recording
            try await store.save(session)
            try MeetingBrowserAudioHardwareTests.write(
                SystemContinuityReady(runID: options.runID, sessionID: session.id,
                                      sessionDirectory: directory.path, captureStartHostSeconds: captureStart,
                                      readyHostSeconds: SystemContinuityProtocol.hostSeconds(),
                                      durationSeconds: options.durationSeconds),
                to: options.root.appendingPathComponent("capture-ready.json")
            )
            try await Self.waitForExternalPhases(options, protocolState: &protocolState)
            let sessionID = session.id
            let stop = try await MeetingBrowserAudioHardwareTests.withDeadline(seconds: 12) {
                try await engine.stop(sessionID: sessionID)
            }
            stopped = stop
            session.audioTracks = stop.tracks
            session.endedAt = stop.stoppedAt
            session.state = .interrupted // Capture probe does not claim meeting processing completed.
            session.recoveryResolvedAt = stop.stoppedAt
            session.events = events.interruptions()
            session.updatedAt = stop.stoppedAt
            try await store.save(session)
            await engine.shutdownForTermination()
        } catch {
            let failure = await Self.finalizeFailure(
                error, session: session, stopped: stopped, captureStarted: start != nil,
                engine: engine, store: store, events: events
            )
            return Self.report(
                session: failure.session, directory: directory, runID: options.runID,
                captureScope: start?.captureScope, protocolState: protocolState,
                events: events, failures: failure.failures, maximumCaptureDuration: options.durationSeconds
            )
        }
        var report = Self.report(
            session: session, directory: directory, runID: options.runID,
            captureScope: start?.captureScope, protocolState: protocolState, events: events, failures: [],
            maximumCaptureDuration: options.durationSeconds
        )
        do {
            let phaseSamples = try await Self.validateSavedPCM(
                session: session, directory: directory, protocolState: protocolState, report: &report,
                requiresEngineScope: true
            )
            if let modelDirectory = options.modelDirectory {
                let modelStore = PichiGigaAMModelStore(directory: modelDirectory)
                let fingerprint = try modelStore.installedModelFingerprint()
                let provider = PichiGigaAMProvider(modelStore: modelStore, expectedModelFingerprint: fingerprint)
                do {
                    try await MeetingBrowserAudioHardwareTests.withDeadline(seconds: 30) { @MainActor in try await provider.prepare() }
                    for index in report.phases.indices {
                        let samples = phaseSamples[index]
                        let text = try await MeetingBrowserAudioHardwareTests.withDeadline(seconds: 30) { @MainActor in
                            try await provider.transcribeFinal(samples).text
                        }
                        report.phases[index].speechText = text
                        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            report.failures.append("\(report.phases[index].phase.name) produced an empty transcript.")
                        }
                        if let expected = options.expectedText[report.phases[index].phase.name],
                           !text.localizedCaseInsensitiveContains(expected) {
                            report.failures.append("\(report.phases[index].phase.name) transcript lacks its distinct expected synthetic phrase.")
                        }
                    }
                    await provider.unloadModel()
                } catch is CancellationError {
                    await provider.unloadModel()
                    throw CancellationError()
                } catch {
                    await provider.unloadModel()
                    report.failures.append("Per-phase saved speech verification failed: \(error.localizedDescription)")
                }
            }
        } catch {
            // Post-capture decode/model failures must not replace finalized capture evidence.
            report.failures.append("Saved phase evidence verification failed: \(error.localizedDescription)")
        }
        report.status = report.failures.isEmpty ? "passed" : "failed"
        return report
    }

    private static func waitForExternalPhases(
        _ options: SystemContinuityOptions, protocolState: inout SystemContinuityProtocol,
        observeRecording: (Int) throws -> Void = { _ in }
    ) async throws {
        let deadline = SystemContinuityProtocol.hostSeconds() + options.durationSeconds
        while SystemContinuityProtocol.hostSeconds() < deadline {
            try Task.checkCancellation()
            try observeRecording(protocolState.sequence)
            let commandURL = options.root.appendingPathComponent("phase-command.json")
            if FileManager.default.fileExists(atPath: commandURL.path) {
                let handle = try FileHandle(forReadingFrom: commandURL)
                let data: Data
                do {
                    data = try handle.read(upToCount: 8193) ?? Data()
                    try handle.close()
                } catch {
                    try? handle.close()
                    throw error
                }
                try MeetingBrowserAudioHardwareTests.require(data.count <= 8192, "Phase command exceeded its size limit.")
                let command = try JSONDecoder().decode(SystemContinuityCommand.self, from: data)
                if command.sequence > protocolState.sequence {
                    let ack = try protocolState.accept(command, at: SystemContinuityProtocol.hostSeconds())
                    try observeRecording(protocolState.sequence)
                    try MeetingBrowserAudioHardwareTests.write(ack, to: options.root.appendingPathComponent("phase-ack.json"))
                } else {
                    try MeetingBrowserAudioHardwareTests.require(command.runID == options.runID, "Phase command has another run ID.")
                }
            }
            if protocolState.isComplete { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        try MeetingBrowserAudioHardwareTests.require(protocolState.isComplete, "External phase protocol did not complete before its deadline.")
    }

    private static func validateSavedPCM(
        session: MeetingSession, directory: URL, protocolState: SystemContinuityProtocol,
        report: inout SystemContinuityReport, requiresEngineScope: Bool
    ) async throws -> [[Float]] {
        if report.applicationAudioScope != "systemAudio" || report.capturedApplication != nil || (requiresEngineScope && report.captureScope != "systemAudio") {
            report.failures.append("Capture/session metadata did not identify the all-system source truthfully.")
        }
        if Set(report.tracks.map(\.kind)) != Set(["applicationAudio", "microphone"]) {
            report.failures.append("Capture did not preserve separate system and microphone tracks.")
        }
        for track in report.tracks where track.chunkCount == 0 || track.finalizedChunkCount != track.chunkCount
            || track.persistedBytes == 0 || track.decodedFrames == 0 || track.nonFiniteSamples != 0 {
            report.failures.append("\(track.kind) contains missing, unfinished, empty, or invalid PCM.")
        }
        let terminal: [MeetingInterruptionKind] = [.writerFailure, .diskExhausted, .permissionRevoked,
                                                   .captureStoppedUnexpectedly, .applicationExited, .microphoneDisconnected]
        for kind in terminal where report.events?.interruptionsByKind[kind.rawValue, default: 0] ?? 0 > 0 {
            report.failures.append("Capture emitted terminal interruption \(kind.rawValue).")
        }
        if report.events?.droppedInterruptionDetails ?? 0 > 0 { report.failures.append("Interruption evidence overflowed.") }
        let track = try XCTUnwrap(session.audioTracks.first { $0.kind == .applicationAudio })
        if track.sourceIdentifier != "system-audio" { report.failures.append("System track has an application-specific identifier.") }
        // Epoch clock resets can alter the writer's canonical PTS mapping. This probe deliberately
        // rejects ambiguous evidence instead of assigning old audio to a later external phase.
        if track.chunks.contains(where: { $0.discontinuities.contains { $0.kind == .clockDiscontinuity } }) {
            report.failures.append("Clock reset prevents unambiguous host-time phase matching in this probe.")
        }
        var phaseSamples: [[Float]] = []
        for phase in protocolState.phases {
            let saved = try await Self.samples(in: phase, track: track, directory: directory)
            let samples = saved.samples
            let metrics = SystemContinuityPhaseMetrics(phase: phase, samples: samples, chunkCount: saved.chunkCount)
            report.phases.append(metrics)
            phaseSamples.append(samples)
            if metrics.rms <= 0.001 || metrics.peak <= 0.01 || metrics.nonSilentSeconds < 0.5
                || metrics.nonFiniteSamples != 0 || metrics.decodedSeconds < 0.5 {
                report.failures.append("\(phase.name) has no valid speech signal in its own persisted system-audio time window.")
            }
        }
        return phaseSamples
    }

    /// Stop returns authoritative finalized tracks, including when runtime stop itself failed.
    /// Shutdown is always joined, but its Void result must never replace that stop evidence.
    fileprivate static func finalizeFailure(
        _ error: Error, session initialSession: MeetingSession, stopped: MeetingCaptureStopResult?,
        captureStarted: Bool, engine: any MeetingCaptureControlling,
        store: MeetingSessionStore, events: BrowserCaptureEvents
    ) async -> (session: MeetingSession, failures: [String]) {
        var session = initialSession
        var failures = [error.localizedDescription]
        var stop = stopped
        if case let MeetingCaptureError.captureStopFailed(_, partial) = error { stop = partial }
        if stop == nil {
            do {
                let sessionID = session.id
                stop = try await MeetingBrowserAudioHardwareTests.withDeadline(seconds: 12) {
                    try await engine.stop(sessionID: sessionID)
                }
            } catch {
                if case let MeetingCaptureError.captureStopFailed(_, partial) = error { stop = partial }
                if captureStarted || !Self.isNoActiveCapture(error) {
                    failures.append("Capture teardown failed: \(error.localizedDescription)")
                }
            }
        }
        await engine.shutdownForTermination()
        if let stop {
            session.audioTracks = stop.tracks
            session.endedAt = stop.stoppedAt
            session.recoveryResolvedAt = stop.stoppedAt
        } else {
            // A joined deadline can discard a completed stop value. Reconcile durable track
            // manifests through the existing store, rather than decoding a second JSON schema.
            do {
                if let recovered = try await store.load(id: session.id) {
                    session.audioTracks = recovered.audioTracks
                }
            } catch { failures.append("Finalized track reconciliation failed: \(error.localizedDescription)") }
            session.endedAt = Date()
        }
        session.timebase.firstPresentationTime = session.audioTracks.flatMap(\.chunks).map(\.presentationStart).min()
        session.state = .failed
        session.events = events.interruptions()
        session.updatedAt = session.endedAt ?? Date()
        do { try await store.save(session) }
        catch { failures.append("Failed capture session save failed: \(error.localizedDescription)") }
        return (session, failures)
    }

    private static func isNoActiveCapture(_ error: Error) -> Bool {
        if case MeetingCaptureError.noActiveCapture = error { return true }
        return false
    }

    fileprivate static func report(
        session: MeetingSession, directory: URL, runID: UUID, captureScope: MeetingCaptureScope?,
        protocolState: SystemContinuityProtocol, events: BrowserCaptureEvents?, failures: [String], maximumCaptureDuration: Double
    ) -> SystemContinuityReport {
        var report = SystemContinuityReport(runID: runID, status: "failed", failures: failures)
        report.sessionDirectory = directory.path
        report.sessionState = session.state.rawValue
        report.endedAt = session.endedAt
        report.applicationAudioScope = session.applicationAudioScope?.rawValue
        report.capturedApplication = session.capturedApplication?.bundleIdentifier
        report.captureScope = captureScope.map { String(describing: $0) }
        report.protocolComplete = protocolState.isComplete
        report.browserAbsentSeconds = protocolState.browserAbsentSeconds
        report.commands = protocolState.commands
        report.acknowledgements = protocolState.acknowledgements
        report.phaseWindows = protocolState.phases
        report.events = events?.summary()
        for track in session.audioTracks {
            do { report.tracks.append(try MeetingBrowserAudioHardwareTests.measure(track, in: directory, maximumCaptureDuration: maximumCaptureDuration)) }
            catch { report.failures.append("\(track.kind.rawValue) saved PCM measurement failed: \(error.localizedDescription)") }
        }
        return report
    }

    private static func samples(in phase: SystemContinuityPhase, track: MeetingAudioTrack, directory: URL) async throws -> (samples: [Float], chunkCount: Int) {
        var result: [Float] = []
        var contributingChunks = 0
        var lastEnd: Double?
        for chunk in track.chunks.sorted(by: { $0.presentationStart < $1.presentationStart }) {
            guard chunk.finalizationState == .finalized,
                  chunk.presentationEnd.seconds > phase.startHostSeconds,
                  chunk.presentationStart.seconds < phase.endHostSeconds else { continue }
            let reader = try LocalAPIAudioDecoder.ChunkReader(
                fileURL: directory.appendingPathComponent(chunk.relativeFilePath), chunkDurationSeconds: 5
            )
            var offset = 0
            let countBeforeChunk = result.count
            while true {
                try Task.checkCancellation()
                let values = try await reader.nextSamples()
                if values.isEmpty { break }
                let start = chunk.presentationStart.seconds + Double(offset) / 16_000
                let lower = max(0, Int(ceil((phase.startHostSeconds - start) * 16_000)))
                let upper = min(values.count, Int(ceil((phase.endHostSeconds - start) * 16_000)))
                if lower < upper {
                    let selectedStart = start + Double(lower) / 16_000
                    try MeetingBrowserAudioHardwareTests.require(
                        lastEnd.map { selectedStart >= $0 - 0.002 } ?? true, "Persisted phase PCM ranges overlap."
                    )
                    try MeetingBrowserAudioHardwareTests.require(result.count + upper - lower <= 16_000 * 60, "Phase PCM exceeded its 60-second bound.")
                    result.append(contentsOf: values[lower..<upper])
                    lastEnd = start + Double(upper) / 16_000
                }
                offset += values.count
            }
            if result.count > countBeforeChunk { contributingChunks += 1 }
        }
        return (result, contributingChunks)
    }
}

private struct SystemContinuityOptions {
    let root: URL
    let runID: UUID
    let durationSeconds: Double
    let modelDirectory: URL?
    let expectedText: [String: String]

    init(environment: [String: String], requiresModelDirectoryForExpectedText: Bool = true) throws {
        let prefix = "PICHI_SYSTEM_CAPTURE_"
        guard let path = environment[prefix + "ROOT"], path.hasPrefix("/"),
              let rawID = environment[prefix + "RUN_ID"], let runID = UUID(uuidString: rawID) else {
            throw BrowserCaptureFailure(message: "System capture requires absolute ROOT and fresh UUID RUN_ID.")
        }
        self.root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let privateAssets = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("private_assets").standardizedFileURL.resolvingSymlinksInPath()
        guard self.root.path.hasPrefix(privateAssets.path + "/") else {
            throw BrowserCaptureFailure(message: "ROOT must be a child of this worktree's ignored private_assets.")
        }
        self.runID = runID
        guard let duration = Double(environment[prefix + "DURATION_SECONDS"] ?? "100"),
              duration.isFinite, (60...180).contains(duration) else {
            throw BrowserCaptureFailure(message: "System capture duration must be in 60...180 seconds.")
        }
        self.durationSeconds = duration
        if let path = environment[prefix + "GIGAAM_MODEL_DIR"], !path.isEmpty {
            guard path.hasPrefix("/") else { throw BrowserCaptureFailure(message: "Model directory must be an absolute installed path.") }
            self.modelDirectory = URL(fileURLWithPath: path, isDirectory: true)
        } else { self.modelDirectory = nil }
        if let json = environment[prefix + "EXPECTED_TEXT_JSON"] {
            guard json.utf8.count <= 8192 else { throw BrowserCaptureFailure(message: "Expected phrase map exceeded its size limit.") }
            self.expectedText = try JSONDecoder().decode([String: String].self, from: Data(json.utf8))
            guard (!requiresModelDirectoryForExpectedText || self.modelDirectory != nil), Set(self.expectedText.keys) == Set(SystemContinuityProtocol.phaseNames),
                  self.expectedText.values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                  Set(self.expectedText.values.map { $0.lowercased() }).count == 3 else {
                throw BrowserCaptureFailure(message: "Expected text requires the requested installed model and three distinct nonempty phase phrases.")
            }
        } else { self.expectedText = [:] }
    }

    func prepareRoot() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try manager.attributesOfItem(atPath: self.root.path)
        guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
              let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue, permissions & 0o077 == 0 else {
            throw BrowserCaptureFailure(message: "Private ROOT must be owned by this user with mode 0700.")
        }
        for name in ["capture-ready.json", "phase-command.json", "phase-ack.json", "outcome.json", "sessions"] {
            guard !manager.fileExists(atPath: self.root.appendingPathComponent(name).path) else {
                throw BrowserCaptureFailure(message: "ROOT contains stale run artifacts; use a fresh directory.")
            }
        }
    }
}

private struct SystemContinuityReady: Encodable {
    let runID: UUID
    let sessionID: UUID
    let sessionDirectory: String
    let captureStartHostSeconds: Double
    let readyHostSeconds: Double
    let durationSeconds: Double
}

fileprivate struct SystemContinuityCommand: Codable {
    let runID: UUID
    let sequence: Int
    let action: String
    let phase: String?
    let bundleID: String?
    let executablePath: String?
    let processID: Int32?
}

fileprivate struct SystemContinuityAck: Codable {
    let runID: UUID
    let sequence: Int
    let machAbsoluteHostSeconds: Double
}

fileprivate struct SystemContinuityPhase: Encodable {
    let name: String
    let bundleID: String?
    let executablePath: String
    let processID: Int32
    let startHostSeconds: Double
    var endHostSeconds: Double

    func containsTranscript(start: Double, end: Double, origin: Double) -> Bool {
        start.isFinite && end.isFinite && origin.isFinite && end > start
            && start + origin >= self.startHostSeconds && end + origin <= self.endHostSeconds
    }
}

/// Only external phase evidence is trusted here, never inferred from RMS or ASR timing.
fileprivate struct SystemContinuityProtocol {
    static let phaseNames = ["browserBefore", "secondSource", "browserAfter"]
    let runID: UUID
    private(set) var sequence = 0
    private(set) var commands: [SystemContinuityCommand] = []
    private(set) var acknowledgements: [SystemContinuityAck] = []
    private(set) var phases: [SystemContinuityPhase] = []
    private var browserExitedAt: Double?
    private var browserRestartedAt: Double?
    private var restartedPID: Int32?

    init(runID: UUID) {
        self.runID = runID
    }

    var isComplete: Bool { self.sequence == 8 }
    var browserAbsentSeconds: Double? {
        guard let browserExitedAt, let browserRestartedAt else { return nil }
        return browserRestartedAt - browserExitedAt
    }

    static func hostSeconds() -> Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(mach_absolute_time()) * Double(info.numer) / Double(info.denom) / 1_000_000_000
    }

    mutating func accept(_ command: SystemContinuityCommand, at now: Double) throws -> SystemContinuityAck {
        func require(_ value: Bool, _ message: String) throws {
            try MeetingBrowserAudioHardwareTests.require(value, message)
        }
        try require(command.runID == self.runID && command.sequence == self.sequence + 1 && now.isFinite,
                    "Phase command has another run ID, skipped sequence, or invalid host clock.")
        let expectedActions = ["begin", "end", "browserExited", "begin", "end", "browserRestarted", "begin", "end"]
        try require((1...8).contains(command.sequence) && command.action == expectedActions[command.sequence - 1], "Unexpected phase action.")
        let phaseIndices = [1: 0, 2: 0, 4: 1, 5: 1, 7: 2, 8: 2]
        if let index = phaseIndices[command.sequence] {
            try require(command.phase == Self.phaseNames[index], "Unexpected phase name.")
            if command.action == "begin" {
                guard let pid = command.processID, pid > 0, let path = command.executablePath, path.hasPrefix("/") else {
                    throw BrowserCaptureFailure(message: "Phase begin needs the actual owned process PID and executable path.")
                }
                if index == 0 { try require(command.bundleID?.isEmpty == false, "Browser phase needs its actual bundle ID.") }
                if index == 1 {
                    try require(pid != self.phases[0].processID && path != self.phases[0].executablePath,
                                "Second source must be a distinct external audio executable/process.")
                }
                if index == 2 {
                    try require(pid == self.restartedPID && command.bundleID == self.phases[0].bundleID
                                && path == self.phases[0].executablePath, "Final phase must use the restarted browser identity.")
                }
                self.phases.append(SystemContinuityPhase(name: Self.phaseNames[index], bundleID: command.bundleID,
                                                         executablePath: path, processID: pid,
                                                         startHostSeconds: now, endHostSeconds: now))
            } else {
                try require(now > self.phases[index].startHostSeconds && now - self.phases[index].startHostSeconds <= 60,
                            "Phase duration must be positive and at most 60 seconds.")
                self.phases[index].endHostSeconds = now
            }
        } else if command.action == "browserExited" {
            try require(command.processID == self.phases[0].processID, "Exit marker does not match the first browser PID.")
            self.browserExitedAt = now
        } else {
            guard let pid = command.processID, pid > 0, let exited = self.browserExitedAt else {
                throw BrowserCaptureFailure(message: "Restart marker needs the actual new owned browser PID.")
            }
            try require(pid != self.phases[0].processID && command.bundleID == self.phases[0].bundleID && now - exited >= 8,
                        "Browser restart needs a changed PID, matching bundle, and at least eight seconds absent.")
            self.browserRestartedAt = now
            self.restartedPID = pid
        }
        self.sequence = command.sequence
        self.commands.append(command)
        let acknowledgement = SystemContinuityAck(runID: self.runID, sequence: self.sequence, machAbsoluteHostSeconds: now)
        self.acknowledgements.append(acknowledgement)
        return acknowledgement
    }
}

fileprivate struct SystemContinuityPhaseMetrics: Encodable {
    let phase: SystemContinuityPhase
    let decodedSeconds: Double
    let chunkCount: Int
    let decodedSamples: Int
    let nonSilentSeconds: Double
    let nonFiniteSamples: Int
    let rms: Double
    let peak: Double
    var speechText: String?

    init(phase: SystemContinuityPhase, samples: [Float], chunkCount: Int) {
        self.phase = phase
        self.chunkCount = chunkCount
        self.decodedSamples = samples.count
        self.decodedSeconds = Double(samples.count) / 16_000
        self.nonSilentSeconds = Double(samples.filter { $0.isFinite && abs($0) > 0.0001 }.count) / 16_000
        self.nonFiniteSamples = samples.filter { !$0.isFinite }.count
        var squaredSum = 0.0
        var peak = 0.0
        var finiteCount = 0
        for value in samples where value.isFinite {
            let sample = Double(value)
            squaredSum += sample * sample
            peak = max(peak, abs(sample))
            finiteCount += 1
        }
        self.rms = finiteCount > 0 ? sqrt(squaredSum / Double(finiteCount)) : 0
        self.peak = peak
    }
}

fileprivate struct SystemContinuityReport: Encodable {
    let runID: UUID
    var status: String
    var failures: [String]
    var sessionDirectory: String?
    var sessionState: String?
    var endedAt: Date?
    var protocolComplete = false
    var phaseWindows: [SystemContinuityPhase] = []
    var applicationAudioScope: String?
    var capturedApplication: String?
    var captureScope: String?
    var browserAbsentSeconds: Double?
    var commands: [SystemContinuityCommand] = []
    var acknowledgements: [SystemContinuityAck] = []
    var tracks: [BrowserCaptureTrackMetrics] = []
    var phases: [SystemContinuityPhaseMetrics] = []
    var events: BrowserCaptureEventSummary?
    var probeScope: String?
    var recordingSessionID: UUID?
    var selectedSpeechModelID: String?
    var recordingBackendID: String?
    var recordingASRArtifactFingerprint: String?
    var coordinatorObservations: [SystemContinuityCoordinatorObservation] = []
    var finalProcessingCompleted: Bool?
    var transcriptCoverageGaps: [MeetingTranscriptCoverageGap] = []
    var normalFinalTranscriptMarkers: [String: Bool] = [:]
    var normalFinalCrossingSegmentCounts: [String: Int] = [:]
    var phaseASREvidenceSource: String?
    var phaseReplayArtifactFingerprint: String?
}

fileprivate struct SystemContinuityCoordinatorObservation: Encodable {
    let sequence: Int
    let sessionID: UUID
    let state: String
    let hostSeconds: Double
}

/// Pure operator-evidence validation. No microphone, browser, permission, or model dependency.
final class MeetingSystemAudioContinuityProtocolTests: XCTestCase {
    func testTranscriptSpanningDistinctPhasesCannotSupplyPhaseLocalASREvidence() {
        let phases = (0..<3).map { index in
            SystemContinuityPhase(name: SystemContinuityProtocol.phaseNames[index], bundleID: nil,
                executablePath: "/synthetic/source", processID: 1,
                startHostSeconds: 100 + Double(index * 10), endHostSeconds: 105 + Double(index * 10))
        }
        // Even if this one segment contains every expected phrase, its envelope cannot locate
        // any phrase in one phase. Canonical relative timing must use the same strict rule.
        XCTAssertTrue(phases.allSatisfy { !$0.containsTranscript(start: 99, end: 126, origin: 0) })
        XCTAssertTrue(phases.allSatisfy { !$0.containsTranscript(start: 0, end: 27, origin: 99) })
        XCTAssertTrue(phases[0].containsTranscript(start: 1, end: 4, origin: 100))
        XCTAssertFalse(phases[1].containsTranscript(start: 1, end: 4, origin: 100))
    }

    func testNewProtocolHasNoAcceptedOperatorEvidence() {
        let runID = UUID()
        let state = SystemContinuityProtocol(runID: runID)

        XCTAssertEqual(state.runID, runID)
        XCTAssertEqual(state.sequence, 0)
        XCTAssertTrue(state.commands.isEmpty)
        XCTAssertTrue(state.acknowledgements.isEmpty)
        XCTAssertTrue(state.phases.isEmpty)
        XCTAssertFalse(state.isComplete)
        XCTAssertNil(state.browserAbsentSeconds)
    }

    func testValidPhasesRequireDistinctProcessAndEightSecondAbsence() throws {
        var state = SystemContinuityProtocol(runID: UUID())
        let commands = self.commands(runID: state.runID)
        for (command, seconds) in zip(commands, [10.0, 15, 16, 17, 22, 25, 26, 31]) {
            let ack = try state.accept(command, at: seconds)
            XCTAssertEqual(ack.sequence, command.sequence)
            XCTAssertEqual(ack.machAbsoluteHostSeconds, seconds)
        }
        XCTAssertTrue(state.isComplete)
        XCTAssertEqual(state.browserAbsentSeconds, 9)
        XCTAssertEqual(state.phases.map(\.name), ["browserBefore", "secondSource", "browserAfter"])
        XCTAssertNil(state.phases[1].bundleID)
        XCTAssertEqual(state.phases[1].executablePath, "/usr/bin/afplay")
        XCTAssertEqual(state.phases[2].processID, 303)
        XCTAssertEqual(state.phases.map { $0.endHostSeconds - $0.startHostSeconds }, [5, 5, 5])
    }

    func testRejectsWrongRunSkippedSequenceAndOutOfOrderPhase() {
        var state = SystemContinuityProtocol(runID: UUID())
        let commands = self.commands(runID: state.runID)
        XCTAssertThrowsError(try state.accept(self.commands(runID: UUID())[0], at: 10))
        XCTAssertThrowsError(try state.accept(commands[1], at: 10))
        XCTAssertThrowsError(try state.accept(SystemContinuityCommand(
            runID: state.runID, sequence: 1, action: "begin", phase: "browserAfter",
            bundleID: "test.browser", executablePath: "/Applications/Test Browser.app/Contents/MacOS/Test Browser", processID: 101
        ), at: 10))
        XCTAssertEqual(state.sequence, 0)
    }

    func testRejectsOldBrowserPIDAndTooShortAbsenceAtRestart() throws {
        var state = SystemContinuityProtocol(runID: UUID())
        let commands = self.commands(runID: state.runID)
        for (command, seconds) in zip(commands.prefix(5), [10.0, 11, 12, 13, 14]) {
            _ = try state.accept(command, at: seconds)
        }
        XCTAssertThrowsError(try state.accept(commands[5], at: 19.99))
        XCTAssertThrowsError(try state.accept(SystemContinuityCommand(
            runID: state.runID, sequence: 6, action: "browserRestarted", phase: nil,
            bundleID: "test.browser", executablePath: nil, processID: 101
        ), at: 21))
        XCTAssertEqual(state.sequence, 5)
        _ = try state.accept(commands[5], at: 21)
    }

    func testRejectsSameExecutableAsSecondSource() throws {
        var state = SystemContinuityProtocol(runID: UUID())
        let commands = self.commands(runID: state.runID)
        for (command, seconds) in zip(commands.prefix(3), [10.0, 11, 12]) {
            _ = try state.accept(command, at: seconds)
        }
        XCTAssertThrowsError(try state.accept(SystemContinuityCommand(
            runID: state.runID, sequence: 4, action: "begin", phase: "secondSource", bundleID: "test.browser",
            executablePath: commands[0].executablePath, processID: 222
        ), at: 13))
        XCTAssertEqual(state.sequence, 3)
    }

    private func commands(runID: UUID) -> [SystemContinuityCommand] {
        let browserPath = "/Applications/Test Browser.app/Contents/MacOS/Test Browser"
        return [
            SystemContinuityCommand(runID: runID, sequence: 1, action: "begin", phase: "browserBefore", bundleID: "test.browser", executablePath: browserPath, processID: 101),
            SystemContinuityCommand(runID: runID, sequence: 2, action: "end", phase: "browserBefore", bundleID: nil, executablePath: nil, processID: nil),
            SystemContinuityCommand(runID: runID, sequence: 3, action: "browserExited", phase: nil, bundleID: nil, executablePath: nil, processID: 101),
            SystemContinuityCommand(runID: runID, sequence: 4, action: "begin", phase: "secondSource", bundleID: nil, executablePath: "/usr/bin/afplay", processID: 202),
            SystemContinuityCommand(runID: runID, sequence: 5, action: "end", phase: "secondSource", bundleID: nil, executablePath: nil, processID: nil),
            SystemContinuityCommand(runID: runID, sequence: 6, action: "browserRestarted", phase: nil, bundleID: "test.browser", executablePath: nil, processID: 303),
            SystemContinuityCommand(runID: runID, sequence: 7, action: "begin", phase: "browserAfter", bundleID: "test.browser", executablePath: browserPath, processID: 303),
            SystemContinuityCommand(runID: runID, sequence: 8, action: "end", phase: "browserAfter", bundleID: nil, executablePath: nil, processID: nil),
        ]
    }
}

/// Synthetic persisted PCM plus a capture-controller seam verifies failure evidence without
/// opening audio devices, loading a model, or depending on an interactive browser.
@MainActor
final class MeetingSystemAudioContinuityFailureEvidenceTests: XCTestCase {
    func testPhasePCMReplayRequiresItsOwnSamplesAndRejectsCorruptionOrAnotherPhaseMarker() async throws {
        let names = SystemContinuityProtocol.phaseNames
        let markers = ["orange garden", "purple mountain", "green river"]
        let expected = Dictionary(uniqueKeysWithValues: zip(names, markers))
        let pcm = (1...3).map { [Float](repeating: Float($0), count: 8_000) }
        let recognize: @MainActor ([Float]) async throws -> String = { samples in
            let index = Int(samples[0]) - 1
            return markers[index]
        }
        let accepted = try await MeetingSystemAudioContinuityHardwareTests.verifyPhaseSpeech(
            samples: pcm, names: names, expected: expected, transcribe: recognize
        )
        XCTAssertEqual(accepted, markers)

        var switched = pcm
        switched.swapAt(0, 1)
        do {
            _ = try await MeetingSystemAudioContinuityHardwareTests.verifyPhaseSpeech(
                samples: switched, names: names, expected: expected, transcribe: recognize
            )
            XCTFail("Another phase's PCM must not supply the requested marker.")
        } catch {}
        var corrupt = pcm
        corrupt[0][0] = .nan
        do {
            _ = try await MeetingSystemAudioContinuityHardwareTests.verifyPhaseSpeech(
                samples: corrupt, names: names, expected: expected
            ) { _ in XCTFail("Corrupt PCM must be rejected before ASR."); return markers[0] }
            XCTFail("Non-finite PCM must fail phase verification.")
        } catch {}
        do {
            _ = try await MeetingSystemAudioContinuityHardwareTests.verifyPhaseSpeech(
                samples: pcm, names: names, expected: expected
            ) { _ in markers.joined(separator: " ") }
            XCTFail("One coarse transcript containing every marker must not prove three phases.")
        } catch {}
    }

    func testCompletedTrackComparisonPreservesExactDatesWithoutIgnoringTrackChanges() async throws {
        let fixture = try await self.fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory.deletingLastPathComponent().deletingLastPathComponent()) }
        var completed = fixture.session
        completed.state = .completed
        completed.endedAt = fixture.stop.stoppedAt
        completed.audioTracks = fixture.stop.tracks
        for index in completed.audioTracks.indices {
            completed.audioTracks[index].health.lastSampleAt = Date(timeIntervalSince1970: 1_700_000_000.375)
        }
        try await fixture.store.save(completed)
        let saved = try await fixture.store.load(id: completed.id)
        let persisted = try XCTUnwrap(saved)
        XCTAssertEqual(persisted.audioTracks, completed.audioTracks, "New manifests preserve fractional track dates exactly.")
        let expected = try MeetingSystemAudioContinuityHardwareTests.tracksUsingStoreDatePrecision(completed.audioTracks)
        XCTAssertEqual(persisted.audioTracks, expected)

        var changedChunk = persisted.audioTracks
        changedChunk[0].chunks[0].byteCount += 1
        XCTAssertNotEqual(changedChunk, expected, "A persisted chunk change must still fail comparison.")
        var changedDate = persisted.audioTracks
        changedDate[0].health.lastSampleAt = try XCTUnwrap(changedDate[0].health.lastSampleAt).addingTimeInterval(0.125)
        XCTAssertNotEqual(changedDate, expected, "A subsecond date change must still fail comparison.")
    }

    func testLateFirstPhaseRetainsFinalizedCaptureAndAcceptedProtocolEvidence() async throws {
        let fixture = try await self.fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory.deletingLastPathComponent().deletingLastPathComponent()) }
        var protocolState = SystemContinuityProtocol(runID: UUID())
        _ = try protocolState.accept(self.begin(runID: protocolState.runID), at: 100)
        let end = SystemContinuityCommand(runID: protocolState.runID, sequence: 2, action: "end",
                                          phase: "browserBefore", bundleID: nil, executablePath: nil, processID: nil)
        let primary: Error
        do {
            _ = try protocolState.accept(end, at: 160.01)
            return XCTFail("A late first phase must remain a failed protocol.")
        } catch { primary = error }
        let events = BrowserCaptureEvents()
        events.record(.interrupted(kind: .sourceLost, trackID: fixture.stop.tracks[0].id, detail: nil))
        events.record(.chunkFinalized(trackID: fixture.stop.tracks[0].id,
                                      chunk: fixture.stop.tracks[0].chunks[0],
                                      format: MeetingAudioFormat(codec: "pcm", sampleRate: 16_000, channelCount: 1, bitRate: nil)))
        let engine = ContinuityEvidenceCaptureController(outcome: .stopped(fixture.stop))
        let failure = await MeetingSystemAudioContinuityHardwareTests.finalizeFailure(
            primary, session: fixture.session, stopped: nil, captureStarted: true,
            engine: engine, store: fixture.store, events: events
        )
        let report = MeetingSystemAudioContinuityHardwareTests.report(
            session: failure.session, directory: fixture.directory, runID: protocolState.runID,
            captureScope: .systemAudio, protocolState: protocolState, events: events, failures: failure.failures, maximumCaptureDuration: 100
        )
        XCTAssertEqual(report.status, "failed")
        XCTAssertFalse(report.protocolComplete)
        XCTAssertEqual(report.failures.first, primary.localizedDescription)
        XCTAssertEqual(report.commands.map(\.sequence), [1])
        XCTAssertEqual(report.acknowledgements.map(\.sequence), [1])
        XCTAssertEqual(report.phaseWindows.count, 1)
        XCTAssertEqual(report.phaseWindows[0].startHostSeconds, report.phaseWindows[0].endHostSeconds)
        XCTAssertTrue(report.phases.isEmpty, "An unclosed phase must not masquerade as verified speech.")
        XCTAssertEqual(report.events?.finalizedChunkEvents, 1)
        XCTAssertEqual(report.events?.interruptionsByKind["sourceLost"], 1)
        XCTAssertEqual(report.sessionState, "failed")
        XCTAssertEqual(report.endedAt, fixture.stop.stoppedAt)
        XCTAssertEqual(report.applicationAudioScope, "systemAudio")
        XCTAssertNil(report.capturedApplication)
        XCTAssertEqual(report.captureScope, "systemAudio")
        XCTAssertEqual(report.tracks.count, 2)
        let encodedReport = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any]
        XCTAssertEqual((encodedReport?["commands"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((encodedReport?["phaseWindows"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(encodedReport?["protocolComplete"] as? Bool, false)
        XCTAssertTrue(report.tracks.allSatisfy { $0.finalizedChunkCount == 1 && $0.decodedFrames == 1600 && $0.rms > 0.1 })
        let loaded = try await fixture.store.load(id: fixture.session.id)
        let saved = try XCTUnwrap(loaded)
        XCTAssertEqual(saved.state, .failed)
        XCTAssertEqual(saved.audioTracks, fixture.stop.tracks)
        XCTAssertEqual(saved.endedAt, fixture.stop.stoppedAt)
        XCTAssertEqual(saved.events.count, 1)
        let calls = await engine.calls()
        XCTAssertEqual(calls, ["stop", "shutdown"])
    }

    func testTeardownFailureRetainsPartialStopAndOriginalFailure() async throws {
        let fixture = try await self.fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory.deletingLastPathComponent().deletingLastPathComponent()) }
        let engine = ContinuityEvidenceCaptureController(outcome: .partial(fixture.stop))
        let primary = BrowserCaptureFailure(message: "operator protocol failed")
        let failure = await MeetingSystemAudioContinuityHardwareTests.finalizeFailure(
            primary, session: fixture.session, stopped: nil, captureStarted: true,
            engine: engine, store: fixture.store, events: BrowserCaptureEvents()
        )
        XCTAssertEqual(failure.failures.count, 2)
        XCTAssertEqual(failure.failures.first, primary.localizedDescription)
        XCTAssertTrue(failure.failures[1].contains("synthetic runtime stop failure"))
        XCTAssertEqual(failure.session.audioTracks, fixture.stop.tracks)
        XCTAssertEqual(failure.session.endedAt, fixture.stop.stoppedAt)
        XCTAssertEqual(failure.session.recoveryResolvedAt, fixture.stop.stoppedAt)
        let calls = await engine.calls()
        XCTAssertEqual(calls, ["stop", "shutdown"])
    }

    func testAlreadyReturnedPartialStopIsNotReplacedByNoActiveCapture() async throws {
        let fixture = try await self.fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory.deletingLastPathComponent().deletingLastPathComponent()) }
        let engine = ContinuityEvidenceCaptureController(outcome: .noActive)
        let primary = MeetingCaptureError.captureStopFailed("synthetic runtime stop failure", partialResult: fixture.stop)
        let failure = await MeetingSystemAudioContinuityHardwareTests.finalizeFailure(
            primary, session: fixture.session, stopped: nil, captureStarted: true,
            engine: engine, store: fixture.store, events: BrowserCaptureEvents()
        )
        XCTAssertEqual(failure.failures, [primary.localizedDescription])
        XCTAssertEqual(failure.session.audioTracks, fixture.stop.tracks)
        let calls = await engine.calls()
        XCTAssertEqual(calls, ["shutdown"])
    }

    func testFailureAfterSuccessfulStopKeepsReturnedTracksWithoutStoppingAgain() async throws {
        let fixture = try await self.fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory.deletingLastPathComponent().deletingLastPathComponent()) }
        let engine = ContinuityEvidenceCaptureController(outcome: .noActive)
        let primary = BrowserCaptureFailure(message: "synthetic session save failed after stop")
        let failure = await MeetingSystemAudioContinuityHardwareTests.finalizeFailure(
            primary, session: fixture.session, stopped: fixture.stop, captureStarted: true,
            engine: engine, store: fixture.store, events: BrowserCaptureEvents()
        )
        XCTAssertEqual(failure.failures, [primary.localizedDescription])
        XCTAssertEqual(failure.session.audioTracks, fixture.stop.tracks)
        XCTAssertEqual(failure.session.endedAt, fixture.stop.stoppedAt)
        let calls = await engine.calls()
        XCTAssertEqual(calls, ["shutdown"])
    }

    func testNoReturnedStopReconcilesDurableManifestAfterJoinedShutdown() async throws {
        let fixture = try await self.fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory.deletingLastPathComponent().deletingLastPathComponent()) }
        for track in fixture.stop.tracks {
            try MeetingBrowserAudioHardwareTests.write(track, to: fixture.directory.appendingPathComponent("tracks/" + track.kind.rawValue + "/track.json"))
        }
        let engine = ContinuityEvidenceCaptureController(outcome: .noActive)
        let failure = await MeetingSystemAudioContinuityHardwareTests.finalizeFailure(
            BrowserCaptureFailure(message: "stop deadline elapsed"), session: fixture.session,
            stopped: nil, captureStarted: true, engine: engine, store: fixture.store, events: BrowserCaptureEvents()
        )
        XCTAssertEqual(failure.failures.count, 2, "Missing stop result must remain visible even when disk PCM is recoverable.")
        XCTAssertEqual(failure.session.audioTracks, fixture.stop.tracks.sorted { $0.kind.rawValue < $1.kind.rawValue })
        XCTAssertNotNil(failure.session.endedAt)
        XCTAssertEqual(failure.session.timebase.firstPresentationTime, fixture.stop.tracks[0].chunks[0].presentationStart)
        let calls = await engine.calls()
        XCTAssertEqual(calls, ["stop", "shutdown"])
    }

    func testStartupFailureStillJoinsShutdownWithoutInventingStopFailure() async throws {
        let fixture = try await self.fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory.deletingLastPathComponent().deletingLastPathComponent()) }
        var session = fixture.session
        session.audioTracks = []
        session.state = .preparing
        try await fixture.store.save(session)
        let engine = ContinuityEvidenceCaptureController(outcome: .noActive)
        let primary = BrowserCaptureFailure(message: "synthetic start failed")
        let failure = await MeetingSystemAudioContinuityHardwareTests.finalizeFailure(
            primary, session: session, stopped: nil, captureStarted: false,
            engine: engine, store: fixture.store, events: BrowserCaptureEvents()
        )
        XCTAssertEqual(failure.failures, [primary.localizedDescription])
        XCTAssertTrue(failure.session.audioTracks.isEmpty)
        XCTAssertEqual(failure.session.state, .failed)
        let calls = await engine.calls()
        XCTAssertEqual(calls, ["stop", "shutdown"])
    }

    private func begin(runID: UUID) -> SystemContinuityCommand {
        SystemContinuityCommand(runID: runID, sequence: 1, action: "begin", phase: "browserBefore",
                                bundleID: "test.browser", executablePath: "/synthetic/browser", processID: 101)
    }

    private func fixture() async throws -> (session: MeetingSession, stop: MeetingCaptureStopResult, store: MeetingSessionStore, directory: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ContinuityEvidence-" + UUID().uuidString)
        let store = MeetingSessionStore(rootDirectory: root.appendingPathComponent("sessions"))
        let timebase = MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1,
                                               machTimebaseDenominator: 1, firstPresentationTime: nil)
        var session = MeetingSession(configuration: MeetingCaptureConfiguration(
            mode: .onlineCall, title: "Synthetic failure evidence", languageCode: "ru", application: nil,
            applicationAudioScope: .systemAudio,
            microphone: MeetingMicrophoneIdentity(captureDeviceID: "synthetic-microphone", displayName: "Synthetic microphone")
        ), timebase: timebase)
        session.audioTracks = [.applicationAudio, .microphone].map { kind in
            MeetingAudioTrack(id: UUID(), kind: kind, sourceIdentifier: kind == .applicationAudio ? "system-audio" : "synthetic-microphone",
                              sourceDisplayName: kind.rawValue, format: nil, timebase: timebase, health: .waiting, chunks: [])
        }
        session.state = .recording
        try await store.create(session)
        let directory = try await store.sessionDirectory(for: session.id)
        var tracks = session.audioTracks
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        for index in tracks.indices {
            let path = "tracks/" + tracks[index].kind.rawValue + "/chunk_0.caf"
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600))
                buffer.frameLength = 1600
                let samples = try XCTUnwrap(buffer.floatChannelData)[0]
                for frame in 0..<1600 { samples[frame] = frame % 2 == 0 ? 0.25 : -0.25 }
                try file.write(from: buffer)
            }
            let bytes = try XCTUnwrap((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value)
            let digest = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            tracks[index].chunks = [MeetingAudioChunk(id: UUID(), sequence: 0, relativeFilePath: path,
                presentationStart: MeetingMediaTime(value: 100, timescale: 1),
                presentationEnd: MeetingMediaTime(value: 1001, timescale: 10), discontinuities: [],
                sha256: digest, byteCount: bytes, finalizationState: .finalized)]
        }
        return (session, MeetingCaptureStopResult(tracks: tracks, stoppedAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) + 1)), store, directory)
    }
}

private actor ContinuityEvidenceCaptureController: MeetingCaptureControlling {
    enum Outcome: Sendable {
        case stopped(MeetingCaptureStopResult)
        case partial(MeetingCaptureStopResult)
        case noActive
    }
    let outcome: Outcome
    private var invocationOrder: [String] = []
    init(outcome: Outcome) { self.outcome = outcome }
    func preflightPermissions() async throws { throw BrowserCaptureFailure(message: "Failure evidence tests must not request permissions.") }
    func start(session: MeetingSession, configuration: MeetingCaptureConfiguration, sessionDirectory: URL,
               eventHandler: @escaping @Sendable (MeetingCaptureEvent) -> Void,
               liveAudioHandler: (@Sendable (MeetingAudioTrackKind, CMSampleBuffer) -> Void)?) async throws -> MeetingCaptureStartResult {
        throw BrowserCaptureFailure(message: "Failure evidence tests must not start hardware capture.")
    }
    func stop(sessionID: MeetingSessionID) async throws -> MeetingCaptureStopResult {
        self.invocationOrder.append("stop")
        switch self.outcome {
        case let .stopped(result): return result
        case let .partial(result): throw MeetingCaptureError.captureStopFailed("synthetic runtime stop failure", partialResult: result)
        case .noActive: throw MeetingCaptureError.noActiveCapture
        }
    }
    func shutdownForTermination() async { self.invocationOrder.append("shutdown") }
    func calls() -> [String] { self.invocationOrder }
}

/// Decoder bounds follow persisted chunk timing and the configured probe bound, not the
/// writer's rotation target. All fixtures are synthetic files, with no device/model access.
final class MeetingBrowserAudioMeasurementTests: XCTestCase {
    func testPacketCrossingSixtySecondTargetAcceptsThirtyTwoExtraFramesWhenManifestAgrees() throws {
        let frames: Int64 = 60 * 48_000 + 32
        let fixture = try self.fixture(frames: frames, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let duration = fixture.track.chunks[0].presentationEnd.seconds - fixture.track.chunks[0].presentationStart.seconds
        XCTAssertGreaterThan((duration - 60) * 48_000, 31)
        let metrics = try MeetingBrowserAudioHardwareTests.measure(fixture.track, in: fixture.directory, maximumCaptureDuration: 100)
        XCTAssertEqual(metrics.decodedFrames, frames)
        XCTAssertEqual(metrics.finalizedChunkCount, 1)
        XCTAssertEqual(metrics.nonFiniteSamples, 0)
        XCTAssertEqual(metrics.rms, 0.25, accuracy: 0.0001)
    }

    func testFileAndDeclaredDurationMustRemainWithinConfiguredHardBound() throws {
        let fixture = try self.fixture(frames: 6 * 16_000, sampleRate: 16_000)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        XCTAssertThrowsError(try MeetingBrowserAudioHardwareTests.measure(fixture.track, in: fixture.directory, maximumCaptureDuration: 5))
        XCTAssertThrowsError(try MeetingBrowserAudioHardwareTests.measure(fixture.track, in: fixture.directory, maximumCaptureDuration: .infinity))
        XCTAssertThrowsError(try MeetingBrowserAudioHardwareTests.measure(fixture.track, in: fixture.directory, maximumCaptureDuration: 181))
        var tooLongManifest = fixture.track
        tooLongManifest.chunks[0].presentationEnd = MeetingMediaTime(value: 200 * 16_000, timescale: 16_000)
        XCTAssertThrowsError(try MeetingBrowserAudioHardwareTests.measure(tooLongManifest, in: fixture.directory, maximumCaptureDuration: 100))
    }

    func testOneFrameTimestampQuantizationDoesNotAdmitTwoFrameMetadataMismatch() throws {
        let fixture = try self.fixture(frames: 1600, sampleRate: 16_000)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        for hostSeconds: Int64 in [100, 789_000] {
            for frameDifference: Int64 in [-2, -1, 0, 1, 2] {
                var track = fixture.track
                track.chunks[0].presentationStart = MeetingMediaTime(value: hostSeconds * 16_000, timescale: 16_000)
                track.chunks[0].presentationEnd = MeetingMediaTime(value: hostSeconds * 16_000 + 1600 + frameDifference, timescale: 16_000)
                if abs(frameDifference) <= 1 {
                    XCTAssertNoThrow(try MeetingBrowserAudioHardwareTests.measure(track, in: fixture.directory, maximumCaptureDuration: 100),
                                     "One-frame rounding at host time \(hostSeconds), difference \(frameDifference), must be accepted.")
                } else {
                    XCTAssertThrowsError(try MeetingBrowserAudioHardwareTests.measure(track, in: fixture.directory, maximumCaptureDuration: 100),
                                         "Two-frame metadata mismatch at host time \(hostSeconds) must be rejected.")
                }
            }
        }
        var invalidRange = fixture.track
        invalidRange.chunks[0].presentationEnd = invalidRange.chunks[0].presentationStart
        XCTAssertThrowsError(try MeetingBrowserAudioHardwareTests.measure(invalidRange, in: fixture.directory, maximumCaptureDuration: 100))
    }

    func testGapMetadataAvoidsFalseContiguousComparisonButKeepsHardBound() throws {
        let fixture = try self.fixture(frames: 1600, sampleRate: 16_000)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var track = fixture.track
        track.chunks[0].presentationEnd.value += 16_000
        track.chunks[0].discontinuities = [MeetingAudioDiscontinuity(kind: .sourceLost, presentationTime: nil, gapSeconds: 1, detail: nil)]
        XCTAssertNoThrow(try MeetingBrowserAudioHardwareTests.measure(track, in: fixture.directory, maximumCaptureDuration: 100))
        track.chunks[0].presentationEnd = MeetingMediaTime(value: 250 * 16_000, timescale: 16_000)
        XCTAssertThrowsError(try MeetingBrowserAudioHardwareTests.measure(track, in: fixture.directory, maximumCaptureDuration: 100))
    }

    func testNonFinitePcmAndInvalidDeclaredTimeRemainFailures() throws {
        let fixture = try self.fixture(frames: 1600, sampleRate: 16_000, nonFinite: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        XCTAssertThrowsError(try MeetingBrowserAudioHardwareTests.measure(fixture.track, in: fixture.directory, maximumCaptureDuration: 100)) { error in
            XCTAssertTrue(error.localizedDescription.contains("non-finite PCM"))
        }
        var invalidTime = fixture.track
        invalidTime.chunks[0].presentationEnd = MeetingMediaTime(value: 1600, timescale: 0)
        XCTAssertThrowsError(try MeetingBrowserAudioHardwareTests.measure(invalidTime, in: fixture.directory, maximumCaptureDuration: 100))
    }

    @MainActor
    func testReportNamesRejectedTrackAndRetainsProtocolMetadata() throws {
        let fixture = try self.fixture(frames: 1600, sampleRate: 16_000)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var track = fixture.track
        track.chunks[0].presentationEnd.value += 32
        let timebase = track.timebase
        var session = MeetingSession(configuration: MeetingCaptureConfiguration(
            mode: .onlineCall, title: "Synthetic rejected metadata", languageCode: "ru", application: nil,
            applicationAudioScope: .systemAudio,
            microphone: MeetingMicrophoneIdentity(captureDeviceID: "synthetic-microphone", displayName: "Synthetic microphone")
        ), timebase: timebase)
        session.audioTracks = [track]
        session.state = .failed
        let protocolState = SystemContinuityProtocol(runID: UUID())
        let report = MeetingSystemAudioContinuityHardwareTests.report(
            session: session, directory: fixture.directory, runID: protocolState.runID,
            captureScope: .systemAudio, protocolState: protocolState, events: BrowserCaptureEvents(),
            failures: ["external phase protocol incomplete"], maximumCaptureDuration: 100
        )
        XCTAssertEqual(report.failures.first, "external phase protocol incomplete")
        XCTAssertTrue(report.failures.last?.contains("microphone saved PCM measurement failed") == true)
        XCTAssertFalse(report.protocolComplete)
        XCTAssertEqual(report.applicationAudioScope, "systemAudio")
        XCTAssertEqual(report.sessionDirectory, fixture.directory.path)
    }

    private func fixture(frames: Int64, sampleRate: Int32, nonFinite: Bool = false) throws -> (track: MeetingAudioTrack, directory: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BrowserMeasurement-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("chunk_0.caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1))
        do {
            let file = try AVAudioFile(forWriting: fileURL, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192))
            let samples = try XCTUnwrap(buffer.floatChannelData)[0]
            for frame in 0..<8192 { samples[frame] = frame % 2 == 0 ? 0.25 : -0.25 }
            if nonFinite { samples[0] = .nan }
            var remaining = frames
            while remaining > 0 {
                buffer.frameLength = UInt32(min(remaining, 8192))
                try file.write(from: buffer)
                remaining -= Int64(buffer.frameLength)
            }
        }
        let bytes = try XCTUnwrap((try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value)
        let chunk = MeetingAudioChunk(id: UUID(), sequence: 0, relativeFilePath: "chunk_0.caf",
                                     presentationStart: MeetingMediaTime(value: 100 * Int64(sampleRate), timescale: sampleRate),
                                     presentationEnd: MeetingMediaTime(value: 100 * Int64(sampleRate) + frames, timescale: sampleRate),
                                     discontinuities: [], sha256: "synthetic-measurement", byteCount: bytes, finalizationState: .finalized)
        let timebase = MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1,
                                               machTimebaseDenominator: 1, firstPresentationTime: nil)
        let track = MeetingAudioTrack(id: UUID(), kind: .microphone, sourceIdentifier: "synthetic-microphone",
                                     sourceDisplayName: "Synthetic microphone", format: nil, timebase: timebase,
                                     health: .waiting, chunks: [chunk])
        return (track, directory)
    }
}

#endif
