import AppKit
@testable import FluidVoice_Debug
import XCTest

@MainActor
final class SettingsBackupRoundTripTests: XCTestCase {
    func testMeetingLocationOnboardingStepResumesWithoutResettingCompletedSetup() throws {
        let suite = "MeetingLocationOnboarding-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "OnboardingCompleted")
        defaults.set(5, forKey: "OnboardingCurrentStep")
        let settings = SettingsStore(defaults: defaults)
        XCTAssertTrue(settings.onboardingCompleted, "Adding an optional step must preserve completed onboarding")
        XCTAssertEqual(settings.onboardingCurrentStep, 5, "The existing AI step keeps its persisted index")

        settings.onboardingCompleted = false
        settings.onboardingCurrentStep = 6
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.onboardingCurrentStep, 6, "The optional location step must survive relaunch")
        XCTAssertFalse(reloaded.onboardingCompleted)
        reloaded.onboardingCurrentStep = 7
        XCTAssertEqual(reloaded.onboardingCurrentStep, 7, "The optional account step must survive relaunch")
        reloaded.onboardingCurrentStep = Int.max
        XCTAssertEqual(reloaded.onboardingCurrentStep, 7)
        defaults.set(Int.max, forKey: "OnboardingCurrentStep")
        XCTAssertEqual(reloaded.onboardingCurrentStep, 7)
        reloaded.onboardingCurrentStep = -1
        XCTAssertEqual(reloaded.onboardingCurrentStep, 0)
    }

    func testHoldSpaceMuteRoundTripsAndLegacyBackupDefaultsOff() throws {
        try self.withSavedDefaults {
            let settings = SettingsStore.shared
            let meeting = self.meetingDefaults()
            settings.meetingRecordingDefaults = meeting
            settings.holdSpaceToMute = true
            let encoded = try JSONEncoder().encode(settings.makeBackupPayload())
            let decoded = try JSONDecoder().decode(SettingsBackupPayload.self, from: encoded)
            XCTAssertEqual(decoded.holdSpaceToMute, true)
            settings.holdSpaceToMute = false
            settings.restore(from: decoded)
            XCTAssertTrue(settings.holdSpaceToMute)
            XCTAssertEqual(settings.meetingRecordingDefaults, meeting)

            let legacy = try self.payload(removing: ["holdSpaceToMute"])
            XCTAssertNil(legacy.holdSpaceToMute)
            settings.restore(from: legacy)
            XCTAssertFalse(settings.holdSpaceToMute)
            XCTAssertEqual(settings.meetingRecordingDefaults, meeting)
        }
    }

    func testProviderConnectionMetadataRoundTripsWithoutSecretsAndLegacyPreservesValues() throws {
        try self.withSavedDefaults {
            let settings = SettingsStore.shared
            let metadata = ["yandex": ["project": "synthetic-folder"], "gigachat": ["scope": "GIGACHAT_API_B2B"]]
            settings.providerConnectionOptions = metadata.merging(["unknown": ["apiKey": "must-not-export"]]) { old, _ in old }
            XCTAssertEqual(settings.providerConnectionOptions, metadata)
            let encoded = try JSONEncoder().encode(settings.makeBackupPayload())
            XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("must-not-export"))
            let decoded = try JSONDecoder().decode(SettingsBackupPayload.self, from: encoded)
            XCTAssertEqual(decoded.providerConnectionOptions, metadata)
            settings.providerConnectionOptions = [:]
            settings.restore(from: decoded)
            XCTAssertEqual(settings.providerConnectionOptions, metadata)
            let legacy = try self.payload(removing: ["providerConnectionOptions"])
            settings.restore(from: legacy)
            XCTAssertEqual(settings.providerConnectionOptions, metadata)
            var cleared = decoded
            cleared.providerConnectionOptions = [:]
            settings.restore(from: cleared)
            XCTAssertTrue(settings.providerConnectionOptions.isEmpty)
        }
    }

    func testDetailedAnalyticsDefaultsOffWithoutWritingConsent() throws {
        let suite = "AnalyticsConsentTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(defaults.object(forKey: "ShareAnonymousAnalytics"))
        XCTAssertFalse(SettingsStore.detailedAnalyticsEnabled(in: defaults))
        XCTAssertNil(defaults.object(forKey: "ShareAnonymousAnalytics"))
    }

    func testDetailedAnalyticsPreservesExplicitLegacyChoicesAcrossReload() throws {
        let suite = "AnalyticsConsentTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for consent in [true, false] {
            defaults.set(consent, forKey: "ShareAnonymousAnalytics")
            let reloaded = try XCTUnwrap(UserDefaults(suiteName: suite))
            XCTAssertEqual(SettingsStore.detailedAnalyticsEnabled(in: reloaded), consent)
            XCTAssertEqual(reloaded.object(forKey: "ShareAnonymousAnalytics") as? Bool, consent)
        }
    }

    func testModernBackupExportsAndRestoresMeetingIdleAndPromptConfiguration() throws {
        try self.withSavedDefaults {
            let settings = SettingsStore.shared
            let profile = self.profile(id: "backup-dictation")
            let meeting = self.meetingDefaults()
            let configurations = self.configurations(profileID: profile.id)
            settings.dictationPromptProfiles = [profile]
            settings.meetingRecordingDefaults = meeting
            settings.privateAIIdleUnload = .oneHour
            settings.dictationPromptConfigurations = configurations
            let payload = settings.makeBackupPayload()
            let encoded = try JSONEncoder().encode(payload)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertNotNil(json["meetingRecordingDefaults"])
            XCTAssertEqual(json["privateAIIdleUnload"] as? Int, 60)
            XCTAssertNotNil(json["dictationPromptConfigurations"])

            settings.meetingRecordingDefaults = .unconfigured
            settings.privateAIIdleUnload = .never
            settings.dictationPromptConfigurations = [:]
            settings.dictationPromptProfiles = []
            try settings.restore(
                from: JSONDecoder().decode(SettingsBackupPayload.self, from: encoded),
                promptProfiles: [profile],
                appPromptBindings: []
            )
            XCTAssertEqual(settings.meetingRecordingDefaults, meeting)
            XCTAssertEqual(settings.privateAIIdleUnload, .oneHour)
            XCTAssertEqual(settings.dictationPromptConfigurations, configurations)
            XCTAssertEqual(settings.dictationPromptShortcutAssignments().count, 3)
            XCTAssertEqual(settings.selectedProviderID, payload.selectedProviderID)
            XCTAssertEqual(settings.primaryDictationShortcuts, payload.primaryDictationShortcuts)
        }
    }

    func testLegacyAbsentFieldsPreserveCurrentPreferences() throws {
        try self.withSavedDefaults {
            let settings = SettingsStore.shared
            let profile = self.profile(id: "legacy-survivor")
            settings.dictationPromptProfiles = [profile]
            let payload = try self.payload(removing: [
                "meetingRecordingDefaults", "privateAIIdleUnload", "dictationPromptConfigurations",
            ])
            let meeting = self.meetingDefaults()
            let configurations = self.configurations(profileID: profile.id)
            settings.meetingRecordingDefaults = meeting
            settings.privateAIIdleUnload = .thirtyMinutes
            settings.dictationPromptConfigurations = configurations
            settings.restore(from: payload, promptProfiles: [profile], appPromptBindings: [])
            XCTAssertEqual(settings.meetingRecordingDefaults, meeting)
            XCTAssertEqual(settings.privateAIIdleUnload, .thirtyMinutes)
            XCTAssertEqual(settings.dictationPromptConfigurations, configurations)
        }
    }

    func testExplicitEmptyPromptConfigurationsClearPreviousMappings() throws {
        try self.withSavedDefaults {
            let settings = SettingsStore.shared
            settings.dictationPromptConfigurations = [:]
            let payload = settings.makeBackupPayload()
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
            XCTAssertEqual((json["dictationPromptConfigurations"] as? [String: Any])?.count, 0)
            settings.dictationPromptConfigurations = self.configurations(profileID: "previous")
            settings.restore(from: payload, promptProfiles: [], appPromptBindings: [])
            XCTAssertTrue(settings.dictationPromptConfigurations.isEmpty)
            XCTAssertTrue(settings.dictationPromptShortcutAssignments().isEmpty)
        }
    }

    func testImportedPromptConfigurationsUseRestoredProfilesAndCannotActivateInvalidReferences() throws {
        try self.withSavedDefaults {
            let settings = SettingsStore.shared
            let valid = self.profile(id: "imported")
            let edit = self.profile(id: "edit-only", mode: .edit)
            let shortcut = HotkeyShortcut(keyCode: 2, modifierFlags: [.control, .option])
            let imported: [String: SettingsStore.DictationPromptConfiguration] = [
                "profile:imported": .init(shortcut: shortcut, providerID: "openai", modelName: "imported-model"),
                "profile:missing": .init(shortcut: shortcut, providerID: "openai", modelName: "missing-model"),
                "profile:edit-only": .init(shortcut: shortcut, providerID: "openai", modelName: "edit-model"),
                "unknown": .init(shortcut: shortcut),
                "__default__": .init(shortcut: HotkeyShortcut(keyCode: 2, modifierFlags: []), providerID: "openai", modelName: "default-model"),
                "__privateAI__": .init(shortcut: shortcut, providerID: "apple-intelligence", modelName: "retired-model"),
            ]
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings.makeBackupPayload())) as? [String: Any])
            json["dictationPromptConfigurations"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(imported))
            let payload = try JSONDecoder().decode(SettingsBackupPayload.self, from: JSONSerialization.data(withJSONObject: json))
            settings.dictationPromptProfiles = [self.profile(id: "previous")]
            settings.dictationPromptConfigurations = ["profile:previous": .init(shortcut: shortcut)]
            settings.restore(from: payload, promptProfiles: [valid, edit], appPromptBindings: [])

            XCTAssertEqual(settings.dictationPromptConfigurations["profile:imported"], imported["profile:imported"])
            XCTAssertNil(settings.dictationPromptConfigurations["profile:missing"])
            XCTAssertNil(settings.dictationPromptConfigurations["profile:edit-only"])
            XCTAssertNil(settings.dictationPromptConfigurations["profile:previous"])
            XCTAssertNil(settings.dictationPromptConfigurations["unknown"])
            XCTAssertNil(settings.dictationPromptConfiguration(for: .default).shortcut)
            XCTAssertEqual(settings.dictationPromptConfiguration(for: .default).modelName, "default-model")
            XCTAssertEqual(settings.dictationPromptConfigurations["__privateAI__"], .init(shortcut: shortcut))
            XCTAssertEqual(settings.dictationPromptShortcutAssignments().count, 2)
            XCTAssertEqual(settings.selectedProviderID, payload.selectedProviderID)
            XCTAssertEqual(settings.primaryDictationShortcuts, payload.primaryDictationShortcuts)
        }
    }

    private func payload(removing keys: [String]) throws -> SettingsBackupPayload {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(SettingsStore.shared.makeBackupPayload())) as? [String: Any])
        for key in keys {
            json.removeValue(forKey: key)
        }
        return try JSONDecoder().decode(SettingsBackupPayload.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func profile(id: String, mode: SettingsStore.PromptMode = .dictate) -> SettingsStore.DictationPromptProfile {
        .init(id: id, name: "Backup fixture", prompt: "Keep these words", mode: mode)
    }

    private func configurations(profileID: String) -> [String: SettingsStore.DictationPromptConfiguration] {
        [
            "__default__": .init(shortcut: HotkeyShortcut(keyCode: 2, modifierFlags: .control), providerID: "openai", modelName: "default-model"),
            "__privateAI__": .init(shortcut: HotkeyShortcut(keyCode: 3, modifierFlags: .control), providerID: "fluid-fixture", modelName: "private-model"),
            "profile:\(profileID)": .init(shortcut: HotkeyShortcut(keyCode: 5, modifierFlags: .control), providerID: "custom:fixture", modelName: "profile-model"),
        ]
    }

    private func meetingDefaults() -> MeetingRecordingDefaults {
        .init(
            isConfigured: true,
            mode: .inRoom,
            applicationBundleIdentifier: "fixture.meeting",
            applicationDisplayName: "Fixture Meeting",
            microphoneCaptureDeviceID: "fixture-capture",
            microphoneCoreAudioUID: "fixture-core-audio",
            microphoneRole: .shared,
            languageCode: "fr"
        )
    }

    private func withSavedDefaults(_ body: () throws -> Void) throws {
        let defaults = UserDefaults.standard
        let domain = try XCTUnwrap(Bundle.main.bundleIdentifier)
        let original = defaults.persistentDomain(forName: domain)
        defer {
            if let original {
                defaults.setPersistentDomain(original, forName: domain)
            } else {
                defaults.removePersistentDomain(forName: domain)
            }
        }
        try body()
    }
}
