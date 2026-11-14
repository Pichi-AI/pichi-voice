@testable import FluidVoice_Debug
import Foundation
import XCTest

final class MeetingProcessingConfigurationTests: XCTestCase {
    func testDictionaryRulesAreEphemeralAndLegacyIdentitySurvivesDecoding() throws {
        let entry = SettingsStore.CustomDictionaryEntry(triggers: ["synthetic private alias"], replacement: "Synthetic Private Name")
        let frozen = MeetingFinalProcessingConfiguration(customDictionaryRewritingEnabled: true, customDictionaryEntries: [entry])
        let bytes = try JSONEncoder().encode(frozen)
        let json = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(json.contains("synthetic private alias"))
        XCTAssertFalse(json.contains("Synthetic Private Name"))
        let restored = try JSONDecoder().decode(MeetingFinalProcessingConfiguration.self, from: bytes)
        XCTAssertTrue(restored.customDictionaryEntries.isEmpty)
        XCTAssertEqual(restored.identityFingerprint, frozen.identityFingerprint)

        let original = MeetingFinalProcessingConfiguration()
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        legacy.removeValue(forKey: "dictionaryFingerprint")
        let decoded = try JSONDecoder().decode(MeetingFinalProcessingConfiguration.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.identityFingerprint, original.identityFingerprint)
        XCTAssertFalse(decoded.identityFingerprint.contains("dictionaryRules"))
    }
    func testRecordingClockPolicyPinsNewAttemptsWithoutChangingLegacyIdentity() throws {
        let legacy = MeetingFinalProcessingConfiguration()
        XCTAssertNil(legacy.recordingTimePolicy)
        XCTAssertFalse(legacy.identityFingerprint.contains("recordingTimePolicy"))
        let encoded = try JSONEncoder().encode(legacy)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("recordingTimePolicy"))
        XCTAssertEqual(try JSONDecoder().decode(MeetingFinalProcessingConfiguration.self, from: encoded).identityFingerprint,
                       legacy.identityFingerprint)
        let unified = MeetingFinalProcessingConfiguration(recordingTimePolicy: .hostMonotonicV1)
        XCTAssertNotEqual(unified.identityFingerprint, legacy.identityFingerprint)
        XCTAssertEqual(try JSONDecoder().decode(MeetingFinalProcessingConfiguration.self,
            from: JSONEncoder().encode(unified)), unified)
    }

    func testSpeakerProcessingModeMigratesWithoutChangingLegacyIdentity() throws {
        let original = MeetingFinalProcessingConfiguration()
        XCTAssertNil(original.speakerProcessingMode)
        XCTAssertEqual(original.effectiveSpeakerProcessingMode, .afterRecording)
        XCTAssertFalse(original.identityFingerprint.contains("speakerProcessing"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "speakerProcessingMode")
        let decoded = try JSONDecoder().decode(MeetingFinalProcessingConfiguration.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.identityFingerprint, original.identityFingerprint)
        XCTAssertEqual(MeetingFinalProcessingConfiguration(speakerProcessingMode: .afterRecording), original)
    }

    func testStreamingSpeakerModeIsAnImmutableDistinctCodableIdentity() throws {
        let streaming = MeetingFinalProcessingConfiguration(speakerProcessingMode: .streaming)
        let copy = streaming
        XCTAssertEqual(streaming.effectiveSpeakerProcessingMode, .streaming)
        XCTAssertNotEqual(streaming.identityFingerprint, MeetingFinalProcessingConfiguration().identityFingerprint)
        XCTAssertTrue(streaming.identityFingerprint.contains("speakerProcessing"))
        XCTAssertEqual(try JSONDecoder().decode(MeetingFinalProcessingConfiguration.self,
            from: JSONEncoder().encode(streaming)), copy)
        XCTAssertEqual(streaming.asrModel, MeetingFinalProcessingConfiguration().asrModel,
                       "Speaker scheduling is independent of ASR model identity")
    }

    func testDisabledSpeakerLabelsDoNotEnableStreamingOrChangeASRIdentity() {
        let normal = MeetingFinalProcessingConfiguration(speakerLabelsEnabled: false)
        let requested = MeetingFinalProcessingConfiguration(speakerLabelsEnabled: false, speakerProcessingMode: .streaming)
        XCTAssertEqual(requested, normal)
        XCTAssertEqual(requested.identityFingerprint, normal.identityFingerprint)
        XCTAssertEqual(requested.effectiveSpeakerProcessingMode, .afterRecording)
    }

    func testCaptureAndSessionSnapshotSpeakerModeAndMigrateMissingField() throws {
        let capture = MeetingCaptureConfiguration(mode: .inRoom, title: "Synthetic",
            microphone: .init(captureDeviceID: "fixture", displayName: "Fixture"),
            audioStorageMode: .memoryOnly, speakerProcessingMode: .streaming)
        let session = MeetingSession(configuration: capture,
            timebase: .init(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil))
        XCTAssertEqual(session.effectiveSpeakerProcessingMode, .streaming)
        XCTAssertEqual(session.audioStorageMode, .memoryOnly)
        XCTAssertEqual(try JSONDecoder().decode(MeetingSession.self, from: JSONEncoder().encode(session)), session)
        var captureObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(capture)) as? [String: Any])
        captureObject.removeValue(forKey: "speakerProcessingMode")
        let legacyCapture = try JSONDecoder().decode(MeetingCaptureConfiguration.self,
            from: JSONSerialization.data(withJSONObject: captureObject))
        XCTAssertEqual(legacyCapture.effectiveSpeakerProcessingMode, .afterRecording)
        var sessionObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        sessionObject.removeValue(forKey: "speakerProcessingMode")
        let legacySession = try JSONDecoder().decode(MeetingSession.self,
            from: JSONSerialization.data(withJSONObject: sessionObject))
        XCTAssertEqual(legacySession.effectiveSpeakerProcessingMode, .afterRecording)
        XCTAssertEqual(legacySession.audioStorageMode, .memoryOnly, "Mode migration cannot change audio retention")
    }

    func testAttributionPolicyIsFrozenAndLegacyConfigurationsDecodeWithoutIt() throws {
        let configured = MeetingFinalProcessingConfiguration()
        XCTAssertEqual(configured.speakerAttributionPolicy, .standard)
        XCTAssertNotEqual(configured.identityFingerprint,
            MeetingFinalProcessingConfiguration(speakerAttributionPolicy: nil).identityFingerprint)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(configured)) as? [String: Any])
        object.removeValue(forKey: "speakerAttributionPolicy")
        object["pipelineVersion"] = 13
        let legacy = try JSONDecoder().decode(MeetingFinalProcessingConfiguration.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.speakerAttributionPolicy)
        XCTAssertEqual(legacy.pipelineVersion, 13)
        XCTAssertNotEqual(legacy.identityFingerprint, configured.identityFingerprint)
    }

    func testASRArtifactChangesInvalidateConfigurationWithoutChangingLegacyDefaults() {
        let first = MeetingFinalProcessingConfiguration(asrModel: "gigaam-v3-eou", asrArtifactFingerprint: "v5:hash-a", languageCode: "ru")
        let second = MeetingFinalProcessingConfiguration(asrModel: "gigaam-v3-eou", asrArtifactFingerprint: "v3:hash-b", languageCode: "ru")
        XCTAssertNotEqual(first.identityFingerprint, second.identityFingerprint)
        XCTAssertFalse(MeetingFinalProcessingConfiguration().identityFingerprint.contains("asrArtifact"))
    }

    func testDictionarySnapshotAndFingerprintTrackEditsWithoutExposingPrivateWords() {
        var entries: [SettingsStore.CustomDictionaryEntry] = [.init(triggers: ["private alias"], replacement: "Private Name")]
        let frozen = MeetingFinalProcessingConfiguration(customDictionaryRewritingEnabled: true, customDictionaryEntries: entries)
        XCTAssertEqual(frozen.identityFingerprint, MeetingFinalProcessingConfiguration(customDictionaryRewritingEnabled: true, customDictionaryEntries: entries).identityFingerprint)
        entries[0].replacement = "Changed Name"
        let changed = MeetingFinalProcessingConfiguration(customDictionaryRewritingEnabled: true, customDictionaryEntries: entries)
        XCTAssertEqual(frozen.customDictionaryEntries[0].replacement, "Private Name")
        XCTAssertNotEqual(frozen.identityFingerprint, changed.identityFingerprint)
        XCTAssertFalse(frozen.identityFingerprint.contains("private alias"))
        XCTAssertFalse(frozen.identityFingerprint.contains("Private Name"))
        entries[0].triggers.append("another alias")
        XCTAssertNotEqual(changed.identityFingerprint, MeetingFinalProcessingConfiguration(customDictionaryRewritingEnabled: true, customDictionaryEntries: entries).identityFingerprint)
        XCTAssertTrue(MeetingFinalProcessingConfiguration(customDictionaryEntries: entries).customDictionaryEntries.isEmpty)
    }

    func testFinalConfigurationDefaultsAreProEnglishWithoutPostProcessing() {
        let config = MeetingFinalProcessingConfiguration()
        XCTAssertEqual(config.asrModel, "fluid-parakeet-pro")
        XCTAssertEqual(config.languageCode, "en")
        XCTAssertFalse(config.vocabularyBoostingEnabled)
        XCTAssertFalse(config.pronunciationMatchingEnabled)
        XCTAssertFalse(config.customDictionaryRewritingEnabled)
        XCTAssertFalse(config.experimentalUnifiedFinalEnabled)
        XCTAssertEqual(config.pipelineVersion, MeetingFinalProcessingConfiguration.defaultPipelineVersion)
        XCTAssertEqual(config.diarizationFingerprint, MeetingProcessingCheckpoint.currentDiarizationFingerprint)
    }

    @MainActor
    func testFinalConfigurationDefaultPipelineVersionMatchesPipelineConstant() {
        XCTAssertEqual(
            MeetingFinalProcessingConfiguration.defaultPipelineVersion,
            MeetingProcessingPipeline.pipelineVersion
        )
    }

    func testFinalIdentityFingerprintIsStableAndCoversEveryEffectiveField() {
        let base = MeetingFinalProcessingConfiguration()
        XCTAssertEqual(base.identityFingerprint, MeetingFinalProcessingConfiguration().identityFingerprint)
        XCTAssertTrue(base.identityFingerprint.hasPrefix("v\(MeetingConfigFingerprintEncoding.version);"))

        let variants: [MeetingFinalProcessingConfiguration] = [
            MeetingFinalProcessingConfiguration(asrModel: "parakeet-tdt-v3"),
            MeetingFinalProcessingConfiguration(languageCode: "de"),
            MeetingFinalProcessingConfiguration(vocabularyBoostingEnabled: true),
            MeetingFinalProcessingConfiguration(pronunciationMatchingEnabled: true),
            MeetingFinalProcessingConfiguration(customDictionaryRewritingEnabled: true),
            MeetingFinalProcessingConfiguration(experimentalUnifiedFinalEnabled: true),
            MeetingFinalProcessingConfiguration(diarizationFingerprint: "other"),
            MeetingFinalProcessingConfiguration(pipelineVersion: base.pipelineVersion + 1),
        ]
        for variant in variants {
            XCTAssertNotEqual(variant.identityFingerprint, base.identityFingerprint)
        }
        XCTAssertTrue(base.identityFingerprint.contains(MeetingProcessingCheckpoint.currentDiarizationFingerprint))
        XCTAssertTrue(base.identityFingerprint.contains("pipeline"))
        XCTAssertTrue(base.identityFingerprint.contains(String(base.pipelineVersion)))
    }

    func testFinalIdentityFingerprintHasNoDelimiterCollisions() {
        let splitAt = MeetingFinalProcessingConfiguration(asrModel: "a@b", languageCode: "c")
        let splitAtLanguage = MeetingFinalProcessingConfiguration(asrModel: "a", languageCode: "b@c")
        XCTAssertNotEqual(splitAt.identityFingerprint, splitAtLanguage.identityFingerprint)

        let semicolonKey = MeetingFinalProcessingConfiguration(asrModel: "x;lang=de")
        let plain = MeetingFinalProcessingConfiguration(languageCode: "de", vocabularyBoostingEnabled: false)
        XCTAssertNotEqual(semicolonKey.identityFingerprint, plain.identityFingerprint)
    }

    func testLiveCaptionsDefaultsMatchStreamingEouIdentity() {
        let config = MeetingLiveCaptionsConfiguration()
        XCTAssertEqual(config.modelRepositoryID, "FluidInference/parakeet-realtime-eou-120m-coreml")
        XCTAssertEqual(config.modelVariant, "160ms")
        XCTAssertEqual(config.chunkSizeMilliseconds, 160)
        XCTAssertEqual(config.languageCode, "en")
        XCTAssertEqual(config.modelRevision, "main")
    }

    func testLiveCaptionsFingerprintIsStableAndDoesNotClaimResolvedRevision() {
        let base = MeetingLiveCaptionsConfiguration()
        XCTAssertEqual(base.identityFingerprint, MeetingLiveCaptionsConfiguration().identityFingerprint)
        XCTAssertTrue(base.identityFingerprint.hasPrefix("v\(MeetingConfigFingerprintEncoding.version);"))
        XCTAssertTrue(base.identityFingerprint.contains("FluidInference/parakeet-realtime-eou-120m-coreml"))
        XCTAssertTrue(base.identityFingerprint.contains("160ms"))
        XCTAssertTrue(base.identityFingerprint.contains("unresolved"))
        // A resolved HF pin would be a full commit SHA; the loader only selects the branch.
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        XCTAssertFalse(
            base.modelRevision.count == 40
                && base.modelRevision.unicodeScalars.allSatisfy(hex.contains)
        )
    }

    func testLiveCaptionsFingerprintChangesForEveryField() {
        let base = MeetingLiveCaptionsConfiguration()
        let variants: [MeetingLiveCaptionsConfiguration] = [
            MeetingLiveCaptionsConfiguration(modelRepositoryID: "FluidInference/parakeet-realtime-eou-200m-coreml"),
            MeetingLiveCaptionsConfiguration(modelVariant: "320ms"),
            MeetingLiveCaptionsConfiguration(modelRevision: "release"),
            MeetingLiveCaptionsConfiguration(chunkSizeMilliseconds: 320),
            MeetingLiveCaptionsConfiguration(languageCode: "de"),
        ]
        for variant in variants {
            XCTAssertNotEqual(variant.identityFingerprint, base.identityFingerprint)
        }
    }

    func testLiveCaptionsFingerprintHasNoDelimiterCollisions() {
        let splitRepo = MeetingLiveCaptionsConfiguration(modelRepositoryID: "x/y", modelVariant: "z")
        let splitVariant = MeetingLiveCaptionsConfiguration(modelRepositoryID: "x", modelVariant: "y/z")
        XCTAssertNotEqual(splitRepo.identityFingerprint, splitVariant.identityFingerprint)
    }

    func testConfigurationsBehaveAsEquatableValueSnapshots() {
        let final = MeetingFinalProcessingConfiguration()
        let finalCopy = final
        XCTAssertEqual(final, finalCopy)
        XCTAssertEqual(final, MeetingFinalProcessingConfiguration())
        XCTAssertNotEqual(final, MeetingFinalProcessingConfiguration(vocabularyBoostingEnabled: true))
        XCTAssertNotEqual(final, MeetingFinalProcessingConfiguration(pipelineVersion: final.pipelineVersion + 1))

        let captions = MeetingLiveCaptionsConfiguration()
        XCTAssertEqual(captions, MeetingLiveCaptionsConfiguration())
        XCTAssertNotEqual(captions, MeetingLiveCaptionsConfiguration(modelRevision: "abc123"))
    }

    func testFingerprintsMatchForCanonicallyEquivalentUnicode() {
        let composedFinal = MeetingFinalProcessingConfiguration(languageCode: "\u{E9}")
        let decomposedFinal = MeetingFinalProcessingConfiguration(languageCode: "e\u{301}")
        XCTAssertEqual(composedFinal, decomposedFinal)
        XCTAssertEqual(composedFinal.identityFingerprint, decomposedFinal.identityFingerprint)

        let composedCaptions = MeetingLiveCaptionsConfiguration(modelRepositoryID: "Caf\u{E9}")
        let decomposedCaptions = MeetingLiveCaptionsConfiguration(modelRepositoryID: "Cafe\u{301}")
        XCTAssertEqual(composedCaptions, decomposedCaptions)
        XCTAssertEqual(composedCaptions.identityFingerprint, decomposedCaptions.identityFingerprint)
    }

    func testFingerprintGoldenEncodingLocksFramingStability() {
        let encoded = MeetingConfigFingerprintEncoding.encode([
            ("asr", "a@b"),
            ("lang", "e\u{301}"),
        ])
        XCTAssertEqual(encoded, "v1;3:asr=3:a@b;4:lang=2:\u{E9}")
    }
}
