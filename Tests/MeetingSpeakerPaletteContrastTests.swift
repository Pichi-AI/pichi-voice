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

        // Eight identities exercise all six inherited slots and palette reuse.
        let expectedIndices = [5, 4, 3, 2, 1, 0, 5, 4]
        let speakers = expectedIndices.indices.map { index in
            MeetingSessionSpeaker(id: UUID(uuidString: "01234567-89ab-cdef-0123-456789abc00\(index)")!,
                displayName: "Synthetic \(index) Ёё", isLocalUser: false)
        }
        for (speaker, expected) in zip(speakers, expectedIndices) {
            precondition(MeetingSpeakerPalette.index(forSpeakerID: speaker.id) == expected,
                "The explicit UUID-byte mapping must remain identical across launches and platforms")
        }
        for (text, expected) in [
            ("11234567-89ab-cdef-0123-456789abc000", 3),
            ("01234567-99ab-cdef-0123-456789abc000", 3),
            ("01234567-89ab-cdef-1123-456789abc000", 1),
        ] {
            precondition(MeetingSpeakerPalette.index(forSpeakerID: UUID(uuidString: text)!) == expected,
                "Bytes throughout the UUID must participate in the fixed mapping")
        }
        var contrasts = 0, immutableChecks = 0, legacyFailures = 0, liveChecks = 0
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
                        var liveFills: [Color] = []
                        guardAppearance.performAsCurrentDrawingAppearance {
                            tints = MeetingSpeakerPalette.tints(for: speakers, isDark: physical == .dark)
                            checked = ProductionSpeakerPaletteProducer(session: .init(activeSpeakers: speakers),
                                theme: theme, colorScheme: ambient).currentTints()
                            precondition(MeetingSpeakerPalette.labelColor(for: nil, theme: theme, colorScheme: ambient)
                                == theme.palette.secondaryText, "Unresolved speech must keep neutral semantic ink")
                            for microphone in [false, true] {
                                for partial in [false, true] {
                                    liveFills.append(ProductionLiveSpeakerPaletteProducer(
                                        row: .init(speaker: microphone ? .you : .remote, isPartial: partial),
                                        theme: theme, colorScheme: ambient).currentFill())
                                }
                            }
                        }
                        for drawScheme: ColorScheme in [.light, .dark] {
                            NSAppearance(named: drawScheme == .dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
                                for (index, fill) in liveFills.enumerated() {
                                    let microphone = index >= 2
                                    let partial = index % 2 == 1
                                    let base = microphone ? theme.palette.accent
                                        : MeetingSpeakerPalette.tint(forSpeakerIndex: 0, isDark: physical == .dark)
                                    precondition(self.equal(UIContrastTests.components(fill), UIContrastTests.components(base)),
                                        "Actual live fill must retain microphone accent or physical remote tint across guard/draw appearances")
                                    precondition(abs(NSColor(fill).usingColorSpace(.sRGB)!.alphaComponent - (partial ? 0.05 : 0.10)) < 0.00001,
                                        "Live partial/final fill opacity must remain unchanged")
                                    liveChecks += 1
                                }
                                for speaker in speakers {
                                    let index = MeetingSpeakerPalette.index(forSpeakerID: speaker.id)
                                    let rgb = MeetingSpeakerPalette.rgb(forSpeakerIndex: index, isDark: physical == .dark)
                                    let expected = [Double(rgb.red), Double(rgb.green), Double(rgb.blue)].map { $0 / 255 }
                                    precondition(self.equal(UIContrastTests.components(tints[speaker.id]!), expected),
                                        "\(brand): actual palette selector must retain physical RGB across opposite draw appearances")
                                    immutableChecks += 1
                                    let expectedInk = theme.palette.readableText(
                                        MeetingSpeakerPalette.tint(forSpeakerID: speaker.id, isDark: physical == .dark),
                                        minimumContrast: 4.5)
                                    let ink = UIContrastTests.components(checked[speaker.id]!)
                                    precondition(self.equal(ink, UIContrastTests.components(expectedInk)),
                                        "Production labels must preserve the UUID tint whenever it meets small-text contrast")
                                    for surface in surfaces {
                                        precondition(UIContrastTests.contrast(ink, UIContrastTests.components(surface)) >= 4.5,
                                            "\(brand): small participant labels must meet 4.5 on all six surfaces")
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

        let indices = MeetingSpeakerPalette.tintIndices(for: speakers)
        var renamed = speakers
        // A name identical to the old catch-all spelling is still just metadata.
        for index in renamed.indices {
            renamed[index].displayName = MeetingSpeakerPalette.unknownMicrophoneSpeakerName
            renamed[index].isLocalUser = index == 2
        }
        renamed.reverse()
        precondition(MeetingSpeakerPalette.tintIndices(for: renamed) == indices,
            "Renaming, owner confirmation and reorder cannot change any participant's slot")
        for dark in [false, true] {
            let original = MeetingSpeakerPalette.tints(for: speakers, isDark: dark)
            precondition(MeetingSpeakerPalette.tints(for: renamed, isDark: dark) == original)
            let filtered = Array(renamed.dropFirst(3))
            let filteredColors = MeetingSpeakerPalette.tints(for: filtered, isDark: dark)
            for speaker in filtered {
                precondition(filteredColors[speaker.id] == original[speaker.id],
                    "Filtering or merging peers must not recolor remaining identities")
            }
            for speaker in speakers {
                let reopenedID = UUID(uuidString: speaker.id.uuidString)!
                precondition(MeetingSpeakerPalette.tint(forSpeakerID: reopenedID, isDark: dark) == original[speaker.id],
                    "Restoring the persisted UUID must recover the same tint without process-local state")
            }
        }
        print("Speaker palette: \(immutableChecks) immutable RGB checks; \(contrasts) six-surface small-label contrast checks; \(liveChecks) source-bound live microphone/remote partial/final fill checks; \(legacyFailures) legacy dynamic negative controls; eight UUID/name/owner/reorder/filter/restored-ID contracts")
        print("SKIP: actual native meeting header/row pixels, hot/cold UI replay, pointer and keyboard interactions")
    }
}
