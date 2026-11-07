@testable import FluidVoice_Debug
import Foundation
import XCTest

final class MeetingAudioAssetCompatibilityTests: XCTestCase {
    func testRecordingClockMetadataIsAdditiveAndPreservesLegacyDefaults() throws {
        let legacy = Data(#"{"startedHostTime":12,"machTimebaseNumerator":1,"machTimebaseDenominator":1}"#.utf8)
        var timebase = try JSONDecoder().decode(MeetingTimebaseMetadata.self, from: legacy)
        XCTAssertNil(timebase.recordingTimePolicy)
        let oldJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(timebase)) as? [String: Any])
        XCTAssertNil(oldJSON["recordingTimePolicy"])
        timebase.recordingTimePolicy = .hostMonotonicV1
        XCTAssertEqual(try JSONDecoder().decode(MeetingTimebaseMetadata.self, from: JSONEncoder().encode(timebase)), timebase)
        let mapping = MeetingAudioClockMapping(frameCount: 480, spans: [
            .init(frameStart: 0, frameEnd: 480, hostStart: .init(value: 1_000, timescale: 1),
                  hostEnd: .init(value: 1_000_010, timescale: 1_000))])
        XCTAssertEqual(try JSONDecoder().decode(MeetingAudioClockMapping.self, from: JSONEncoder().encode(mapping)), mapping)
        let missingDefaults = Data(#"{"frameCount":1,"spans":[{"frameStart":0,"frameEnd":1,"hostStart":{"value":1,"timescale":1},"hostEnd":{"value":2,"timescale":1}}]}"#.utf8)
        let decoded = try JSONDecoder().decode(MeetingAudioClockMapping.self, from: missingDefaults)
        XCTAssertEqual(decoded.version, 1)
        XCTAssertFalse(try XCTUnwrap(decoded.spans.first).discontinuityBefore)
    }

    func testInRoomHostRecordingPinsItsOriginWhileLegacyKeepsItsOldTimebase() throws {
        let configuration = MeetingCaptureConfiguration(mode: .inRoom, title: "Synthetic clock",
            microphone: .init(captureDeviceID: "mic", displayName: "Mic"))
        let legacyTimebase = MeetingTimebaseMetadata(startedHostTime: 100_000_000_000,
            machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil)
        let legacy = MeetingSession(configuration: configuration, timebase: legacyTimebase)
        XCTAssertNil(legacy.transcriptPresentationOrigin)
        var hostTimebase = legacyTimebase; hostTimebase.recordingTimePolicy = .hostMonotonicV1
        let unified = MeetingSession(configuration: configuration, timebase: hostTimebase)
        XCTAssertEqual(try XCTUnwrap(unified.transcriptPresentationOrigin).seconds, 100)
        XCTAssertEqual(unified.transcriptTimeDomain, .meetingRelative)
        let restored = try JSONDecoder().decode(MeetingSession.self, from: JSONEncoder().encode(unified))
        XCTAssertEqual(restored, unified)
        XCTAssertEqual(MeetingAnalysisManifest.presentationOrigin(of: restored), 100)
    }

    func testSavedHostDurationIgnoresCalendarClockChangesAndLegacyDurationStaysCompatible() throws {
        let configuration = MeetingCaptureConfiguration(mode: .inRoom, title: "Synthetic clock",
            microphone: .init(captureDeviceID: "mic", displayName: "Mic"))
        var session = MeetingSession(configuration: configuration,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            timebase: .init(startedHostTime: 100_000_000_000, machTimebaseNumerator: 1,
                machTimebaseDenominator: 1, firstPresentationTime: nil,
                recordingTimePolicy: .hostMonotonicV1, endedHostTime: 102_500_000_000))
        session.endedAt = session.startedAt.addingTimeInterval(-3_600)
        XCTAssertEqual(session.duration, 2.5)
        let restored = try JSONDecoder().decode(MeetingSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(restored.duration, 2.5)
        session.timebase.recordingTimePolicy = nil
        session.endedAt = session.startedAt.addingTimeInterval(3)
        XCTAssertEqual(session.duration, 3)
    }

    func testHostOriginKeepsNanosecondPrecisionAcrossSavedAndLiveConsumers() throws {
        let configuration = MeetingCaptureConfiguration(mode: .inRoom, title: "Synthetic clock",
            microphone: .init(captureDeviceID: "mic", displayName: "Mic"))
        let timebase = MeetingTimebaseMetadata(startedHostTime: 1_000_123_456_789,
            machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil,
            recordingTimePolicy: .hostMonotonicV1)
        let session = MeetingSession(configuration: configuration, timebase: timebase)
        let live = try MeetingRecordingClock(timebase: timebase)
        XCTAssertEqual(try XCTUnwrap(session.transcriptPresentationOrigin).timescale, 1_000_000_000)
        XCTAssertEqual(MeetingAnalysisManifest.presentationOrigin(of: session), live.origin.seconds, accuracy: 1e-9)
    }

    func testLegacyCheckpointBindsClockAnchorsWithoutChangingUnmappedFingerprintJSON() throws {
        let legacy = try JSONDecoder().decode(MeetingProcessingCheckpoint.ChunkFingerprint.self,
            from: Data(#"{"id":"00000000-0000-0000-0000-000000000001","byteCount":42,"sha256":"same"}"#.utf8))
        XCTAssertNil(legacy.clockMappingDigest)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        XCTAssertNil(json["clockMappingDigest"])
        var chunk = MeetingAudioChunk(id: legacy.id, sequence: 0, relativeFilePath: "tracks/0.caf",
            presentationStart: .init(value: 1_000, timescale: 1), presentationEnd: .init(value: 1_001, timescale: 1),
            discontinuities: [], sha256: legacy.sha256, byteCount: legacy.byteCount, finalizationState: .finalized)
        chunk.clockMapping = .init(frameCount: 16_000, spans: [.init(frameStart: 0, frameEnd: 16_000,
            hostStart: chunk.presentationStart, hostEnd: chunk.presentationEnd)])
        var track = MeetingAudioTrack(id: UUID(), kind: .microphone, sourceIdentifier: "fixture",
            sourceDisplayName: "Fixture", format: nil, timebase: .init(startedHostTime: 0,
                machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil), health: .waiting, chunks: [chunk])
        let before = MeetingProcessingCheckpoint.fingerprints(for: [track])
        track.chunks[0].clockMapping?.spans[0].hostEnd = .init(value: 1_001_001, timescale: 1_000)
        XCTAssertNotEqual(before, MeetingProcessingCheckpoint.fingerprints(for: [track]))
    }

    func testLegacyChunkOmitsAllP0aKeysAndRoundTripsFullSession() throws {
        let chunk = MeetingAudioChunk(
            id: UUID(),
            sequence: 3,
            relativeFilePath: "tracks/microphone/3.caf",
            presentationStart: MeetingMediaTime(value: 0, timescale: 1000),
            presentationEnd: MeetingMediaTime(value: 1000, timescale: 1000),
            discontinuities: [],
            sha256: "legacy",
            byteCount: 42,
            finalizationState: .finalized
        )
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let json = try encoder.encode(chunk)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(
            Set(object.keys),
            Set(["id", "sequence", "relativeFilePath", "presentationStart", "presentationEnd", "discontinuities", "sha256", "byteCount", "finalizationState"])
        )
        XCTAssertNil(object["audioSchemaVersion"]); XCTAssertNil(object["captureAnalysisAsset"]); XCTAssertNil(object["playbackArchiveAsset"])
        let decodedChunk = try JSONDecoder().decode(MeetingAudioChunk.self, from: json)
        XCTAssertEqual(decodedChunk, chunk)

        let configuration = MeetingCaptureConfiguration(mode: .inRoom, title: "Legacy", microphone: MeetingMicrophoneIdentity(captureDeviceID: "mic", displayName: "Mic"))
        var session = MeetingSession(
            configuration: configuration,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            timebase: MeetingTimebaseMetadata(startedHostTime: 1, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil)
        )
        session.audioTracks = [MeetingAudioTrack(
            id: UUID(),
            kind: .microphone,
            sourceIdentifier: "mic",
            sourceDisplayName: "Mic",
            format: nil,
            timebase: session.timebase,
            health: .waiting,
            chunks: [chunk]
        )]
        let sessionData = try encoder.encode(session)
        XCTAssertEqual(try JSONDecoder().decode(MeetingSession.self, from: sessionData), session)
    }

    func testValidPCMAssetRoundTripsAndLegacyReadyMayOmitFrameFacts() throws {
        let asset = MeetingAudioAsset(
            role: .captureAnalysis,
            encoding: .linearPCMFloat32CAFV1,
            presence: .ready,
            relativeFilePath: "tracks/application/1.caf",
            byteCount: 128,
            sha256: String(repeating: "a", count: 64),
            sampleRate: 48_000,
            channelCount: 2,
            frameCount: 16
        )
        let data = try JSONEncoder().encode(asset)
        XCTAssertEqual(try JSONDecoder().decode(MeetingAudioAsset.self, from: data), asset)
        XCTAssertTrue(asset.validationIssues().isEmpty)
        let legacy = MeetingAudioAsset(
            role: .playbackArchive,
            encoding: .legacyAACUnknownPrimingV1,
            presence: .ready,
            relativeFilePath: "audio.m4a",
            byteCount: 1
        )
        XCTAssertTrue(legacy.validationIssues().isEmpty)
    }

    func testUnknownRawValuesRoundTripAndQuarantineOnlyThatAsset() throws {
        let json = Data(#"{"role":"futureRole","encoding":"futureEncoding","presence":"futurePresence","relativeFilePath":"future.bin","byteCount":1}"#.utf8)
        let asset = try JSONDecoder().decode(MeetingAudioAsset.self, from: json)
        XCTAssertEqual(asset.role.rawValue, "futureRole"); XCTAssertEqual(asset.encoding.rawValue, "futureEncoding"); XCTAssertEqual(asset.presence.rawValue, "futurePresence")
        XCTAssertEqual(asset.validationIssues(), [.unknownRole("futureRole"), .unknownEncoding("futureEncoding"), .unknownPresence("futurePresence")])
        let reencoded = try JSONDecoder().decode(MeetingAudioAsset.self, from: JSONEncoder().encode(asset))
        XCTAssertEqual(reencoded, asset)

        let validArchive = MeetingAudioAsset(
            role: .playbackArchive,
            encoding: .aacLCM4AV1,
            presence: .ready,
            relativeFilePath: "tracks/application/archive.m4a",
            byteCount: 64,
            sha256: String(repeating: "b", count: 64),
            sampleRate: 48_000,
            channelCount: 2,
            frameCount: 48_000
        )
        let chunk = MeetingAudioChunk(
            id: UUID(),
            sequence: 0,
            relativeFilePath: "tracks/application/legacy.m4a",
            presentationStart: MeetingMediaTime(value: 0, timescale: 1000),
            presentationEnd: MeetingMediaTime(value: 1000, timescale: 1000),
            discontinuities: [],
            sha256: "legacy",
            byteCount: 1,
            finalizationState: .finalized,
            audioSchemaVersion: 2,
            captureAnalysisAsset: asset,
            playbackArchiveAsset: validArchive
        )
        XCTAssertEqual(chunk.captureAnalysisAsset?.validationIssues(), asset.validationIssues())
        XCTAssertTrue(validArchive.validationIssues().isEmpty)
        XCTAssertTrue(chunk.assetValidationIssues().contains(.unknownRole("futureRole")))
    }

    func testReadyPCMAssetWithoutFactsIsInvalidPurelyFromMetadata() {
        let invalid = MeetingAudioAsset(
            role: .captureAnalysis,
            encoding: .linearPCMFloat32CAFV1,
            presence: .ready,
            relativeFilePath: "tracks/application/1.caf",
            byteCount: 128
        )
        XCTAssertTrue(invalid.validationIssues().contains(.readyAssetMissingHash))
        XCTAssertTrue(invalid.validationIssues().contains(.readyAssetMissingSampleRate))
        XCTAssertTrue(invalid.validationIssues().contains(.readyAssetMissingChannelCount))
        XCTAssertTrue(invalid.validationIssues().contains(.readyAssetMissingFrameCount))
    }
}
