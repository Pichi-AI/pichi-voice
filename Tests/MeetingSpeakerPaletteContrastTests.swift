import AppKit
import SwiftUI

/// Colors only. No NSApplication, windows, hosting views, settings or model services.
enum MeetingSpeakerPaletteContrastTests {
    private static func equal(_ lhs: [Double], _ rhs: [Double]) -> Bool {
        zip(lhs, rhs).allSatisfy { abs($0 - $1) < 0.00001 }
    }

    @MainActor static func run() throws {
        var packages = try [("pichi", "Sources/Fluid/Branding/brand-package.json"),
                            ("sber", "Configuration/BrandExamples/sber-demo.json"),
                            ("alfa", "Configuration/BrandExamples/alfa-demo.json")].map {
            ($0.0, try BrandPackage.decode(Data(contentsOf: URL(fileURLWithPath: $0.1))))
        }
        var inverted = packages[0].1
        let profile = inverted.profile
        inverted.profile = BrandProfile(appName: profile.appName, meetingName: profile.meetingName,
            assistantName: profile.assistantName, tagline: profile.tagline,
            accentLight: profile.accentDark, accentDark: profile.accentLight,
            website: profile.website, support: profile.support)
        inverted.theme = BrandTheme(light: inverted.theme!.dark, dark: inverted.theme!.light)
        packages.append(("inverted", try BrandPackage.decode(inverted.encoded())))

        let speakers = (0..<6).map { index in
            MeetingSessionSpeaker(id: UUID(), displayName: "Synthetic \(index) Ёё", isLocalUser: false)
        }
        var contrasts = 0, immutableChecks = 0, legacyFailures = 0
        for (brand, package) in packages {
            for logical: ColorScheme in [.light, .dark] {
                let theme = AppTheme.adaptive(
                    accent: Color(hex: logical == .dark ? package.profile.accentDark : package.profile.accentLight)!,
                    colorScheme: logical, package: package)
                let surfaces = [theme.palette.windowBackground, theme.palette.contentBackground,
                    theme.palette.sidebarBackground, theme.palette.cardBackground,
                    theme.palette.elevatedCardBackground, theme.palette.toolbarBackground]
                for ambient: ColorScheme in [.light, .dark] {
                    let physical = theme.palette.nativeColorScheme(fallback: ambient)
                    if brand == "inverted" { precondition(physical != logical) }
                    for guardScheme: ColorScheme in [.light, .dark] {
                        let guardAppearance = NSAppearance(named: guardScheme == .dark ? .darkAqua : .aqua)!
                        var tints: [SessionSpeakerID: Color] = [:]
                        var checked: [SessionSpeakerID: Color] = [:]
                        guardAppearance.performAsCurrentDrawingAppearance {
                            tints = ProductionSpeakerPaletteProducer(session: .init(activeSpeakers: speakers),
                                theme: theme, colorScheme: ambient).currentTints()
                            for speaker in speakers { checked[speaker.id] = theme.palette.readableText(tints[speaker.id]!) }
                        }
                        for drawScheme: ColorScheme in [.light, .dark] {
                            NSAppearance(named: drawScheme == .dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
                                for (index, speaker) in speakers.enumerated() {
                                    let rgb = MeetingSpeakerPalette.rgb(forSpeakerIndex: index, isDark: physical == .dark)
                                    let expected = [Double(rgb.red), Double(rgb.green), Double(rgb.blue)].map { $0 / 255 }
                                    precondition(self.equal(UIContrastTests.components(tints[speaker.id]!), expected),
                                        "\(brand): actual palette producer must retain physical RGB across opposite draw appearances")
                                    immutableChecks += 1
                                    let ink = UIContrastTests.components(checked[speaker.id]!)
                                    for surface in surfaces {
                                        precondition(UIContrastTests.contrast(ink, UIContrastTests.components(surface)) >= 3,
                                            "\(brand): stable proposed ink or existing fallback must meet all six surface contrasts")
                                        contrasts += 1
                                    }
                                }
                            }
                        }
                    }
                }
                // Negative control reproduces the former dynamic guard/draw mismatch
                // with the genuine production RGB selector, without a second palette.
                if brand != "inverted" && logical == .light {
                    let legacy = Color(nsColor: NSColor(name: nil) { appearance in
                        let rgb = MeetingSpeakerPalette.rgb(forSpeakerIndex: 0,
                            isDark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
                        return NSColor(srgbRed: CGFloat(rgb.red) / 255, green: CGFloat(rgb.green) / 255,
                            blue: CGFloat(rgb.blue) / 255, alpha: 1)
                    })
                    var accepted = Color.clear
                    NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
                        accepted = theme.palette.readableText(legacy)
                        precondition(UIContrastTests.contrast(UIContrastTests.components(accepted),
                            UIContrastTests.components(theme.palette.contentBackground)) >= 3)
                    }
                    NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
                        precondition(UIContrastTests.contrast(UIContrastTests.components(accepted),
                            UIContrastTests.components(theme.palette.contentBackground)) < 3,
                            "Negative control must demonstrate the old dynamic check/draw defect")
                        legacyFailures += 1
                    }
                }
            }
        }

        let first = speakers[0], last = speakers[2]
        var unknown = MeetingSessionSpeaker(id: UUID(), displayName: MeetingSpeakerPalette.unknownMicrophoneSpeakerName, isLocalUser: false)
        let local = MeetingSessionSpeaker(id: UUID(), displayName: "Synthetic local", isLocalUser: true)
        let before = MeetingSpeakerPalette.tintIndices(for: [local, first, unknown, last])
        precondition(before[first.id] == 0 && before[last.id] == 2 && before[unknown.id] == nil && before[local.id] == nil)
        let beforeColors = [false, true].map {
            MeetingSpeakerPalette.tints(for: [local, first, unknown, last], isDark: $0)
        }
        precondition(beforeColors.allSatisfy { $0[local.id] == nil && $0[unknown.id] == nil })
        unknown.displayName = "Synthetic renamed"
        let after = MeetingSpeakerPalette.tintIndices(for: [local, first, unknown, last])
        precondition(after[first.id] == 0 && after[last.id] == 2 && after[unknown.id] == 1 && after[local.id] == nil)
        for (index, dark) in [false, true].enumerated() {
            let colors = MeetingSpeakerPalette.tints(for: [local, first, unknown, last], isDark: dark)
            precondition(colors[first.id] == beforeColors[index][first.id] && colors[last.id] == beforeColors[index][last.id],
                "Renaming the unknown bucket cannot recolor other stable speaker IDs")
            precondition(colors[unknown.id] != nil && colors[local.id] == nil)
        }
        print("Speaker palette: \(immutableChecks) immutable RGB checks; \(contrasts) six-surface contrast checks; \(legacyFailures) legacy dynamic negative controls; local/unknown/renamed index contracts preserved")
        print("SKIP: actual native meeting header/row pixels, hot/cold UI replay, pointer and keyboard interactions")
    }
}
