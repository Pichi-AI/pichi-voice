import Foundation

@main struct DesktopCloudPublicationFormatTests {
    static func main() throws {
        let bundle = Bundle(path: CommandLine.arguments[1])!
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        var assertions = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message); assertions += 1
        }
        for language in [PichiInterfaceLanguage.english, .russian] {
            let pattern = language == .russian ? "Повторная попытка: %@" : "Retry at %@"
            let readiness = language == .russian ? "Синхронизация с облаком готова." : "Cloud sync is ready."
            check(PichiLocalization.text("cloud.status.retryScheduled", language: language, bundle: bundle) == pattern,
                  "The fixture must carry the canonical N3 placeholder")
            for zone in [TimeZone(secondsFromGMT: 0)!, TimeZone(identifier: "America/Los_Angeles")!] {
                var style = Date.FormatStyle(date: .abbreviated, time: .shortened).locale(language.locale)
                style.timeZone = zone
                let dateText = date.formatted(style)
                let actual = DesktopCloudPublicationCopy.retryScheduled(date, language: language, bundle: bundle, timeZone: zone)
                let expected = String(format: pattern, locale: language.locale, arguments: [dateText])
                check(actual == expected, "Use actual localized catalog formatting with one localized date argument")
                check(!actual.contains("%@") && !actual.contains("cloud.status."), "No literal placeholder or key may escape")
                check(actual.components(separatedBy: dateText).count == 2, "Display the retry date exactly once")
            }
            check(DesktopCloudPublicationCopy.availabilityLabel(.ready, language: language, bundle: bundle) == readiness,
                  "Readiness alone must not claim consent ON")
            let disabled = PichiCloudPublicationSnapshot(availability: .ready, cloudSyncEnabled: false, items: [:])
            check(DesktopCloudPublicationCopy.availability(disabled, accountState: .signedIn,
                  language: language, bundle: bundle) == "Cloud sync is off", "Verified OFF overrides readiness")
        }
        print("Desktop cloud catalog: \(assertions) actual-localization EN/RU format assertions passed, canonical N3 values, fixed date and two time zones; no native UI or preferences.")
    }
}
