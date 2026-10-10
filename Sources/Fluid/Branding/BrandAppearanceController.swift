import AppKit
import Combine

/// Native shell surfaces refresh together with SwiftUI content after an atomic package commit.
@MainActor
enum BrandAppearanceController {
    static func apply(previous: BrandProfile) {
        let current = AppBrand.profile
        let replacements = [(previous.appName, current.appName), (previous.meetingName, current.meetingName), (previous.assistantName, current.assistantName)]
        func replace(_ source: String) -> String {
            // Match original ranges once; imported names are never recursively interpreted.
            let names = Dictionary(replacements, uniquingKeysWith: { first, _ in first })
            let expression = try! NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}_])(?:" + names.keys.sorted().map(NSRegularExpression.escapedPattern).joined(separator: "|") + ")(?![\\p{L}\\p{N}_])")
            var result = source
            for match in expression.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
                guard let sourceRange = Range(match.range, in: source), let resultRange = Range(match.range, in: result), let value = names[String(source[sourceRange])] else { continue }
                result.replaceSubrange(resultRange, with: value)
            }
            return result
        }
        func refresh(_ menu: NSMenu) {
            for item in menu.items {
                item.title = replace(item.title)
                if let submenu = item.submenu { refresh(submenu) }
            }
        }
        if let menu = NSApplication.shared.mainMenu { refresh(menu) }
        for window in NSApplication.shared.windows { window.title = replace(window.title) }
        NSApplication.shared.applicationIconImage = PichiBrandMark.appIcon
        SettingsStore.shared.objectWillChange.send()
        NotificationCenter.default.post(name: AppBrand.appearanceChanged, object: nil)
    }
}
