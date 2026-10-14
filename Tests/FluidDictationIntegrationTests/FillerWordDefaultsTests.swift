import Foundation
@testable import FluidVoice_Debug
import XCTest

@MainActor
final class FillerWordDefaultsTests: XCTestCase {
    private let legacyDefaults = [
        "um", "uh", "er", "ah", "eh", "umm", "uhh", "err", "ahh", "ehh",
        "hmm", "hm", "mm", "mmm", "erm", "urm", "ugh",
    ]

    private var previousMultilingualDefaults: [String] {
        self.legacyDefaults + [
            "э", "ээ", "эээ", "э-э", "э-э-э", "эм", "эмм", "эммм",
            "ммм", "м-м", "м-м-м", "хм", "хмм",
        ]
    }

    func testFreshInstallUsesMultilingualDefaultsWithoutPersistingAList() throws {
        try self.withIsolatedDefaults { defaults in
            SettingsStore.migrateFillerWordDefaultsIfNeeded(defaults: defaults)
            XCTAssertNil(defaults.object(forKey: "FillerWords"))
            XCTAssertTrue(defaults.bool(forKey: "FillerWordDefaultsMigrationV1"))
            XCTAssertTrue(defaults.bool(forKey: "FillerWordDefaultsMigrationV2"))
        }
        self.withRestoredFillerSettings {
            UserDefaults.standard.removeObject(forKey: "FillerWords")
            XCTAssertEqual(SettingsStore.shared.fillerWords, SettingsStore.defaultFillerWords)
            XCTAssertTrue(Set(self.legacyDefaults).isSubset(of: Set(SettingsStore.shared.fillerWords)))
            XCTAssertTrue(SettingsStore.shared.fillerWords.contains("эм"))
            XCTAssertTrue(SettingsStore.shared.fillerWords.contains("э-мм"))
        }
    }

    func testMigrationUpgradesOnlyUnchangedLegacyDefaults() throws {
        try self.withIsolatedDefaults { defaults in
            defaults.set(self.legacyDefaults, forKey: "FillerWords")
            defaults.set(false, forKey: "RemoveFillerWordsEnabled")
            SettingsStore.migrateFillerWordDefaultsIfNeeded(defaults: defaults)
            XCTAssertEqual(defaults.stringArray(forKey: "FillerWords"), SettingsStore.defaultFillerWords)
            XCTAssertFalse(defaults.bool(forKey: "RemoveFillerWordsEnabled"))
        }
    }

    func testMigrationPreservesCustomizedAndEmptyLists() throws {
        let customizedLists = [
            [], ["um"], Array(self.legacyDefaults.dropFirst()),
            self.legacyDefaults + ["синтетический"], Array(self.legacyDefaults.reversed()),
            SettingsStore.defaultFillerWords,
        ]
        for list in customizedLists {
            try self.withIsolatedDefaults { defaults in
                defaults.set(list, forKey: "FillerWords")
                SettingsStore.migrateFillerWordDefaultsIfNeeded(defaults: defaults)
                XCTAssertEqual(defaults.stringArray(forKey: "FillerWords"), list)
                XCTAssertTrue(defaults.bool(forKey: "FillerWordDefaultsMigrationV1"))
            }
        }
    }

    func testMigrationDoesNotReinsertSoundsAfterUserRemovesRussianDefaults() throws {
        try self.withIsolatedDefaults { defaults in
            defaults.set(self.legacyDefaults, forKey: "FillerWords")
            SettingsStore.migrateFillerWordDefaultsIfNeeded(defaults: defaults)
            defaults.set(self.legacyDefaults, forKey: "FillerWords")
            SettingsStore.migrateFillerWordDefaultsIfNeeded(defaults: defaults)
            XCTAssertEqual(defaults.stringArray(forKey: "FillerWords"), self.legacyDefaults)
        }
    }

    func testMigrationUpgradesPreviousMultilingualDefaultsEvenAfterV1() throws {
        for firstMigrationCompleted in [false, true] {
            try self.withIsolatedDefaults { defaults in
                defaults.set(self.previousMultilingualDefaults, forKey: "FillerWords")
                defaults.set(firstMigrationCompleted, forKey: "FillerWordDefaultsMigrationV1")
                defaults.set(false, forKey: "RemoveFillerWordsEnabled")
                SettingsStore.migrateFillerWordDefaultsIfNeeded(defaults: defaults)
                XCTAssertEqual(defaults.stringArray(forKey: "FillerWords"), SettingsStore.defaultFillerWords)
                XCTAssertTrue(defaults.bool(forKey: "FillerWordDefaultsMigrationV1"))
                XCTAssertTrue(defaults.bool(forKey: "FillerWordDefaultsMigrationV2"))
                XCTAssertFalse(defaults.bool(forKey: "RemoveFillerWordsEnabled"))
            }
        }
    }

    func testSecondMigrationPreservesPreviouslyCustomizedLists() throws {
        let customizedLists = [
            [], self.legacyDefaults, Array(self.previousMultilingualDefaults.dropFirst()),
            self.previousMultilingualDefaults + ["синтетический"],
            self.previousMultilingualDefaults + ["эм"],
            Array(self.previousMultilingualDefaults.reversed()), SettingsStore.defaultFillerWords,
        ]
        for list in customizedLists {
            try self.withIsolatedDefaults { defaults in
                defaults.set(list, forKey: "FillerWords")
                defaults.set(true, forKey: "FillerWordDefaultsMigrationV1")
                SettingsStore.migrateFillerWordDefaultsIfNeeded(defaults: defaults)
                XCTAssertEqual(defaults.stringArray(forKey: "FillerWords"), list)
                XCTAssertTrue(defaults.bool(forKey: "FillerWordDefaultsMigrationV2"))
            }
        }
    }

    func testSecondMigrationDoesNotReinsertRemovedHyphenatedHesitation() throws {
        try self.withIsolatedDefaults { defaults in
            defaults.set(self.previousMultilingualDefaults, forKey: "FillerWords")
            defaults.set(true, forKey: "FillerWordDefaultsMigrationV1")
            SettingsStore.migrateFillerWordDefaultsIfNeeded(defaults: defaults)
            XCTAssertEqual(defaults.stringArray(forKey: "FillerWords"), SettingsStore.defaultFillerWords)
            defaults.set(self.previousMultilingualDefaults, forKey: "FillerWords")
            SettingsStore.migrateFillerWordDefaultsIfNeeded(defaults: defaults)
            XCTAssertEqual(defaults.stringArray(forKey: "FillerWords"), self.previousMultilingualDefaults)
        }
    }

    func testDefaultFilterRemovesRussianHesitationsWithCaseAndPunctuation() {
        self.withRestoredFillerSettings {
            let settings = SettingsStore.shared
            settings.fillerWords = SettingsStore.defaultFillerWords
            settings.removeFillerWordsEnabled = true
            XCTAssertEqual(
                ASRService.removeFillerWords("Э, ээ эээ э-э э-э-э Эм, эмм эммм ммм м-м м-м-м Хм... хмм Э-ММ, готово."),
                "готово."
            )
            XCTAssertEqual(ASRService.removeFillerWords("Um, эм сегодня uh обсудим хм план."), "сегодня обсудим план.")
            XCTAssertEqual(ASRService.removeFillerWords("Эм, hmm ммм."), "")
        }
    }

    func testDefaultFilterPreservesMeaningfulRussianWordsAndSubstrings() {
        self.withRestoredFillerSettings {
            SettingsStore.shared.fillerWords = SettingsStore.defaultFillerWords
            SettingsStore.shared.removeFillerWordsEnabled = true
            let text = "Ну это типа значит короче как бы угу ага да а м. Ёжик ёлка эмаль экран гамма хмель."
            XCTAssertEqual(ASRService.removeFillerWords(text), text)
            XCTAssertEqual(ASRService.removeFillerWords("Эм, толщина 2 мм. и длина 10 мм"), "толщина 2 мм. и длина 10 мм")
            XCTAssertEqual(ASRService.removeFillerWords("Э-мм, толщина 2 мм."), "толщина 2 мм.")
        }
    }

    func testDisabledFilterPreservesInputExactly() {
        self.withRestoredFillerSettings {
            SettingsStore.shared.fillerWords = SettingsStore.defaultFillerWords
            SettingsStore.shared.removeFillerWordsEnabled = false
            let text = "Эм,  um\nммм э-мм готово."
            XCTAssertEqual(ASRService.removeFillerWords(text), text)
        }
    }

    func testCustomListAndExplicitEmptyListRemainAuthoritative() {
        self.withRestoredFillerSettings {
            let settings = SettingsStore.shared
            settings.removeFillerWordsEnabled = true
            settings.fillerWords = ["синтетический"]
            XCTAssertEqual(ASRService.removeFillerWords("эм синтетический um готово"), "эм um готово")
            settings.fillerWords = []
            XCTAssertEqual(ASRService.removeFillerWords("эм um готово"), "эм um готово")
        }
    }

    private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "FillerWordDefaultsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    private func withRestoredFillerSettings(_ body: () -> Void) {
        // Initialize existing settings migrations before taking the snapshot.
        _ = SettingsStore.shared
        let defaults = UserDefaults.standard
        let keys = ["FillerWords", "RemoveFillerWordsEnabled"]
        let originals = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, original) in zip(keys, originals) {
                if let original {
                    defaults.set(original, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        body()
    }
}
