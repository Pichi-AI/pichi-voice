@testable import FluidASRBaselineHost
import XCTest

/// Pins the explicit `enhancementOptions` path of `FluidAudioProvider`. These tests never
/// touch `SettingsStore.shared` and never prepare models; under the baseline host any
/// transitive settings/credentials access would trip the `KeychainService` fatalError guard.
@MainActor
final class ProviderEnhancementOptionsTests: XCTestCase {
    private func setPronunciationGateForTest(_ enabled: Bool) {
        let defaults = UserDefaults.standard
        let key = "DictionarySharedFeatureMatcherEnabled"
        let original = defaults.object(forKey: key)
        defaults.set(enabled, forKey: key)
        self.addTeardownBlock {
            if let original { defaults.set(original, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
    }

    private func makeEntry() -> SettingsStore.CustomDictionaryEntry {
        SettingsStore.CustomDictionaryEntry(
            // Fixed test fixture: missing required audio storage or evidence is a setup failure.
            // swiftlint:disable:next force_unwrapping
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            triggers: ["fluid voice", "fluid boys"],
            replacement: "FluidVoice"
        )
    }

    func testExplicitEnhancementOptionsDriveEffectiveGetters() {
        self.setPronunciationGateForTest(true)
        let entry = self.makeEntry()
        let options = FluidAudioProviderEnhancementOptions(
            experimentalUnifiedFinalEnabled: true,
            pronunciationMatchingEnabled: true,
            customDictionaryEntries: [entry]
        )
        let provider = FluidAudioProvider(configureWordBoosting: false, enhancementOptions: options)
        #if arch(arm64) && DEBUG
        let snapshot = provider.effectiveEnhancementOptionsForTesting
        XCTAssertTrue(snapshot.experimentalUnifiedFinalEnabled)
        XCTAssertTrue(snapshot.pronunciationMatchingEnabled)
        XCTAssertEqual(snapshot.customDictionaryEntries, [entry])
        #endif
    }

    func testExplicitlyDisabledOptionsAreNotTreatedAsNil() {
        self.setPronunciationGateForTest(true)
        let options = FluidAudioProviderEnhancementOptions(
            experimentalUnifiedFinalEnabled: false,
            pronunciationMatchingEnabled: false,
            customDictionaryEntries: []
        )
        let provider = FluidAudioProvider(enhancementOptions: options)
        #if arch(arm64) && DEBUG
        let snapshot = provider.effectiveEnhancementOptionsForTesting
        XCTAssertFalse(snapshot.experimentalUnifiedFinalEnabled)
        XCTAssertFalse(snapshot.pronunciationMatchingEnabled)
        XCTAssertTrue(snapshot.customDictionaryEntries.isEmpty)
        #endif
    }

    func testMeetingProviderKeepsFixedAllDisabledPolicy() throws {
        self.setPronunciationGateForTest(true)
        let provider = try FluidAudioProvider(meetingConfiguration: MeetingFinalProcessingConfiguration())
        #if arch(arm64) && DEBUG
        let snapshot = provider.effectiveEnhancementOptionsForTesting
        XCTAssertFalse(snapshot.experimentalUnifiedFinalEnabled)
        XCTAssertFalse(snapshot.pronunciationMatchingEnabled)
        XCTAssertTrue(snapshot.customDictionaryEntries.isEmpty)
        #endif
    }

    func testMasterPronunciationSwitchStillDisablesExplicitOptions() {
        self.setPronunciationGateForTest(false)
        let options = FluidAudioProviderEnhancementOptions(
            experimentalUnifiedFinalEnabled: true,
            pronunciationMatchingEnabled: true,
            customDictionaryEntries: [self.makeEntry()]
        )
        let provider = FluidAudioProvider(configureWordBoosting: false, enhancementOptions: options)
        #if arch(arm64) && DEBUG
        let snapshot = provider.effectiveEnhancementOptionsForTesting
        XCTAssertTrue(snapshot.experimentalUnifiedFinalEnabled)
        XCTAssertFalse(snapshot.pronunciationMatchingEnabled)
        XCTAssertEqual(snapshot.customDictionaryEntries, options.customDictionaryEntries)
        #endif
    }
}
