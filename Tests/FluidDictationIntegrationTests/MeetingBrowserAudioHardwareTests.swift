#if DEBUG

import AVFoundation
import CoreGraphics
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
        let immutableSession = session
        let start: MeetingCaptureStartResult
        do {
            start = try await Self.withDeadline(seconds: 8) {
                try await engine.start(
                    session: immutableSession, configuration: configuration,
                    sessionDirectory: directory, eventHandler: { events.record($0) }
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
            try await Task.sleep(nanoseconds: UInt64(options.durationSeconds * 1_000_000_000))
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

        let tracks = try session.audioTracks.map { try Self.measure($0, in: directory) }
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
        for track in tracks where track.chunkCount == 0 || track.finalizedChunkCount != track.chunkCount
            || track.persistedBytes == 0 || track.decodedFrames == 0 || track.nonFiniteSamples > 0 {
            failures.append("\(track.kind) has missing, unfinalized, empty, or invalid audio.")
        }
        if let browser = tracks.first(where: { $0.kind == "applicationAudio" }) {
            if browser.sourceIdentifier != options.bundleID || browser.rms <= 0.001
                || browser.peak <= 0.01 || browser.nonSilentSeconds < 0.5 {
                failures.append("Selected applicationAudio did not contain the externally played speech signal.")
            }
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
            tracks: tracks, events: eventSummary, speechText: speechText
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

    private static func measure(_ track: MeetingAudioTrack, in directory: URL) throws -> BrowserCaptureTrackMetrics {
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
            try Self.require(
                format.sampleRate.isFinite && format.sampleRate > 0 && format.sampleRate <= 192_000
                    && file.length <= Int64(format.sampleRate * 60),
                "CAF exceeds its decoding bound."
            )
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
        return result
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw BrowserCaptureFailure(message: message) }
    }

    private static func withDeadline<T: Sendable>(
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
        let rawDuration = environment["PICHI_BROWSER_CAPTURE_DURATION_SECONDS"] ?? "25"
        guard let duration = Double(rawDuration), duration.isFinite, (5...30).contains(duration) else {
            throw BrowserCaptureFailure(message: "DURATION_SECONDS must be in 5...30.")
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
}

private struct BrowserCaptureTrackMetrics: Encodable {
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

private struct BrowserCaptureEventSummary: Encodable {
    var trackHealthEvents = 0
    var finalizedChunkEvents = 0
    var captureMethodChanges = 0
    var interruptionsByKind: [String: Int] = [:]
    var droppedInterruptionDetails = 0
}

private final class BrowserCaptureEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var counts = BrowserCaptureEventSummary()
    private var retainedInterruptions: [MeetingSessionEvent] = []

    func record(_ event: MeetingCaptureEvent) {
        self.lock.withLock {
            switch event {
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

#endif
