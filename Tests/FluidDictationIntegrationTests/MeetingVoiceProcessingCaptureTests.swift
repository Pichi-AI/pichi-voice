import AVFoundation
import CoreAudio
import CoreMedia
@testable import FluidVoice_Debug
import Foundation
import os
import ScreenCaptureKit
import XCTest

/// Hardware/permission-free: ScreenCaptureKit and AVAudioEngine integration paths need live
/// screen-recording/microphone permission and are not exercised here. This covers the pure
/// decision, gate, drift-eligibility, de-drift transform and Codable pieces of Phase 3.
final class MeetingVoiceProcessingCaptureTests: XCTestCase {
    // MARK: - Decision table

    private func mic(uid: String? = "mic-uid", role: MeetingMicrophoneRole = .personal) -> MeetingMicrophoneIdentity {
        MeetingMicrophoneIdentity(
            captureDeviceID: uid ?? "selection-1",
            coreAudioUID: uid,
            avCaptureDeviceID: "dev-1",
            displayName: "Mic",
            role: role
        )
    }

    private func viableRoute() -> MeetingOutputRouteSnapshot {
        MeetingOutputRouteSnapshot(deviceExists: true, isBluetooth: false, isBuiltIn: true, isHeadphonesDataSource: false)
    }

    func testDecisionSucceedsWhenEveryConditionIsMet() {
        let decision = MeetingCapturePathDecider.decide(mode: .onlineCall, microphone: self.mic(), outputRoute: self.viableRoute())
        XCTAssertEqual(decision, .voiceProcessing)
    }

    func testPreproductionDirectAEC3PreferenceSelectsPairedScreenCaptureKit() {
        let decision = MeetingCapturePathDecider.decide(
            mode: .onlineCall,
            microphone: self.mic(),
            outputRoute: self.viableRoute(),
            preferDirectAEC3: true
        )
        XCTAssertEqual(
            decision,
            .screenCaptureKit(reason: MeetingCapturePathDecider.directAEC3DefaultReason)
        )
    }

    func testDirectAEC3GateDefaultsOnAndHasExactDisableEscapeHatch() {
        XCTAssertTrue(MeetingDirectAEC3Gate.enabled(environment: [:]))
        XCTAssertTrue(MeetingDirectAEC3Gate.enabled(environment: [
            MeetingDirectAEC3Gate.disableEnvironmentKey: "true",
        ]))
        XCTAssertFalse(MeetingDirectAEC3Gate.enabled(environment: [
            MeetingDirectAEC3Gate.disableEnvironmentKey: "1",
        ]))
    }

    #if DEBUG
    func testExplicitC2GateCanForcePairedScreenCaptureKitWithoutChangingDefault() {
        let defaultDecision = MeetingCapturePathDecider.decide(
            mode: .onlineCall, microphone: self.mic(), outputRoute: self.viableRoute()
        )
        let forcedDecision = MeetingCapturePathDecider.decide(
            mode: .onlineCall,
            microphone: self.mic(),
            outputRoute: self.viableRoute(),
            forcePairedScreenCaptureKit: true,
            preferDirectAEC3: true
        )
        XCTAssertEqual(defaultDecision, .voiceProcessing)
        XCTAssertEqual(
            forcedDecision,
            .screenCaptureKit(reason: MeetingCapturePathDecider.diagnosticForceScreenCaptureKitReason)
        )
        guard case let .screenCaptureKit(reason) = forcedDecision else { return }
        XCTAssertTrue(reason.contains("C2 diagnostic"))
        XCTAssertTrue(reason.contains("not a production fallback"))
    }

    func testC2GateIsOnlyEnabledByExplicitEnvironmentValue() {
        XCTAssertFalse(MeetingSCKPairedDiagnosticGate.enabled(environment: [:]))
        XCTAssertFalse(MeetingSCKPairedDiagnosticGate.enabled(environment: [
            MeetingSCKPairedDiagnosticGate.environmentKey: "true",
        ]))
        XCTAssertTrue(MeetingSCKPairedDiagnosticGate.enabled(environment: [
            MeetingSCKPairedDiagnosticGate.environmentKey: "1",
        ]))
    }
    #endif

    func testDecisionDeclinesForInRoomMode() {
        let decision = MeetingCapturePathDecider.decide(mode: .inRoom, microphone: self.mic(), outputRoute: self.viableRoute())
        guard case .screenCaptureKit = decision else { return XCTFail("expected decline") }
    }

    func testDecisionDeclinesWithoutCoreAudioUID() {
        let decision = MeetingCapturePathDecider.decide(mode: .onlineCall, microphone: self.mic(uid: nil), outputRoute: self.viableRoute())
        guard case let .screenCaptureKit(reason) = decision else { return XCTFail("expected decline") }
        XCTAssertTrue(reason.contains("UID"))
    }

    func testDecisionDeclinesWithoutOutputDevice() {
        let route = MeetingOutputRouteSnapshot(deviceExists: false, isBluetooth: false, isBuiltIn: false, isHeadphonesDataSource: false)
        let decision = MeetingCapturePathDecider.decide(mode: .onlineCall, microphone: self.mic(), outputRoute: route)
        guard case let .screenCaptureKit(reason) = decision else { return XCTFail("expected decline") }
        XCTAssertTrue(reason.contains("output device"))
    }

    func testDecisionDeclinesForBluetoothOutput() {
        let route = MeetingOutputRouteSnapshot(deviceExists: true, isBluetooth: true, isBuiltIn: false, isHeadphonesDataSource: false)
        let decision = MeetingCapturePathDecider.decide(mode: .onlineCall, microphone: self.mic(), outputRoute: route)
        guard case let .screenCaptureKit(reason) = decision else { return XCTFail("expected decline") }
        XCTAssertTrue(reason.contains("Bluetooth"))
    }

    func testDecisionDeclinesForNonBuiltInOutput() {
        let route = MeetingOutputRouteSnapshot(deviceExists: true, isBluetooth: false, isBuiltIn: false, isHeadphonesDataSource: false)
        let decision = MeetingCapturePathDecider.decide(mode: .onlineCall, microphone: self.mic(), outputRoute: route)
        guard case let .screenCaptureKit(reason) = decision else { return XCTFail("expected decline") }
        XCTAssertTrue(reason.contains("built-in"))
    }

    func testDecisionDeclinesForHeadphonesDataSource() {
        let route = MeetingOutputRouteSnapshot(deviceExists: true, isBluetooth: false, isBuiltIn: true, isHeadphonesDataSource: true)
        let decision = MeetingCapturePathDecider.decide(mode: .onlineCall, microphone: self.mic(), outputRoute: route)
        guard case let .screenCaptureKit(reason) = decision else { return XCTFail("expected decline") }
        XCTAssertTrue(reason.contains("headphones"))
    }

    func testDecisionDeclinesForHeadphoneTerminalEvenWhenDataSourceIsUnknown() {
        let route = MeetingOutputRouteSnapshot(
            deviceExists: true,
            isBluetooth: false,
            isBuiltIn: true,
            isHeadphonesDataSource: false,
            terminalTypes: [kAudioStreamTerminalTypeHeadphones]
        )
        let decision = MeetingCapturePathDecider.decide(mode: .onlineCall, microphone: self.mic(), outputRoute: route)
        guard case let .screenCaptureKit(reason) = decision else { return XCTFail("expected decline") }
        XCTAssertTrue(reason.contains("headphones"))
    }

    func testDecisionSucceedsForPersonalRole() {
        let decision = MeetingCapturePathDecider.decide(
            mode: .onlineCall, microphone: self.mic(role: .personal), outputRoute: self.viableRoute()
        )
        XCTAssertEqual(decision, .voiceProcessing)
    }

    func testDecisionIgnoresSharedRoleForCaptureSafety() {
        let decision = MeetingCapturePathDecider.decide(
            mode: .onlineCall, microphone: self.mic(role: .shared), outputRoute: self.viableRoute()
        )
        XCTAssertEqual(decision, .voiceProcessing)
    }

    func testDecisionIgnoresUnknownRoleForCaptureSafety() {
        let decision = MeetingCapturePathDecider.decide(
            mode: .onlineCall, microphone: self.mic(role: .unknown), outputRoute: self.viableRoute()
        )
        XCTAssertEqual(decision, .voiceProcessing)
    }

    func testRawRouteRequiresPositiveHeadphoneEvidence() {
        let unknownBluetooth = MeetingOutputRouteSnapshot(
            deviceExists: true,
            isBluetooth: true,
            isBuiltIn: false,
            isHeadphonesDataSource: false,
            terminalTypes: []
        )
        XCTAssertEqual(MeetingRawMicrophoneProtection.classify(unknownBluetooth), .unfiltered)

        var externalWithoutDataSource = unknownBluetooth
        externalWithoutDataSource.isHeadphonesDataSource = true
        XCTAssertEqual(
            MeetingRawMicrophoneProtection.classify(externalWithoutDataSource),
            .unfiltered,
            "AudioDevice reports missing data-source properties pessimistically; that alone is not closed-route proof"
        )

        var headphones = unknownBluetooth
        headphones.terminalTypes = [kAudioStreamTerminalTypeHeadphones]
        XCTAssertEqual(MeetingRawMicrophoneProtection.classify(headphones), .acousticallyClosed)

        let builtInHeadphoneJack = MeetingOutputRouteSnapshot(
            deviceExists: true,
            isBluetooth: false,
            isBuiltIn: true,
            isHeadphonesDataSource: true
        )
        XCTAssertEqual(MeetingRawMicrophoneProtection.classify(builtInHeadphoneJack), .acousticallyClosed)
    }

    func testTranscriptGateFailsClosedAcrossTransition() {
        let gate = MeetingMicrophoneTranscriptGate(.voiceProcessed)
        XCTAssertTrue(gate.admitsTranscript())
        gate.update(.unprotected)
        XCTAssertFalse(gate.admitsTranscript())
        gate.update(.acousticallyClosed)
        XCTAssertTrue(gate.admitsTranscript())
    }

    func testRawRouteResumeWithoutNewPCMReopensOnlyAfterDurableBoundary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var track = self.makeTrack(chunkStart: 10, drift: nil, captureMethod: .avCaptureSession)
        track.chunks = []
        track.captureEras = [MeetingCaptureEra(method: .avCaptureSession, deviceUID: "mic",
            deviceName: "Mic", roleAtElection: .unknown, echoProtection: .unprotected, startSeconds: 10)]
        let writer = try MeetingAudioChunkWriter(track: track, sessionDirectory: root,
            chunkDuration: 60, eventHandler: { _ in })
        let gate = MeetingMicrophoneTranscriptGate(.unprotected)
        XCTAssertFalse(gate.observeAndAdmit(self.makeSampleBuffer(ptsSeconds: 10)))
        let epoch = gate.invalidationEpoch
        // No new PCM arrives before the one-shot route evaluation. This was a permanent stall.
        let recorded = try await MeetingRawMicrophoneProtection.persistResume(.unfiltered,
            observedAtSeconds: 12, writer: writer, gate: gate, epoch: epoch)
        XCTAssertTrue(recorded)
        XCTAssertFalse(gate.admitsTranscript(), "Persistence alone cannot publish live admission")
        let manifest = root.appendingPathComponent("tracks/microphone/track.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let persisted = try decoder.decode(MeetingAudioTrack.self, from: Data(contentsOf: manifest))
        XCTAssertEqual(persisted.captureEras?.map(\.echoProtection), [.unprotected, .unfiltered])
        XCTAssertEqual(persisted.captureEras?.last?.startSeconds, 12)
        XCTAssertTrue(gate.updateIfNotInvalidated(.unfiltered, since: epoch, notBeforePresentationSeconds: 12))
        // The privacy quarantine may release older PCM later. It is retained but not live-ASR eligible.
        let late = self.makeSampleBuffer(ptsSeconds: 11.9)
        XCTAssertTrue(writer.enqueue(late))
        XCTAssertFalse(gate.observeAndAdmit(late))
        let resumed = self.makeSampleBuffer(ptsSeconds: 12.1)
        XCTAssertTrue(writer.enqueue(resumed))
        XCTAssertTrue(gate.observeAndAdmit(resumed))
        let stopped = await writer.stop()
        XCTAssertFalse(stopped.chunks.isEmpty)
        XCTAssertEqual(stopped.health.droppedSampleCount, 0)
        XCTAssertFalse(MeetingProcessingPipeline.microphoneIntervalIsAdmitted(start: 11.9, end: 12.01,
            eras: try XCTUnwrap(stopped.captureEras)))
        XCTAssertTrue(MeetingProcessingPipeline.microphoneIntervalIsAdmitted(start: 12.1, end: 12.11,
            eras: try XCTUnwrap(stopped.captureEras)))
    }

    func testRawRouteResumeRejectsStaleObservationAndLaterInvalidation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var track = self.makeTrack(chunkStart: 10, drift: nil, captureMethod: .avCaptureSession)
        track.chunks = []
        track.captureEras = [MeetingCaptureEra(method: .avCaptureSession, deviceUID: "mic",
            deviceName: "Mic", roleAtElection: .unknown, echoProtection: .unprotected, startSeconds: 10)]
        let writer = try MeetingAudioChunkWriter(track: track, sessionDirectory: root,
            chunkDuration: 60, eventHandler: { _ in })
        let gate = MeetingMicrophoneTranscriptGate()
        let staleEpoch = gate.invalidationEpoch
        _ = gate.invalidate()
        let stale = try await MeetingRawMicrophoneProtection.persistResume(.unfiltered,
            observedAtSeconds: 12, writer: writer, gate: gate, epoch: staleEpoch)
        XCTAssertFalse(stale)
        let epoch = gate.invalidationEpoch
        let recorded = try await MeetingRawMicrophoneProtection.persistResume(.unfiltered,
            observedAtSeconds: 12, writer: writer, gate: gate, epoch: epoch)
        XCTAssertTrue(recorded)
        _ = gate.invalidate()
        XCTAssertFalse(gate.updateIfNotInvalidated(.unfiltered, since: epoch, notBeforePresentationSeconds: 12))
        XCTAssertFalse(gate.observeAndAdmit(self.makeSampleBuffer(ptsSeconds: 13)))
        _ = await writer.stop()
    }

    func testRawRouteResumePersistenceFailureDoesNotOpenAdmission() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var track = self.makeTrack(chunkStart: 10, drift: nil, captureMethod: .avCaptureSession)
        track.chunks = []
        track.captureEras = [MeetingCaptureEra(method: .avCaptureSession, deviceUID: "mic",
            deviceName: "Mic", roleAtElection: .unknown, echoProtection: .unprotected, startSeconds: 10)]
        let writer = try MeetingAudioChunkWriter(track: track, sessionDirectory: root,
            chunkDuration: 60, eventHandler: { _ in })
        let gate = MeetingMicrophoneTranscriptGate()
        let directory = root.appendingPathComponent("tracks/microphone")
        try FileManager.default.removeItem(at: directory)
        try Data().write(to: directory)
        do {
            _ = try await MeetingRawMicrophoneProtection.persistResume(.unfiltered,
                observedAtSeconds: 12, writer: writer, gate: gate, epoch: gate.invalidationEpoch)
            XCTFail("The failed durable write must propagate")
        } catch {}
        XCTAssertFalse(gate.observeAndAdmit(self.makeSampleBuffer(ptsSeconds: 13)))
        let stopped = await writer.stop()
        XCTAssertEqual(stopped.captureEras?.last?.echoProtection, .unprotected)
    }

    func testTurnCrossingUnprotectedEraIsRejectedAsAWhole() {
        let eras = [
            MeetingCaptureEra(
                method: .voiceProcessing,
                deviceUID: "mic",
                deviceName: "Mic",
                roleAtElection: .unknown,
                echoProtection: .voiceProcessed,
                startSeconds: -.infinity
            ),
            MeetingCaptureEra(
                method: .avCaptureSession,
                deviceUID: "mic",
                deviceName: "Mic",
                roleAtElection: .unknown,
                echoProtection: .unprotected,
                startSeconds: 10
            ),
        ]
        XCTAssertTrue(MeetingProcessingPipeline.microphoneIntervalIsAdmitted(start: 8, end: 9.9, eras: eras))
        XCTAssertFalse(MeetingProcessingPipeline.microphoneIntervalIsAdmitted(start: 9.9, end: 10.1, eras: eras))
        XCTAssertFalse(MeetingProcessingPipeline.microphoneIntervalIsAdmitted(start: 10, end: 11, eras: eras))
    }

    func testLegacyVoiceProcessingEraWithoutProtectionRetainsPositiveVPIOEvidence() throws {
        let data = Data(#"{"method":"voiceProcessing","roleAtElection":"personal","startSeconds":0}"#.utf8)
        let era = try JSONDecoder().decode(MeetingCaptureEra.self, from: data)
        XCTAssertEqual(era.echoProtection, .voiceProcessed)
    }

    func testLegacyRawEraWithoutProtectionPreservesPreviouslyEligibleRecording() throws {
        let data = Data(#"{"method":"avCaptureSession","roleAtElection":"personal","startSeconds":0}"#.utf8)
        let era = try JSONDecoder().decode(MeetingCaptureEra.self, from: data)
        XCTAssertEqual(era.echoProtection, .legacyUnclassified)
        let roundTripped = try JSONDecoder().decode(
            MeetingCaptureEra.self,
            from: JSONEncoder().encode(era)
        )
        XCTAssertEqual(roundTripped.echoProtection, .legacyUnclassified)
    }

    func testTranscriptGateInvalidationUsesLastObservedSampleBoundary() {
        let gate = MeetingMicrophoneTranscriptGate(.voiceProcessed)
        XCTAssertTrue(gate.observeAndAdmit(self.makeSampleBuffer(ptsSeconds: 12.5)))
        let boundary = gate.invalidate()
        XCTAssertEqual(
            boundary?.unsafeStartSeconds ?? -1,
            12.5 - MeetingMicrophoneTranscriptGate.routeNotificationSafetySeconds,
            accuracy: 0.000_001
        )
        XCTAssertEqual(boundary?.observedSeconds ?? -1, 12.5, accuracy: 0.000_001)
        XCTAssertFalse(gate.observeAndAdmit(self.makeSampleBuffer(ptsSeconds: 12.51)))
    }

    func testCoverageGapPersistsTheUnprotectedTail() {
        let trackID = UUID()
        let track = MeetingAudioTrack(
            id: trackID,
            kind: .microphone,
            sourceIdentifier: "mic",
            sourceDisplayName: "Mic",
            format: nil,
            timebase: MeetingTimebaseMetadata(
                startedHostTime: 0,
                machTimebaseNumerator: 1,
                machTimebaseDenominator: 1,
                firstPresentationTime: nil
            ),
            health: .waiting,
            chunks: [MeetingAudioChunk(
                id: UUID(),
                sequence: 0,
                relativeFilePath: "mic.m4a",
                presentationStart: MeetingMediaTime(value: 100, timescale: 1),
                presentationEnd: MeetingMediaTime(value: 120, timescale: 1),
                discontinuities: [],
                sha256: "x",
                byteCount: 1,
                finalizationState: .finalized
            )],
            captureMethod: .avCaptureSession,
            captureEras: [
                MeetingCaptureEra(
                    method: .voiceProcessing,
                    deviceUID: "mic",
                    deviceName: "Mic",
                    roleAtElection: .unknown,
                    echoProtection: .voiceProcessed,
                    startSeconds: 0
                ),
                MeetingCaptureEra(
                    method: .avCaptureSession,
                    deviceUID: "mic",
                    deviceName: "Mic",
                    roleAtElection: .unknown,
                    echoProtection: .unprotected,
                    startSeconds: 110
                ),
            ]
        )
        let gaps = MeetingProcessingPipeline.microphoneCoverageGaps(track: track, origin: 100)
        XCTAssertEqual(gaps, [MeetingTranscriptCoverageGap(
            trackID: trackID, start: 10, end: 20, reason: .unprotectedMicrophone
        )])
    }

    // MARK: - Commit gate

    private func makeSampleBuffer(ptsSeconds: Double = 0) -> CMSampleBuffer {
        // Fixed test fixture: missing required audio storage or evidence is a setup failure.
        // swiftlint:disable:next force_unwrapping
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        // Fixed test fixture: missing required audio storage or evidence is a setup failure.
        // swiftlint:disable:next force_unwrapping
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        buffer.frameLength = 480
        let pts = CMTime(seconds: ptsSeconds, preferredTimescale: 48_000)
        // Fixed test fixture: missing required audio storage or evidence is a setup failure.
        // swiftlint:disable:next force_unwrapping
        return meetingMicrophoneSynthesizeSampleBuffer(from: buffer, presentationTime: pts)!
    }

    func testGateBuffersThenPassesThroughAfterCommit() {
        let gate = MeetingVoiceProcessingCommitGate()
        XCTAssertEqual(gate.offer(self.makeSampleBuffer()), .buffered)
        let flushed = gate.beginCommitFlush()
        XCTAssertEqual(flushed?.count, 1)
        XCTAssertNil(gate.continueCommitFlush(), "drained ring flips to committed")
        XCTAssertEqual(gate.offer(self.makeSampleBuffer()), .passthrough)
    }

    func testGateFlushSerializesConcurrentArrivalsBeforePassthrough() {
        let gate = MeetingVoiceProcessingCommitGate()
        XCTAssertEqual(gate.offer(self.makeSampleBuffer(ptsSeconds: 0)), .buffered)
        let first = gate.beginCommitFlush()
        XCTAssertEqual(first?.count, 1)
        // A sample landing mid-flush must queue behind the ring, never overtake it.
        XCTAssertEqual(gate.offer(self.makeSampleBuffer(ptsSeconds: 1)), .buffered)
        let second = gate.continueCommitFlush()
        XCTAssertEqual(second?.count, 1)
        XCTAssertNil(gate.continueCommitFlush())
        XCTAssertEqual(gate.offer(self.makeSampleBuffer(ptsSeconds: 2)), .passthrough)
    }

    func testGateAbortAndTerminalEventsAreNoOpsWhileFlushing() {
        let gate = MeetingVoiceProcessingCommitGate()
        _ = gate.offer(self.makeSampleBuffer())
        _ = gate.beginCommitFlush()
        gate.abort()
        XCTAssertFalse(gate.offerTerminalEventPreCommit())
        XCTAssertNil(gate.continueCommitFlush())
        XCTAssertEqual(gate.offer(self.makeSampleBuffer()), .passthrough, "a promoted flush can never be aborted back out")
    }

    func testGateAbortsAndSwallowsAfterRingExhaustion() throws {
        // Cap sized to fit exactly one sample's worth of bytes: the second sample must not fit.
        let one = self.makeSampleBuffer()
        let bytes = try CMBlockBufferGetDataLength(XCTUnwrap(CMSampleBufferGetDataBuffer(one)))
        XCTAssertGreaterThan(bytes, 0)
        let gate = MeetingVoiceProcessingCommitGate(ringCapBytes: bytes)
        XCTAssertEqual(gate.offer(one), .buffered)
        XCTAssertEqual(gate.offer(self.makeSampleBuffer(ptsSeconds: 1)), .aborted, "ring-cap exhaustion must abort, never evict-and-commit")
        XCTAssertEqual(gate.offer(self.makeSampleBuffer(ptsSeconds: 2)), .aborted)
        XCTAssertNil(gate.beginCommitFlush(), "an aborted gate can never commit")
    }

    func testGateTerminalEventPreCommitAborts() {
        let gate = MeetingVoiceProcessingCommitGate()
        _ = gate.offer(self.makeSampleBuffer())
        XCTAssertTrue(gate.offerTerminalEventPreCommit())
        XCTAssertEqual(gate.offer(self.makeSampleBuffer()), .aborted)
        XCTAssertNil(gate.beginCommitFlush())
    }

    func testGateTerminalEventPostCommitIsNotAnAbort() {
        let gate = MeetingVoiceProcessingCommitGate()
        _ = gate.beginCommitFlush()
        XCTAssertNil(gate.continueCommitFlush())
        XCTAssertFalse(gate.offerTerminalEventPreCommit(), "post-commit terminal events are the runtime's normal interrupt path, not a gate abort")
        XCTAssertEqual(gate.offer(self.makeSampleBuffer()), .passthrough)
    }

    func testGateAbortIsIdempotentAndFinal() {
        let gate = MeetingVoiceProcessingCommitGate()
        gate.abort()
        gate.abort()
        XCTAssertEqual(gate.offer(self.makeSampleBuffer()), .aborted)
        XCTAssertNil(gate.beginCommitFlush())
    }

    // MARK: - Watchdog predicate

    func testWatchdogDoesNotTripBeforeThreshold() {
        XCTAssertFalse(MeetingVoiceProcessingWatchdog.isStalled(secondsSinceLastEmittedBuffer: 9.9))
    }

    func testWatchdogTripsAtThreshold() {
        XCTAssertTrue(MeetingVoiceProcessingWatchdog.isStalled(secondsSinceLastEmittedBuffer: 10))
        XCTAssertTrue(MeetingVoiceProcessingWatchdog.isStalled(secondsSinceLastEmittedBuffer: 30))
    }

    func testRouteDrivenFallbackRecoversOnlyOnViableBuiltInRoute() {
        XCTAssertTrue(MeetingCaptureTransitionPolicy.shouldAttemptVoiceProcessingRecovery(
            routeDrivenFallback: true,
            attempts: 0,
            microphone: self.mic(),
            outputRoute: self.viableRoute()
        ))
        XCTAssertFalse(MeetingCaptureTransitionPolicy.shouldAttemptVoiceProcessingRecovery(
            routeDrivenFallback: true,
            attempts: 0,
            microphone: self.mic(),
            outputRoute: MeetingOutputRouteSnapshot(
                deviceExists: true,
                isBluetooth: true,
                isBuiltIn: false,
                isHeadphonesDataSource: false
            )
        ))
    }

    func testWatchdogOrEngineFailureFallbackStaysSticky() {
        XCTAssertFalse(MeetingCaptureTransitionPolicy.shouldAttemptVoiceProcessingRecovery(
            routeDrivenFallback: false,
            attempts: 0,
            microphone: self.mic(),
            outputRoute: self.viableRoute()
        ))
    }

    func testVoiceProcessingRecoveryAttemptsAreBounded() {
        XCTAssertFalse(MeetingCaptureTransitionPolicy.shouldAttemptVoiceProcessingRecovery(
            routeDrivenFallback: true,
            attempts: MeetingCaptureTransitionPolicy.maximumRouteRecoveryAttempts,
            microphone: self.mic(),
            outputRoute: self.viableRoute()
        ))
    }

    func testRecoveryDwellCannotArmDuringTransitionStopOrQuarantine() {
        for blocked in [
            (false, false, false, false),
            (true, true, false, false),
            (true, false, true, false),
            (true, false, false, true),
        ] {
            XCTAssertFalse(MeetingVoiceProcessingUpgradeDwell.shouldArm(
                phaseIsAVCapture: blocked.0,
                dwellAlreadyArmed: blocked.1,
                quarantined: blocked.2,
                stopRequested: blocked.3,
                routeDrivenFallback: true,
                attempts: 0,
                microphone: self.mic(),
                outputRoute: self.viableRoute()
            ))
        }
    }

    func testStopOldFirstOwnershipSequenceReleasesAVCaptureBeforeVPIOConstruction() throws {
        let steps = MeetingVoiceProcessingUpgradeOwnership.stopOldFirstSequence
        let clearRuntime = try XCTUnwrap(steps.firstIndex(of: .clearRuntimeRef))
        let clearLocal = try XCTUnwrap(steps.firstIndex(of: .clearLocalRef))
        let constructVPIO = try XCTUnwrap(steps.firstIndex(of: .constructVoiceProcessing))
        XCTAssertLessThan(clearRuntime, constructVPIO)
        XCTAssertLessThan(clearLocal, constructVPIO)
        XCTAssertFalse(MeetingVoiceProcessingUpgradeOwnership.mayConstructVoiceProcessing(
            avCaptureRuntimeRef: false,
            avCaptureLocalRef: true,
            avCaptureRunning: false,
            teardownProven: true
        ))
        XCTAssertTrue(MeetingVoiceProcessingUpgradeOwnership.mayConstructVoiceProcessing(
            avCaptureRuntimeRef: false,
            avCaptureLocalRef: false,
            avCaptureRunning: false,
            teardownProven: true
        ))
        XCTAssertFalse(MeetingVoiceProcessingUpgradeOwnership.watchdogRunsDuringIntentionalGap)
    }

    func testRollbackMayPublishAVCaptureOnlyWithALiveComponent() {
        XCTAssertFalse(MeetingVoiceProcessingUpgradeOwnership.mayPhaseAVCapture(
            hasComponent: false,
            componentStopped: false
        ))
        XCTAssertFalse(MeetingVoiceProcessingUpgradeOwnership.mayPhaseAVCapture(
            hasComponent: true,
            componentStopped: true
        ))
        XCTAssertTrue(MeetingVoiceProcessingUpgradeOwnership.mayPhaseAVCapture(
            hasComponent: true,
            componentStopped: false
        ))
    }

    func testStickyFallbackRebindsWhenPhysicalInputChanges() {
        XCTAssertTrue(MeetingAVCaptureRebindDecision.shouldRebind(
            activeCoreAudioUID: "airpods",
            electedCoreAudioUID: "built-in",
            forced: false
        ))
    }

    func testOutputOnlyRouteChangeDoesNotRebindTheSamePhysicalInput() {
        XCTAssertFalse(MeetingAVCaptureRebindDecision.shouldRebind(
            activeCoreAudioUID: "built-in",
            electedCoreAudioUID: "built-in",
            forced: false
        ))
    }

    func testMissingSettledDefaultDoesNotAbandonTheActiveInput() {
        XCTAssertFalse(MeetingAVCaptureRebindDecision.shouldRebind(
            activeCoreAudioUID: "airpods",
            electedCoreAudioUID: nil,
            forced: false
        ))
    }

    func testNoBufferWatchdogCanRebuildTheSamePhysicalInput() {
        XCTAssertTrue(MeetingAVCaptureRebindDecision.shouldRebind(
            activeCoreAudioUID: "built-in",
            electedCoreAudioUID: "built-in",
            forced: true
        ))
    }

    func testRetiredCandidateTerminalCallbackCannotFailItsSuccessor() {
        let retired = MeetingAVCaptureAttemptToken()
        let active = MeetingAVCaptureAttemptToken()
        XCTAssertFalse(MeetingAVCaptureFailureAdmission.accepts(
            currentGeneration: 7,
            eventGeneration: 7,
            activeToken: active,
            eventToken: retired,
            stopRequested: false
        ))
        XCTAssertTrue(MeetingAVCaptureFailureAdmission.accepts(
            currentGeneration: 7,
            eventGeneration: 7,
            activeToken: active,
            eventToken: active,
            stopRequested: false
        ))
    }

    func testStopRejectsEvenTheCurrentCandidateTerminalCallback() {
        let active = MeetingAVCaptureAttemptToken()
        XCTAssertFalse(MeetingAVCaptureFailureAdmission.accepts(
            currentGeneration: 7,
            eventGeneration: 7,
            activeToken: active,
            eventToken: active,
            stopRequested: true
        ))
    }

    func testCaptureRetirementWaitsBehindAnInFlightFrameworkStart() async {
        let startEntered = DispatchSemaphore(value: 0)
        let allowStartToReturn = DispatchSemaphore(value: 0)
        let stopRan = DispatchSemaphore(value: 0)
        let lifecycle = MeetingSerializedCaptureLifecycle(
            label: "com.fluidvoice.tests.avcapture-lifecycle",
            start: {
                startEntered.signal()
                allowStartToReturn.wait()
                return false
            },
            stop: { stopRan.signal() }
        )

        let startTask = Task { await lifecycle.start() }
        XCTAssertEqual(startEntered.wait(timeout: .now() + 1), .success)
        let stopTask = Task { await lifecycle.stop() }
        XCTAssertEqual(
            stopRan.wait(timeout: .now() + 0.1),
            .timedOut,
            "retirement must not bypass an uninterruptible startRunning call"
        )

        allowStartToReturn.signal()
        _ = await startTask.value
        await stopTask.value
        XCTAssertEqual(stopRan.wait(timeout: .now() + 1), .success)
    }

    func testCaptureRetirementRejectsAStartSubmittedAfterStopAdmission() async {
        let startRan = DispatchSemaphore(value: 0)
        let stopEntered = DispatchSemaphore(value: 0)
        let allowStopToReturn = DispatchSemaphore(value: 0)
        let lifecycle = MeetingSerializedCaptureLifecycle(
            label: "com.fluidvoice.tests.avcapture-retirement-seal",
            start: {
                startRan.signal()
                return true
            },
            stop: {
                stopEntered.signal()
                allowStopToReturn.wait()
            }
        )

        let stopTask = Task { await lifecycle.stop() }
        XCTAssertEqual(stopEntered.wait(timeout: .now() + 1), .success)
        let lateStartSucceeded = await lifecycle.start()
        XCTAssertFalse(lateStartSucceeded)
        XCTAssertEqual(
            startRan.wait(timeout: .now() + 0.1),
            .timedOut,
            "retirement must permanently seal the lifecycle against late restarts"
        )

        allowStopToReturn.signal()
        await stopTask.value
    }

    // MARK: - ScreenCaptureKit audio-settings plumbing (rebuild regression)

    func testIncludeMicrophoneFalseAttachesNoMicrophoneDevice() {
        let configuration = SCStreamConfiguration()
        MeetingScreenCaptureAudioSettings.apply(to: configuration, microphone: self.mic(), includeMicrophone: false)
        XCTAssertFalse(configuration.captureMicrophone)
        XCTAssertNil(configuration.microphoneCaptureDeviceID)
    }

    func testIncludeMicrophoneTrueSetsTheRequestedDevice() {
        let configuration = SCStreamConfiguration()
        MeetingScreenCaptureAudioSettings.apply(to: configuration, microphone: self.mic(), includeMicrophone: true)
        XCTAssertTrue(configuration.captureMicrophone)
        XCTAssertEqual(configuration.microphoneCaptureDeviceID, "dev-1")
    }

    func testAVCaptureSelectionPrefersExplicitResolvedID() {
        let candidates = [
            MeetingAVCaptureDeviceDescriptor(uniqueID: "explicit", displayName: "Mic"),
            MeetingAVCaptureDeviceDescriptor(uniqueID: "mic-uid", displayName: "Mic"),
        ]
        var microphone = self.mic()
        microphone.avCaptureDeviceID = "explicit"
        XCTAssertEqual(
            MeetingAVCaptureDeviceSelection.select(microphone: microphone, candidates: candidates),
            "explicit"
        )
    }

    func testAVCaptureSelectionAcceptsLegacyCaptureIDOnlyForLegacyManifest() {
        let candidates = [MeetingAVCaptureDeviceDescriptor(uniqueID: "legacy-av", displayName: "Different")]
        let legacy = MeetingMicrophoneIdentity(
            captureDeviceID: "legacy-av",
            coreAudioUID: "core-id",
            identitySchemaVersion: nil,
            displayName: "Saved mic"
        )
        XCTAssertEqual(
            MeetingAVCaptureDeviceSelection.select(microphone: legacy, candidates: candidates),
            "legacy-av"
        )

        var current = legacy
        current.identitySchemaVersion = 2
        XCTAssertNil(MeetingAVCaptureDeviceSelection.select(microphone: current, candidates: candidates))
    }

    func testAVCaptureSelectionUsesCoreAudioUIDWhenFrameworkIDsMatch() {
        let microphone = MeetingMicrophoneIdentity(
            captureDeviceID: "core-id", coreAudioUID: "core-id", displayName: "Mic"
        )
        let candidates = [MeetingAVCaptureDeviceDescriptor(uniqueID: "core-id", displayName: "Other")]
        XCTAssertEqual(
            MeetingAVCaptureDeviceSelection.select(microphone: microphone, candidates: candidates),
            "core-id"
        )
    }

    func testAVCaptureSelectionUsesOnlyUniqueNormalizedNameFallback() {
        let microphone = MeetingMicrophoneIdentity(
            captureDeviceID: "core-id", coreAudioUID: "core-id", displayName: "  Studio MÍC  "
        )
        let unique = [MeetingAVCaptureDeviceDescriptor(uniqueID: "av-id", displayName: "studio mic")]
        XCTAssertEqual(
            MeetingAVCaptureDeviceSelection.select(microphone: microphone, candidates: unique),
            "av-id"
        )

        let ambiguous = unique + [MeetingAVCaptureDeviceDescriptor(uniqueID: "av-id-2", displayName: "Studio Mic")]
        XCTAssertNil(MeetingAVCaptureDeviceSelection.select(microphone: microphone, candidates: ambiguous))
    }

    func testMicrophoneIdentityDecodesLegacyManifestAndRoundTripsCurrentIdentity() throws {
        let legacyJSON = Data(#"{"captureDeviceID":"legacy-av","coreAudioUID":"core-id","displayName":"Mic","role":"personal"}"#.utf8)
        let legacy = try JSONDecoder().decode(MeetingMicrophoneIdentity.self, from: legacyJSON)
        XCTAssertNil(legacy.identitySchemaVersion)
        XCTAssertNil(legacy.avCaptureDeviceID)
        XCTAssertEqual(legacy.captureDeviceID, "legacy-av")

        let current = self.mic()
        let roundTrip = try JSONDecoder().decode(
            MeetingMicrophoneIdentity.self,
            from: JSONEncoder().encode(current)
        )
        XCTAssertEqual(roundTrip, current)
        XCTAssertEqual(roundTrip.identitySchemaVersion, 2)
    }

    func testSameDeviceElectionPreservesLegacyAVMappingAcrossCoreAudioRefresh() {
        let original = MeetingMicrophoneIdentity(
            captureDeviceID: "legacy-av",
            coreAudioUID: "core-id",
            identitySchemaVersion: nil,
            displayName: "Shared Name",
            role: .personal
        )
        let refreshed = MeetingMicrophoneIdentity(
            captureDeviceID: "core-id", coreAudioUID: "core-id", displayName: "Shared Name"
        )
        let elected = MeetingCaptureDeviceElection.decide(
            original: original, catalog: [refreshed], defaultInputUID: "core-id"
        )
        XCTAssertEqual(elected.identity.captureDeviceID, "core-id")
        XCTAssertEqual(elected.identity.avCaptureDeviceID, "legacy-av")
        XCTAssertEqual(elected.role, .unknown)
        XCTAssertEqual(elected.identity.role, .unknown)

        let ambiguous = [
            MeetingAVCaptureDeviceDescriptor(uniqueID: "legacy-av", displayName: "Shared Name"),
            MeetingAVCaptureDeviceDescriptor(uniqueID: "other-av", displayName: "Shared Name"),
        ]
        XCTAssertEqual(
            MeetingAVCaptureDeviceSelection.select(microphone: elected.identity, candidates: ambiguous),
            "legacy-av"
        )
    }

    func testSameDeviceElectionPreservesCurrentExplicitAVMapping() {
        let original = MeetingMicrophoneIdentity(
            captureDeviceID: "core-id",
            coreAudioUID: "core-id",
            avCaptureDeviceID: "explicit-av",
            displayName: "Shared Name",
            role: .personal
        )
        let refreshed = MeetingMicrophoneIdentity(
            captureDeviceID: "core-id", coreAudioUID: "core-id", displayName: "Shared Name"
        )
        let elected = MeetingCaptureDeviceElection.decide(
            original: original, catalog: [refreshed], defaultInputUID: "core-id"
        )
        XCTAssertEqual(elected.identity.avCaptureDeviceID, "explicit-av")
    }

    // MARK: - Eligibility

    private func makeStats(
        resyncCount: Int = 0,
        resyncClampCount: Int = 0,
        divergenceStepEventCount: Int = 0,
        configurationChangeEvents: Int = 0,
        droppedPostCapCount: Int = 0
    ) -> MeetingMicrophoneCaptureStats.Snapshot {
        var snapshot = MeetingMicrophoneCaptureStats.Snapshot()
        snapshot.resyncCount = resyncCount
        snapshot.resyncClampCount = resyncClampCount
        snapshot.divergenceStepEventCount = divergenceStepEventCount
        snapshot.configurationChangeEvents = configurationChangeEvents
        snapshot.droppedPostCapCount = droppedPostCapCount
        return snapshot
    }

    func testCleanRunIsEligible() {
        XCTAssertTrue(MeetingVoiceProcessingDriftSnapshot.isEligible(self.makeStats()))
    }

    func testMidStreamResetMakesRunIneligible() {
        XCTAssertFalse(MeetingVoiceProcessingDriftSnapshot.isEligible(self.makeStats(resyncCount: 1)))
        XCTAssertFalse(MeetingVoiceProcessingDriftSnapshot.isEligible(self.makeStats(resyncClampCount: 1)))
        XCTAssertFalse(MeetingVoiceProcessingDriftSnapshot.isEligible(self.makeStats(divergenceStepEventCount: 1)))
        XCTAssertFalse(MeetingVoiceProcessingDriftSnapshot.isEligible(self.makeStats(configurationChangeEvents: 1)))
        XCTAssertFalse(MeetingVoiceProcessingDriftSnapshot.isEligible(self.makeStats(droppedPostCapCount: 1)))
    }

    func testElapsedValidHostSecondsFromStats() {
        var snapshot = MeetingMicrophoneCaptureStats.Snapshot()
        snapshot.firstValidHostSeconds = 10
        snapshot.lastValidHostSeconds = 22.5
        XCTAssertEqual(MeetingVoiceProcessingDriftSnapshot.elapsedValidHostSeconds(snapshot), 12.5, accuracy: 1e-9)
    }

    func testElapsedValidHostSecondsIsZeroWithoutBothBounds() {
        XCTAssertEqual(MeetingVoiceProcessingDriftSnapshot.elapsedValidHostSeconds(MeetingMicrophoneCaptureStats.Snapshot()), 0)
    }

    // MARK: - End-to-end de-drift sign

    private func makeTrack(chunkStart: Double, drift: MeetingClockDriftRecord?, captureMethod: MeetingAudioTrackCaptureMethod?) -> MeetingAudioTrack {
        var track = MeetingAudioTrack(
            id: UUID(),
            kind: .microphone,
            sourceIdentifier: "mic",
            sourceDisplayName: "Mic",
            format: nil,
            timebase: MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil),
            health: .waiting,
            chunks: [MeetingAudioChunk(
                id: UUID(),
                sequence: 0,
                relativeFilePath: "x.m4a",
                presentationStart: MeetingMediaTime(value: Int64(chunkStart * 48_000), timescale: 48_000),
                presentationEnd: MeetingMediaTime(value: Int64((chunkStart + 60) * 48_000), timescale: 48_000),
                discontinuities: [],
                sha256: "x",
                byteCount: 1,
                finalizationState: .finalized
            )]
        )
        track.captureMethod = captureMethod
        track.clockDrift = drift
        return track
    }

    /// Era anchored at origin-relative 0, mirroring a single-era track starting at the session origin.
    private func makeEra(drift: MeetingClockDriftRecord?, captureMethod: MeetingAudioTrackCaptureMethod?) -> MeetingCaptureEra {
        MeetingCaptureEra(
            method: captureMethod ?? .avCaptureSession,
            deviceUID: nil,
            deviceName: nil,
            roleAtElection: .unknown,
            startSeconds: 0,
            clockDrift: drift
        )
    }

    /// Drives the REAL clock fast-mic (host elapses SLOWER than frame count — the mirror of
    /// `testSlowDriftNeverFiresTheStepDetector`), then asserts the transform compresses the timeline.
    func testDeDriftCorrectsAFastMicAndTheInverseFormulaFails() {
        var clock = MeetingMicrophonePTSClock(timebase: mach_timebase_info_data_t(numer: 1, denom: 1))
        let ppm = 6.7e-6
        let windowSeconds = 0.1
        let windows = 9500 // 950s: past the ~12.5min materiality crossover at 6.7ppm
        for i in 0..<windows {
            let hostSeconds = Double(i) * windowSeconds * (1 - ppm) // fast mic: less host time per window
            _ = clock.stamp(hostTime: UInt64(hostSeconds * 1_000_000_000), frameCount: 4800)
        }
        let elapsed = Double(windows - 1) * windowSeconds * (1 - ppm)
        let cumulative = clock.cumulativeAbsorbedCorrectionSeconds
        XCTAssertLessThan(cumulative, 0, "a fast mic must show a NEGATIVE cumulative absorbed correction")
        XCTAssertGreaterThan(abs(cumulative), MeetingMicrophoneDeDrift.materialityThresholdSeconds)

        let drift = MeetingClockDriftRecord(cumulativeAbsorbedSeconds: cumulative, elapsedValidHostSeconds: elapsed, eligible: true)
        let era = self.makeEra(drift: drift, captureMethod: .voiceProcessing)

        let rawEnd = Double(windows) * windowSeconds
        let corrected = MeetingMicrophoneDeDrift.correct(rawEnd, era: era, eraEndRelative: nil)
        XCTAssertLessThan(corrected, rawEnd, "correction must compress the fast timeline toward the reference, not expand it")
        XCTAssertEqual(corrected, rawEnd + cumulative, accuracy: 0.05, "k = 1 + cumulative/elapsed applied against the reference")

        // The v1 sign-bug inverse transform must move the WRONG direction (expand, not compress).
        let fraction = cumulative / elapsed
        let inverseCorrected = rawEnd / (1 + fraction)
        XCTAssertGreaterThan(inverseCorrected, rawEnd, "the inverted formula moves the WRONG direction — expands instead of compresses")
    }

    func testDeDriftIsANoOpWhenIneligible() {
        let drift = MeetingClockDriftRecord(cumulativeAbsorbedSeconds: -0.05, elapsedValidHostSeconds: 300, eligible: false)
        let era = self.makeEra(drift: drift, captureMethod: .voiceProcessing)
        XCTAssertEqual(MeetingMicrophoneDeDrift.correct(120, era: era, eraEndRelative: nil), 120)
    }

    func testDeDriftIsANoOpForNonVoiceProcessingTracks() {
        let drift = MeetingClockDriftRecord(cumulativeAbsorbedSeconds: -0.05, elapsedValidHostSeconds: 300, eligible: true)
        let era = self.makeEra(drift: drift, captureMethod: .screenCaptureKit)
        XCTAssertEqual(MeetingMicrophoneDeDrift.correct(120, era: era, eraEndRelative: nil), 120)
    }

    func testDeDriftIsANoOpBelowMaterialityThreshold() {
        // 1ms cumulative over 300s is below the 5ms materiality gate.
        let drift = MeetingClockDriftRecord(cumulativeAbsorbedSeconds: -0.001, elapsedValidHostSeconds: 300, eligible: true)
        let era = self.makeEra(drift: drift, captureMethod: .voiceProcessing)
        XCTAssertEqual(MeetingMicrophoneDeDrift.correct(120, era: era, eraEndRelative: nil), 120)
    }

    // MARK: - Ring flush pacing

    /// flushBatch's pacing (4 samples / 5ms) against a real writer: a full ~5s ring must not trip backpressure.
    func testPacedRingFlushProducesNoWriterBackpressure() async throws {
        let sessionDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }
        let track = MeetingAudioTrack(
            id: UUID(),
            kind: .microphone,
            sourceIdentifier: "mic",
            sourceDisplayName: "Mic",
            format: nil,
            timebase: MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil),
            health: .waiting,
            chunks: []
        )
        let backpressureCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let writer = try MeetingAudioChunkWriter(track: track, sessionDirectory: sessionDirectory, chunkDuration: 60) { event in
            if case .interrupted(.writerBackpressure, _, _) = event {
                backpressureCount.withLock { $0 += 1 }
            }
        }

        let samples = (0..<50).map { self.makeSampleBuffer(ptsSeconds: Double($0) * 0.1) }
        for (index, sample) in samples.enumerated() {
            writer.enqueue(sample)
            if index % 4 == 3 {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        _ = await writer.stop()
        XCTAssertEqual(backpressureCount.withLock { $0 }, 0)
    }

    // MARK: - Provenance promotion

    func testProvenanceIsPessimisticThenPromotedOnCommit() async throws {
        let sessionDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }
        let track = MeetingAudioTrack(
            id: UUID(),
            kind: .microphone,
            sourceIdentifier: "mic",
            sourceDisplayName: "Mic",
            format: nil,
            timebase: MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil),
            health: .waiting,
            chunks: [],
            captureMethod: .screenCaptureKit
        )
        let writer = try MeetingAudioChunkWriter(track: track, sessionDirectory: sessionDirectory, chunkDuration: 60) { _ in }

        let beforeCommit = await writer.snapshot()
        XCTAssertEqual(beforeCommit.captureMethod, .screenCaptureKit, "pessimistic default before any commit")

        try await writer.updateTrackMetadata { track in
            track.captureMethod = .voiceProcessing
        }
        let afterCommit = await writer.snapshot()
        XCTAssertEqual(afterCommit.captureMethod, .voiceProcessing)
        _ = await writer.stop()
    }

    // MARK: - Codable tolerance

    func testUnknownCaptureMethodRawValueDecodesToNil() throws {
        var track = self.makeTrack(chunkStart: 0, drift: nil, captureMethod: .voiceProcessing)
        track.captureMethod = nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(track)
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["captureMethod"] = "someFutureCaptureMethodThisBuildDoesNotKnow"
        data = try JSONSerialization.data(withJSONObject: json)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MeetingAudioTrack.self, from: data)
        XCTAssertNil(decoded.captureMethod, "an unrecognized raw value must decode to nil, not throw")
    }

    func testPreExistingJSONWithoutCaptureMethodDecodesWithNilFields() throws {
        let track = self.makeTrack(chunkStart: 0, drift: nil, captureMethod: .voiceProcessing)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(track)
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "captureMethod")
        json.removeValue(forKey: "voiceProcessingConfig")
        json.removeValue(forKey: "clockDrift")
        data = try JSONSerialization.data(withJSONObject: json)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MeetingAudioTrack.self, from: data)
        XCTAssertNil(decoded.captureMethod)
        XCTAssertNil(decoded.voiceProcessingConfig)
        XCTAssertNil(decoded.clockDrift)
    }

    func testCaptureMethodAndDriftRoundTripThroughCodable() throws {
        let drift = MeetingClockDriftRecord(cumulativeAbsorbedSeconds: -0.02, elapsedValidHostSeconds: 300, eligible: true)
        let track = self.makeTrack(chunkStart: 0, drift: drift, captureMethod: .voiceProcessing)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MeetingAudioTrack.self, from: encoder.encode(track))
        XCTAssertEqual(decoded.captureMethod, .voiceProcessing)
        XCTAssertEqual(decoded.clockDrift, drift)
    }

    // MARK: - Sheet default mic preselection

    private func identity(_ deviceID: String, uid: String?, role: MeetingMicrophoneRole = .unknown) -> MeetingMicrophoneIdentity {
        MeetingMicrophoneIdentity(captureDeviceID: deviceID, coreAudioUID: uid, displayName: deviceID, role: role)
    }

    func testPreselectionPrefersSystemDefaultOverSavedDevice() {
        let identities = [
            self.identity("saved", uid: "saved-uid", role: .personal),
            self.identity("default", uid: "default-uid"),
        ]
        let selection = MeetingMicrophonePreselection.select(
            identities: identities,
            savedDeviceID: "saved",
            savedRole: .personal,
            systemDefaultUID: "default-uid",
            preferredInputUID: nil,
            systemDefaultCaptureID: nil
        )
        XCTAssertEqual(selection.deviceID, "default")
        XCTAssertEqual(selection.role, .unknown)
    }

    func testPreselectionNeutralizesSavedRoleEvenWhenDeviceMatches() {
        let identities = [self.identity("saved", uid: "saved-uid", role: .personal)]
        let selection = MeetingMicrophonePreselection.select(
            identities: identities,
            savedDeviceID: "saved",
            savedRole: .personal,
            systemDefaultUID: "saved-uid",
            preferredInputUID: nil,
            systemDefaultCaptureID: nil
        )
        XCTAssertEqual(selection.deviceID, "saved")
        XCTAssertEqual(selection.role, .unknown)
    }

    /// System default → preferred input UID → `AVCaptureDevice.default` unique ID → first identity.
    func testPreselectionFallsBackThroughPreferredInputThenCaptureDeviceIDThenFirstIdentity() {
        let identities = [
            self.identity("a", uid: "a-uid"),
            self.identity("b", uid: "b-uid"),
            self.identity("c", uid: nil),
        ]
        let byPreferredInput = MeetingMicrophonePreselection.select(
            identities: identities,
            savedDeviceID: nil,
            savedRole: .unknown,
            systemDefaultUID: "no-match-uid",
            preferredInputUID: "b-uid",
            systemDefaultCaptureID: "a"
        )
        XCTAssertEqual(byPreferredInput.deviceID, "b", "preferred input UID must win over the AVCaptureDevice.default fallback")

        let byCaptureID = MeetingMicrophonePreselection.select(
            identities: identities,
            savedDeviceID: nil,
            savedRole: .unknown,
            systemDefaultUID: "no-match-uid",
            preferredInputUID: "no-match-uid",
            systemDefaultCaptureID: "a"
        )
        XCTAssertEqual(byCaptureID.deviceID, "a")

        let byFirst = MeetingMicrophonePreselection.select(
            identities: identities,
            savedDeviceID: nil,
            savedRole: .unknown,
            systemDefaultUID: "no-match-uid",
            preferredInputUID: "no-match-uid",
            systemDefaultCaptureID: "no-match-id"
        )
        XCTAssertEqual(byFirst.deviceID, "a")
    }

    func testPreselectionWithEmptyIdentitiesReturnsNil() {
        let selection = MeetingMicrophonePreselection.select(
            identities: [],
            savedDeviceID: "saved",
            savedRole: .personal,
            systemDefaultUID: "default-uid",
            preferredInputUID: "preferred-uid",
            systemDefaultCaptureID: "default-id"
        )
        XCTAssertNil(selection.deviceID)
        XCTAssertEqual(selection.role, .unknown)
    }
}

final class MeetingScreenCaptureRecoveryTests: XCTestCase {
    func testTransientFailuresRemainRetryableWhenApplicationsAndCaptureServiceRestart() {
        let codes: [SCStreamError.Code] = [
            .failedToStart, .failedApplicationConnectionInvalid, .failedApplicationConnectionInterrupted,
            .failedNoMatchingApplicationContext, .internalError, .noWindowList, .noDisplayList,
            .noCaptureSource, .failedToStartAudioCapture, .failedToStartMicrophoneCapture, .systemStoppedStream,
        ]
        for code in codes {
            XCTAssertTrue(MeetingScreenCaptureRecoveryPolicy.shouldRetry(NSError(domain: SCStreamErrorDomain, code: code.rawValue)))
        }
        XCTAssertTrue(MeetingScreenCaptureRecoveryPolicy.shouldRetry(MeetingCaptureError.applicationUnavailable("Fixture")))
        XCTAssertTrue(MeetingScreenCaptureRecoveryPolicy.shouldRetry(MeetingCaptureError.noCaptureDisplay))
    }

    func testDisconnectedInputIsReelectedDuringRecoveryAndOnlyCommittedInputGetsEra() throws {
        let headset = MeetingMicrophoneIdentity(
            captureDeviceID: "headset", coreAudioUID: "headset", avCaptureDeviceID: "headset-av",
            displayName: "Headset", role: .personal
        )
        let builtIn = MeetingMicrophoneIdentity(
            captureDeviceID: "built-in", coreAudioUID: "built-in", displayName: "Built-in", role: .shared
        )
        var track = MeetingAudioTrack(
            id: UUID(), kind: .microphone, sourceIdentifier: "headset", sourceDisplayName: "Headset",
            format: nil,
            timebase: MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil),
            health: .waiting, chunks: []
        )
        track.captureEras = [MeetingCaptureEra(
            method: .screenCaptureKit, deviceUID: "headset", deviceName: "Headset",
            roleAtElection: .unknown, echoProtection: .acousticallyClosed, startSeconds: 0
        )]
        // An unplug can temporarily leave the CoreAudio default unmatched. Never rebind the
        // frozen headset or alter its recorded provenance just because a retry is scheduled.
        XCTAssertEqual(MeetingCaptureDeviceElection.decideTransition(
            from: headset, catalog: [], defaultInputUID: "headset"
        ), .unavailable)
        XCTAssertEqual(track.captureEras?.count, 1)
        XCTAssertTrue(MeetingScreenCaptureRecoveryPolicy.shouldRetry(MeetingCaptureError.microphoneUnavailable))
        guard case let .changed(elected) = MeetingCaptureDeviceElection.decideTransition(
            from: headset, catalog: [builtIn], defaultInputUID: "built-in"
        ) else { return XCTFail("Recovery must elect the newly available default input") }
        XCTAssertEqual(elected.identity.coreAudioUID, "built-in")
        XCTAssertNil(elected.identity.avCaptureDeviceID, "Removed headset AVCapture identity cannot leak to the new input")
        XCTAssertEqual(track.captureEras?.last?.deviceUID, "headset", "An election is not producer publication")
        XCTAssertEqual(MeetingCaptureOwnershipGate.mayPublishReplacement(
            authorizedRevision: 4, currentRevision: 5, stopping: false, candidateFailed: false,
            ownsExpectedOldStream: true, ownsPendingCandidate: true
        ), .superseded, "A route change during native start requires retirement before a fresh retry")
        MeetingScreenCaptureRecoveryPolicy.applyRecoveredMicrophoneEra(
            to: &track, microphone: elected.identity, startSeconds: 12
        )
        let eras = try XCTUnwrap(track.captureEras)
        XCTAssertEqual(eras.count, 2)
        XCTAssertEqual(eras[0].deviceUID, "headset")
        XCTAssertEqual(eras[1].deviceUID, "built-in")
        XCTAssertEqual(eras[1].startSeconds, 12)
        XCTAssertEqual(eras[1].echoProtection, .unprotected)
        XCTAssertEqual(MeetingCaptureDeviceElection.decideTransition(
            from: elected.identity, catalog: [builtIn], defaultInputUID: "built-in"
        ), .unchanged(MeetingCaptureDeviceElection.decide(
            original: elected.identity, catalog: [builtIn], defaultInputUID: "built-in"
        )))
    }

    func testExplicitUserStopRevokedPermissionAndInvalidConfigurationAreTerminal() {
        let codes: [SCStreamError.Code] = [.userStopped, .userDeclined, .missingEntitlements, .invalidParameter, .attemptToStartStreamState]
        for code in codes {
            XCTAssertFalse(MeetingScreenCaptureRecoveryPolicy.shouldRetry(NSError(domain: SCStreamErrorDomain, code: code.rawValue)))
        }
        XCTAssertFalse(MeetingScreenCaptureRecoveryPolicy.shouldRetry(NSError(domain: SCStreamErrorDomain, code: -9999)))
        XCTAssertFalse(MeetingScreenCaptureRecoveryPolicy.shouldRetry(NSError(domain: "Fixture", code: -3804)))
        XCTAssertFalse(MeetingScreenCaptureRecoveryPolicy.shouldRetry(MeetingCaptureError.screenCapturePermissionDenied("Denied")))
        XCTAssertTrue(MeetingScreenCaptureRecoveryPolicy.isPermissionFailure(NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)))
        XCTAssertFalse(MeetingScreenCaptureRecoveryPolicy.isPermissionFailure(NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.internalError.rawValue)))
    }

    func testRecoveryContinuesAfterFourthAttemptWithBoundedBackoffAndState() {
        var backoff = MeetingCaptureRecoveryBackoff()
        XCTAssertEqual((0..<6).map { _ in backoff.nextDelayNanoseconds() }, [500_000_000, 1_000_000_000, 2_000_000_000, 4_000_000_000, 5_000_000_000, 5_000_000_000])
        for _ in 0..<10_000 { XCTAssertEqual(backoff.nextDelayNanoseconds(), 5_000_000_000) }
    }

    func testStopCancelsWaitingRecoveryWithoutStartingAnotherAttempt() async {
        let startedWaiting = expectation(description: "Waiting to recover")
        let task = Task { () -> Bool in
            var backoff = MeetingCaptureRecoveryBackoff()
            for _ in 0..<10 { _ = backoff.nextDelayNanoseconds() }
            startedWaiting.fulfill()
            do {
                try await backoff.waitForRetry()
                return true
            } catch is CancellationError {
                return false
            } catch {
                XCTFail("Unexpected error: \(error)")
                return true
            }
        }
        await fulfillment(of: [startedWaiting], timeout: 1)
        task.cancel()
        let startedAnotherAttempt = await task.value
        XCTAssertFalse(startedAnotherAttempt)
    }

    func testFailedRetirementCannotAuthorizeAnotherProducer() {
        XCTAssertFalse(MeetingScreenCaptureRecoveryPolicy.mayReplaceRetiredCandidate(stopSucceeded: false, didStopReceived: false))
        XCTAssertTrue(MeetingScreenCaptureRecoveryPolicy.mayReplaceRetiredCandidate(stopSucceeded: true, didStopReceived: false))
        XCTAssertTrue(MeetingScreenCaptureRecoveryPolicy.mayReplaceRetiredCandidate(stopSucceeded: false, didStopReceived: true))
    }

    func testOnlyLiveOwnedProducerCanAdmitSamplesIncludingSilence() {
        for stopping in [false, true] {
            for rebuilding in [false, true] {
                for stopped in [false, true] {
                    for ownsProducer in [false, true] {
                        XCTAssertEqual(MeetingScreenCaptureRecoveryPolicy.mayAdmitSample(
                            stopping: stopping,
                            rebuilding: rebuilding,
                            producerStopped: stopped,
                            ownsCurrentProducer: ownsProducer
                        ), !stopping && !rebuilding && !stopped && ownsProducer)
                    }
                }
            }
        }
        // Admission deliberately has no amplitude or elapsed-silence input. Zero PCM is valid.
    }
}

/// The native adapters use this production boundary before privacy, persistence, VAD and ASR.
/// Synthetic CMTimebases exercise source clock conversion without opening a capture device.
final class MeetingNativeCaptureClockTests: XCTestCase {
    private func recordingClock(origin: Double = 100) throws -> MeetingRecordingClock {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return try MeetingRecordingClock(timebase: .init(
            startedHostTime: AVAudioTime.hostTime(forSeconds: origin),
            machTimebaseNumerator: info.numer, machTimebaseDenominator: info.denom,
            firstPresentationTime: nil))
    }

    private func packet(start: Double, frames: Int = 4_800, rate: Double = 48_000) throws -> CMSampleBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: rate, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<frames { samples[index] = index.isMultiple(of: 2) ? 0.25 : -0.25 }
        return try XCTUnwrap(meetingMicrophoneSynthesizeSampleBuffer(from: buffer,
            presentationTime: CMTime(seconds: start, preferredTimescale: 1_000_000_000)))
    }

    private func sourceClock(rate: Double = 1, sourceStart: Double = 0, hostStart: Double = 100) throws -> CMTimebase {
        var result: CMTimebase?
        XCTAssertEqual(CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(), timebaseOut: &result), noErr)
        let clock = try XCTUnwrap(result)
        XCTAssertEqual(CMTimebaseSetRateAndAnchorTime(clock, rate: rate,
            anchorTime: CMTime(seconds: sourceStart, preferredTimescale: 1_000_000_000),
            immediateSourceTime: CMTime(seconds: hostStart, preferredTimescale: 1_000_000_000)), noErr)
        return clock
    }

    func testNativeClockDriftUsesHostIntervalsForBothRateDirections() throws {
        for rate in [0.9997, 1.0003] {
            let context = try self.recordingClock().source(UUID())
            let source = MeetingCaptureSourceClock(context: context)
            let nativeClock = try self.sourceClock(rate: rate)
            XCTAssertTrue(try source.offer(self.packet(start: 0), producerGeneration: 1,
                sourceClock: nativeClock).isEmpty)
            let output = try XCTUnwrap(source.offer(self.packet(start: 0.1), producerGeneration: 1,
                sourceClock: nativeClock).first)
            let metadata = try XCTUnwrap(MeetingCaptureClockMetadata.read(from: output))
            let span = try XCTUnwrap(metadata.mapping.spans.first)
            XCTAssertTrue(context.accepts(metadata))
            XCTAssertEqual(span.hostStart.seconds, 100, accuracy: 0.000_001)
            XCTAssertEqual(span.hostEnd.seconds, 100 + 0.1 / rate, accuracy: 0.000_001)
            XCTAssertEqual(CMSampleBufferGetNumSamples(output), 4_800)
            XCTAssertEqual(CMSampleBufferGetDuration(output).seconds, 0.1 / rate, accuracy: 0.000_001)
            XCTAssertEqual(try source.finish().count, 1)
            XCTAssertTrue(try source.finish().isEmpty)
        }
    }

    func testContiguousNativeFramesUseMeasuredJitteredAnchorsWithoutFalseBoundaries() throws {
        let context = try self.recordingClock().source(UUID())
        let source = MeetingCaptureSourceClock(context: context)
        var outputs: [CMSampleBuffer] = []
        let hostStarts = (0..<20).map { 101 + Double($0) * 0.1 + ($0.isMultiple(of: 2) ? 0.001 : -0.001) }
        // Delivery is deliberately a synchronous burst. Its arrival time cannot become acquisition time.
        for index in hostStarts.indices {
            outputs += try source.offer(self.packet(start: Double(index) * 0.1), producerGeneration: 1,
                acquisitionStart: CMTime(seconds: hostStarts[index], preferredTimescale: 1_000_000_000),
                sourceFrameStart: Int64(index * 4_800))
        }
        XCTAssertEqual(outputs.count, 19, "Only one finite packet awaits its next acquisition anchor")
        var firstEpoch: UInt64?
        for (index, output) in outputs.enumerated() {
            let metadata = try XCTUnwrap(MeetingCaptureClockMetadata.read(from: output))
            let span = try XCTUnwrap(metadata.mapping.spans.first)
            XCTAssertEqual(span.hostStart.seconds, hostStarts[index], accuracy: 0.000_001)
            XCTAssertEqual(span.hostEnd.seconds, hostStarts[index + 1], accuracy: 0.000_001)
            XCTAssertEqual(span.discontinuityBefore, index == 0)
            if let firstEpoch { XCTAssertEqual(metadata.producerEpoch, firstEpoch) }
            else { firstEpoch = metadata.producerEpoch }
        }
        XCTAssertEqual(try source.finish().count, 1)
    }

    func testRealNativeGapIsNotPaddedOrStretchedIntoRecordedAudio() throws {
        let context = try self.recordingClock().source(UUID())
        let source = MeetingCaptureSourceClock(context: context)
        XCTAssertTrue(try source.offer(self.packet(start: 100), producerGeneration: 1).isEmpty)
        let beforeGap = try XCTUnwrap(source.offer(self.packet(start: 102.5), producerGeneration: 1).first)
        let resumed = try XCTUnwrap(source.finish().first)
        let before = try XCTUnwrap(MeetingCaptureClockMetadata.read(from: beforeGap)?.mapping.spans.first)
        let after = try XCTUnwrap(MeetingCaptureClockMetadata.read(from: resumed)?.mapping.spans.first)
        XCTAssertEqual(before.hostEnd.seconds, 100.1, accuracy: 0.000_001)
        XCTAssertEqual(after.hostStart.seconds, 102.5, accuracy: 0.000_001)
        XCTAssertTrue(after.discontinuityBefore)
        XCTAssertEqual(CMSampleBufferGetNumSamples(beforeGap) + CMSampleBufferGetNumSamples(resumed), 9_600)
        XCTAssertEqual(after.hostStart.seconds - before.hostEnd.seconds, 2.4, accuracy: 0.000_001)
    }

    func testReplacementProducerConvertsResetPTSAndRejectsRetiredGeneration() throws {
        let clock = try self.recordingClock()
        let context = clock.source(UUID())
        let source = MeetingCaptureSourceClock(context: context)
        let oldClock = try self.sourceClock(hostStart: 100)
        let replacementClock = try self.sourceClock(hostStart: 105)
        XCTAssertTrue(try source.offer(self.packet(start: 0), producerGeneration: 7, sourceClock: oldClock).isEmpty)
        let oldTail = try XCTUnwrap(source.offer(self.packet(start: 0), producerGeneration: 8,
            sourceClock: replacementClock).first)
        XCTAssertThrowsError(try source.offer(self.packet(start: 0.1), producerGeneration: 7,
            sourceClock: oldClock)) { error in
                guard case MeetingRecordingClock.Failure.retiredProducer = error else {
                    return XCTFail("Expected a retired producer refusal, received \(error)")
                }
            }
        let replacement = try XCTUnwrap(source.finish().first)
        let oldMetadata = try XCTUnwrap(MeetingCaptureClockMetadata.read(from: oldTail))
        let newMetadata = try XCTUnwrap(MeetingCaptureClockMetadata.read(from: replacement))
        XCTAssertNotEqual(oldMetadata.producerEpoch, newMetadata.producerEpoch)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(oldTail).seconds, 100, accuracy: 0.000_001)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(replacement).seconds, 105, accuracy: 0.000_001)
        XCTAssertTrue(try XCTUnwrap(newMetadata.mapping.spans.first).discontinuityBefore)
        XCTAssertEqual(clock.origin.seconds, 100, accuracy: 0.000_001)
        XCTAssertEqual(newMetadata.clockID, oldMetadata.clockID)
    }

    func testRateChangeRetiresOnePendingPacketAndKeepsIndependentSourceOwnership() throws {
        let clock = try self.recordingClock()
        let context = clock.source(UUID()), sibling = clock.source(UUID())
        let source = MeetingCaptureSourceClock(context: context)
        XCTAssertTrue(try source.offer(self.packet(start: 100), producerGeneration: 1).isEmpty)
        let old = try XCTUnwrap(source.offer(self.packet(start: 100.1, frames: 4_410, rate: 44_100),
            producerGeneration: 1).first)
        let new = try XCTUnwrap(source.finish().first)
        let oldPacket = try XCTUnwrap(MeetingCaptureClockMetadata.read(from: old))
        let newPacket = try XCTUnwrap(MeetingCaptureClockMetadata.read(from: new))
        XCTAssertTrue(context.accepts(oldPacket))
        XCTAssertFalse(sibling.accepts(oldPacket))
        XCTAssertNotEqual(oldPacket.producerEpoch, newPacket.producerEpoch)
        XCTAssertEqual(CMSampleBufferGetDuration(old).seconds, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(CMSampleBufferGetDuration(new).seconds, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(CMSampleBufferGetNumSamples(new), 4_410)
        XCTAssertTrue(try source.finish().isEmpty, "Normal stop must not publish the finite tail twice")
    }
}
