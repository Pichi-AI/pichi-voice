import Foundation

// Only preference/package storage is replaced; localization, format escaping,
// owned Settings expressions and overlay enum metadata are production source.
nonisolated final class UserDefaults: @unchecked Sendable {
    static let standard = UserDefaults()
    private var values: [String: Any] = [:]
    func string(forKey key: String) -> String? { self.values[key] as? String }
    func set(_ value: Any?, forKey key: String) { self.values[key] = value }
}

nonisolated final class BrandPackageStore: @unchecked Sendable {
    static let shared = BrandPackageStore()
    var hasOverride: Bool { false }
    func current() -> BrandPackage { AppBrand.packagedPackage }
}

@main struct SettingsOwnedCopyTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        self.checks += 1
        precondition(condition(), message)
    }

    static func main() throws {
        self.check(Bundle.main.localizations.contains("ru"), "Fixture must use the actual compiled catalog")
        for language in ["en", "ru"] {
            UserDefaults.standard.set(language, forKey: PichiInterfaceLanguage.defaultsKey)
            for name in ["Pichi Voice", "Сбер Голос", "100%@ Ё Voice", "Output device"] {
                let fresh = SettingsCopyFixture(asr: .init(micStatus: .notDetermined), appDisplayName: name)
                let microphone = fresh.microphoneSteps()
                let expected = language == "ru"
                    ? ["Нажмите **Разрешить доступ** выше", "Выберите **Разрешить** в системном диалоге"]
                    : ["Click **Grant Access** above", "Choose **Allow** in the system dialog"]
                self.check(microphone == expected, "Microphone permission instructions must use the chosen interface language")
                let denied = SettingsCopyFixture(asr: .init(micStatus: .denied), appDisplayName: name)
                let deniedSteps = denied.microphoneSteps()
                let access = fresh.accessibilitySteps()
                self.check(deniedSteps.count == 3 && access.count == 4, "Localization must not change the guided action count")
                let expectedDenied = language == "ru"
                    ? ["Нажмите **Открыть настройки** выше", "Найдите **\(name)** в списке доступа к микрофону", "Включите доступ к микрофону для **\(name)**"]
                    : ["Click **Open Settings** above", "Find **\(name)** in the microphone list", "Toggle **\(name) ON** to allow access"]
                self.check(deniedSteps == expectedDenied, "Every denied microphone step must localize while preserving literal brand arguments")
                let expectedAccess = language == "ru"
                    ? ["Нажмите **Открыть настройки Универсального доступа** выше", "В настройках Универсального доступа нажмите кнопку **+**", "Выберите **\(name)**. При необходимости нажмите ниже **Показать в Finder**", "Нажмите **Открыть** и включите **\(name)** в списке"]
                    : ["Click **Open Accessibility Settings** above", "In the Accessibility window, click the **+ button**", "Select **\(name)**; use **Reveal in Finder** below if needed", "Click **Open**, then toggle **\(name) ON** in the list"]
                self.check(access == expectedAccess, "Every Accessibility step must localize while preserving imported names and punctuation")
                for step in microphone + deniedSteps + access {
                    // The production renderer consumes already localized Markdown as data.
                    let rendered = SettingsCopyFixture.renderInstruction(step)
                    self.check(rendered.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true },
                               "Owned instruction emphasis must survive localization")
                }
                let renderedFind = SettingsCopyFixture.renderInstruction(deniedSteps[1])
                self.check(String(renderedFind.characters).contains(name), "Rendered instructions must not translate imported brand data")
            }
            for device in ["MacBook Pro Speakers", "Output device", "Medium", "100%@ Ё Device", "Studio (System Default)"] {
                self.check(SettingsCopyFixture.outputDeviceDisplayName(device, isSystemDefault: false) == device,
                           "CoreAudio names without a default tag must remain byte-identical")
                let suffix = language == "ru" ? " (по умолчанию)" : " (System Default)"
                self.check(SettingsCopyFixture.outputDeviceDisplayName(device, isSystemDefault: true) == device + suffix,
                           "Only the app-owned default suffix may localize; device names stay verbatim")
            }
            let keys = ["Output device", "Overlay size", "Overlay position"]
            let expectedKeys = language == "ru" ? ["Устройство вывода", "Размер индикатора", "Положение индикатора"] : keys
            self.check(keys.map(PichiLocalization.text) == expectedKeys, "Dropdown accessibility titles must have owned localized keys")
            self.check(PichiLocalization.text(SettingsStore.OverlaySize.medium.displayName) == (language == "ru" ? "Средний" : "Medium"),
                       "Current overlay size must use the existing metadata display contract")
            self.check(PichiLocalization.text(SettingsStore.OverlayPosition.bottom.displayName) == (language == "ru" ? "Внизу экрана" : "Bottom of Screen"),
                       "Current overlay position must use the existing metadata display contract")
            self.check(SettingsStore.OverlaySize.medium.rawValue == "medium" && SettingsStore.OverlayPosition.bottom.rawValue == "bottom",
                       "Localization must not alter stored overlay identifiers")
        }
        print("Settings owned copy: \(self.checks) checks passed; real RU/EN instructions/catalog, Markdown emphasis, literal brands/devices and stable overlay IDs; no UI or permission calls")
    }
}
