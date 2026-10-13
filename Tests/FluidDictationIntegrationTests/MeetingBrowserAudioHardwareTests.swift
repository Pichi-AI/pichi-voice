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

    fileprivate nonisolated static func measure(_ track: MeetingAudioTrack, in directory: URL) throws -> BrowserCaptureTrackMetrics {
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

/// Real system-audio continuity probe. The parent owns external stimulus/processes; this class
/// never operates UI, launches/kills a browser, changes defaults, or requests permissions.
/// See docs/development/system-audio-continuity-test.md for the atomic command/ack protocol.
@MainActor
final class MeetingSystemAudioContinuityHardwareTests: XCTestCase {
    func testSystemAudioSurvivesExternalBrowserRestartWhenEnabled() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PICHI_SYSTEM_CAPTURE_CONSENT"] == "1" else {
            throw XCTSkip("Set PICHI_SYSTEM_CAPTURE_CONSENT=1 and explicit private ROOT/RUN_ID.")
        }
        let options = try SystemContinuityOptions(environment: environment)
        try options.prepareRoot()
        do {
            try MeetingBrowserAudioHardwareTests.require(CGPreflightScreenCaptureAccess(), "System audio is not preflight-authorized.")
            try MeetingBrowserAudioHardwareTests.require(
                AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, "Microphone is not preflight-authorized."
            )
            let report = try await self.capture(options)
            try MeetingBrowserAudioHardwareTests.write(report, to: options.root.appendingPathComponent("outcome.json"))
            XCTAssertTrue(report.failures.isEmpty, report.failures.joined(separator: " "))
        } catch {
            try? MeetingBrowserAudioHardwareTests.write(
                SystemContinuityReport(runID: options.runID, status: "failed", failures: [error.localizedDescription]),
                to: options.root.appendingPathComponent("outcome.json")
            )
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
        let start: MeetingCaptureStartResult
        let captureStart = SystemContinuityProtocol.hostSeconds()
        do {
            start = try await MeetingBrowserAudioHardwareTests.withDeadline(seconds: 12) {
                try await engine.start(session: immutableSession, configuration: configuration,
                                       sessionDirectory: directory, eventHandler: { events.record($0) })
            }
            session.audioTracks = start.tracks
            session.state = .recording
            try await store.save(session)
            try MeetingBrowserAudioHardwareTests.write(
                SystemContinuityReady(runID: options.runID, sessionID: session.id,
                                      sessionDirectory: directory.path, captureStartHostSeconds: captureStart,
                                      readyHostSeconds: SystemContinuityProtocol.hostSeconds(),
                                      durationSeconds: options.durationSeconds),
                to: options.root.appendingPathComponent("capture-ready.json")
            )
            let deadline = SystemContinuityProtocol.hostSeconds() + options.durationSeconds
            while SystemContinuityProtocol.hostSeconds() < deadline {
                try Task.checkCancellation()
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
                        try MeetingBrowserAudioHardwareTests.write(ack, to: options.root.appendingPathComponent("phase-ack.json"))
                    } else {
                        try MeetingBrowserAudioHardwareTests.require(command.runID == options.runID, "Phase command has another run ID.")
                    }
                }
                if protocolState.isComplete { break }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            try MeetingBrowserAudioHardwareTests.require(protocolState.isComplete, "External phase protocol did not complete before its deadline.")
            let sessionID = session.id
            let stop = try await MeetingBrowserAudioHardwareTests.withDeadline(seconds: 12) {
                try await engine.stop(sessionID: sessionID)
            }
            session.audioTracks = stop.tracks
            session.endedAt = stop.stoppedAt
            session.state = .interrupted // Capture probe does not claim meeting processing completed.
            session.recoveryResolvedAt = stop.stoppedAt
            session.events = events.interruptions()
            session.updatedAt = stop.stoppedAt
            try await store.save(session)
            await engine.shutdownForTermination()
        } catch {
            await engine.shutdownForTermination()
            if case let MeetingCaptureError.captureStopFailed(_, partial) = error {
                session.audioTracks = partial.tracks
                session.endedAt = partial.stoppedAt
            }
            session.state = .failed
            session.events = events.interruptions()
            session.updatedAt = Date()
            try? await store.save(session)
            throw error
        }
        var report = SystemContinuityReport(runID: options.runID, status: "failed", failures: [])
        report.sessionDirectory = directory.path
        report.applicationAudioScope = session.applicationAudioScope?.rawValue
        report.capturedApplication = session.capturedApplication?.bundleIdentifier
        report.captureScope = start.captureScope.map { String(describing: $0) }
        report.browserAbsentSeconds = protocolState.browserAbsentSeconds
        report.commands = protocolState.commands
        report.acknowledgements = protocolState.acknowledgements
        report.events = events.summary()
        report.tracks = try session.audioTracks.map { try MeetingBrowserAudioHardwareTests.measure($0, in: directory) }
        if report.applicationAudioScope != "systemAudio" || report.capturedApplication != nil || report.captureScope != "systemAudio" {
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
        report.status = report.failures.isEmpty ? "passed" : "failed"
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

    init(environment: [String: String]) throws {
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
            guard self.modelDirectory != nil, Set(self.expectedText.keys) == Set(SystemContinuityProtocol.phaseNames),
                  self.expectedText.values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                  Set(self.expectedText.values.map { $0.lowercased() }).count == 3 else {
                throw BrowserCaptureFailure(message: "Expected text requires an installed model and three distinct nonempty phase phrases.")
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

private struct SystemContinuityCommand: Codable {
    let runID: UUID
    let sequence: Int
    let action: String
    let phase: String?
    let bundleID: String?
    let executablePath: String?
    let processID: Int32?
}

private struct SystemContinuityAck: Codable {
    let runID: UUID
    let sequence: Int
    let machAbsoluteHostSeconds: Double
}

private struct SystemContinuityPhase: Encodable {
    let name: String
    let bundleID: String?
    let executablePath: String
    let processID: Int32
    let startHostSeconds: Double
    var endHostSeconds: Double
}

/// Only external phase evidence is trusted here, never inferred from RMS or ASR timing.
private struct SystemContinuityProtocol {
    static let phaseNames = ["browserBefore", "secondSource", "browserAfter"]
    let runID: UUID
    private(set) var sequence = 0
    private(set) var commands: [SystemContinuityCommand] = []
    private(set) var acknowledgements: [SystemContinuityAck] = []
    private(set) var phases: [SystemContinuityPhase] = []
    private var browserExitedAt: Double?
    private var browserRestartedAt: Double?
    private var restartedPID: Int32?
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

private struct SystemContinuityPhaseMetrics: Encodable {
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

private struct SystemContinuityReport: Encodable {
    let runID: UUID
    var status: String
    var failures: [String]
    var sessionDirectory: String?
    var applicationAudioScope: String?
    var capturedApplication: String?
    var captureScope: String?
    var browserAbsentSeconds: Double?
    var commands: [SystemContinuityCommand] = []
    var acknowledgements: [SystemContinuityAck] = []
    var tracks: [BrowserCaptureTrackMetrics] = []
    var phases: [SystemContinuityPhaseMetrics] = []
    var events: BrowserCaptureEventSummary?
}

/// Pure operator-evidence validation. No microphone, browser, permission, or model dependency.
final class MeetingSystemAudioContinuityProtocolTests: XCTestCase {
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

#endif
