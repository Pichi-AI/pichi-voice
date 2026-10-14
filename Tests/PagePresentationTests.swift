import Foundation
import SwiftUI

@main
struct PagePresentationTests {
    @MainActor
    static func main() {
        let destinations: [SidebarItem] = [
            .welcome, .history, .stats, .voiceEngine, .aiEnhancements, .cleanupStyles,
            .customDictionary, .commandMode, .fileTranscription, .meetingTranscription,
            .feedback, .changelog, .rewriteMode,
        ]
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message)
            checks += 1
        }

        var settings = SettingsNavigationState()
        check(AppPagePresentation(destination: nil, settings: settings).title == "Dashboard", "Missing destination must have a useful title")
        check(Set(destinations.map(\.title)).count == destinations.count, "Each page needs a distinct title")
        for destination in destinations {
            let initial = settings
            let page = AppPagePresentation(destination: destination, settings: settings)
            check(page.title == destination.title && page.showsPageActions, "Destination chrome must be current")
            check(settings == initial, "Reading chrome must not mutate navigation")
            for section in SettingsSection.allCases {
                settings.present(section, returningTo: destination)
                let snapshot = settings
                // Simulate a stale underlying destination while Settings is visible.
                for hiddenDestination in destinations {
                    let hidden = AppPagePresentation(destination: hiddenDestination, settings: settings)
                    check(hidden.title == section.title, "Hidden content must not change the Settings title")
                    check(!hidden.showsPageActions, "Hidden page actions must not leak into Settings")
                    check(settings == snapshot, "Presentation must not change the return destination")
                }
                check(settings.dismiss() == destination, "Back must retain its original destination")
                let restored = AppPagePresentation(destination: destination, settings: settings)
                check(restored == page, "Rapid Settings/Back changes must not retain stale chrome")
            }
        }

        // Geometry checks use production layout code, including the capped width.
        for width in stride(from: 320, through: 2000, by: 1) {
            let layout = DashboardLayout(width: CGFloat(width))
            if layout.hasActionColumn {
                check(layout.mainWidth >= 640, "Action column must not squeeze main content")
            }
            for count in 1...3 {
                let columns = layout.setupColumns(count: count)
                check(count % columns == 0, "Setup rows must remain complete")
                if columns > 1 {
                    check((layout.contentWidth - CGFloat(count - 1) * 10) / CGFloat(count) >= 280, "Setup cards must remain readable")
                }
            }
        }
        var environment = EnvironmentValues()
        check(environment.fluidPageToolbarVisible, "Standalone page actions should default to visible")
        environment.fluidPageToolbarVisible = false
        check(!environment.fluidPageToolbarVisible, "Mounted hidden pages must suppress toolbar contribution")
        check(EnvironmentValues().fluidPageToolbarVisible, "Toolbar visibility must not leak into another view environment")
        // Pure passive-trace budget/encoding checks: no app, window, defaults
        // writes, observer, or production file logger is initialized.
        var trace = ToolbarAppearanceTrace.Stream(maxEvents: 2, maxBytes: 8192)
        let first: [String: Any] = ["colorScheme": "dark", "enabled": true]
        check(trace.encode(enabled: false, kind: "label", source: "synthetic", payload: first,
                           pid: 7, uptime: 1, timestamp: 2) == nil && trace.events == 0, "Trace is opt-in")
        check(trace.encode(enabled: true, kind: "label", source: "synthetic", payload: ["unsupported": Date(timeIntervalSince1970: 1)],
                           pid: 7, uptime: 1, timestamp: 2) == nil && trace.events == 0, "Invalid metadata cannot enter the log")
        let line = trace.encode(enabled: true, kind: "label", source: "synthetic", payload: first,
                                pid: 7, uptime: 1, timestamp: 2)!
        check(trace.bytes == line.utf8.count + 1, "Byte budget includes the emitted prefix and logger newline")
        let json = try! JSONSerialization.jsonObject(with: Data(line.dropFirst("[ToolbarAppearance] ".count).utf8)) as! [String: Any]
        check(json["pid"] as? Int == 7 && json["sequence"] as? Int == 1 && json["timestamp"] as? Int == 2, "Trace attribution must be explicit")
        check(trace.encode(enabled: true, kind: "label", source: "synthetic", payload: first,
                           pid: 7, uptime: 3, timestamp: 4) == nil && trace.events == 1, "Unchanged metadata is deduplicated")
        check(trace.encode(enabled: true, kind: "label", source: "synthetic", payload: ["colorScheme": "light"],
                           pid: 7, uptime: 3, timestamp: 4) != nil, "A changed actual scheme is retained")
        check(trace.encode(enabled: true, kind: "window", source: "synthetic", payload: first,
                           pid: 7, uptime: 3, timestamp: 4) == nil && trace.events == 2, "Event budget is bounded")
        var tinyTrace = ToolbarAppearanceTrace.Stream(maxEvents: 2, maxBytes: 8)
        check(tinyTrace.encode(enabled: true, kind: "label", source: "synthetic", payload: first,
                               pid: 7, uptime: 1, timestamp: 2) == nil && tinyTrace.bytes == 0, "Byte budget is bounded without partial records")

        print("Page presentation: \(checks) checks passed (navigation non-effects, hidden actions, rapid Settings/Back, adaptive layout)")
    }
}
