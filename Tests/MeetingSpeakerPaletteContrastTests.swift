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

        // The first two UUIDs collided under the rejected UUID-hash selector.
        // Full admission order keeps the first six distinct and repeats at eight.
        let suffixes = [0, 6, 1, 2, 3, 4, 5, 7]
        let speakers = suffixes.map { suffix in
            MeetingSessionSpeaker(id: UUID(uuidString: "01234567-89ab-cdef-0123-456789abc00\(suffix)")!,
                displayName: "Synthetic \(suffix) Ёё", isLocalUser: false)
        }
        let indices = MeetingSpeakerPalette.tintIndices(for: speakers)
        for (index, speaker) in speakers.enumerated() {
            precondition(indices[speaker.id] == index,
                "Every persisted identity, including local and merged entries, must reserve its admission slot")
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
                            checked = ProductionSpeakerPaletteProducer(session: .init(speakers: speakers),
                                theme: theme, colorScheme: ambient).currentTints()
                            precondition(MeetingSpeakerPalette.labelColor(forSpeakerIndex: nil, theme: theme, colorScheme: ambient)
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
                                    let index = indices[speaker.id]!
                                    let rgb = MeetingSpeakerPalette.rgb(forSpeakerIndex: index, isDark: physical == .dark)
                                    let expected = [Double(rgb.red), Double(rgb.green), Double(rgb.blue)].map { $0 / 255 }
                                    precondition(self.equal(UIContrastTests.components(tints[speaker.id]!), expected),
                                        "\(brand): actual palette selector must retain physical RGB across opposite draw appearances")
                                    immutableChecks += 1
                                    let expectedInk = theme.palette.readableText(
                                        MeetingSpeakerPalette.tint(forSpeakerIndex: index, isDark: physical == .dark),
                                        minimumContrast: 4.5)
                                    let ink = UIContrastTests.components(checked[speaker.id]!)
                                    precondition(self.equal(ink, UIContrastTests.components(expectedInk)),
                                        "Production labels must preserve the admission tint whenever it meets small-text contrast")
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

        var renamed = speakers
        // These are presentation metadata, not palette-allocation inputs.
        for index in renamed.indices {
            renamed[index].displayName = MeetingSpeakerPalette.unknownMicrophoneSpeakerName
            renamed[index].isLocalUser = index == 2
            renamed[index].generatedParticipantNumber = 100 - index
        }
        renamed[0].mergedIntoSpeakerID = renamed[1].id
        precondition(MeetingSpeakerPalette.tintIndices(for: renamed) == indices,
            "Renaming, owner confirmation, generated numbers and merging cannot release admission slots")
        for dark in [false, true] {
            let original = MeetingSpeakerPalette.tints(for: speakers, isDark: dark)
            let fullColors = MeetingSpeakerPalette.tints(for: renamed, isDark: dark)
            precondition(fullColors == original)
            let firstSix = speakers.prefix(6).map { original[$0.id]! }
            for index in firstSix.indices {
                for other in firstSix.indices where index != other {
                    precondition(firstSix[index] != firstSix[other],
                        "The first six admitted identities must have distinct inherited hues")
                }
            }
            precondition(original[speakers[6].id] == original[speakers[0].id]
                && original[speakers[7].id] == original[speakers[1].id],
                "Meetings beyond six identities repeat the bounded inherited palette")
            let filteredView = renamed.filter { $0.mergedIntoSpeakerID == nil }.reversed()
            for speaker in filteredView {
                precondition(fullColors[speaker.id] == original[speaker.id],
                    "A filtered/reordered view must look up the full canonical map by UUID")
            }
            let restored = speakers.map {
                MeetingSessionSpeaker(id: UUID(uuidString: $0.id.uuidString)!,
                    displayName: $0.displayName, isLocalUser: $0.isLocalUser)
            }
            precondition(MeetingSpeakerPalette.tints(for: restored, isDark: dark) == original,
                "Restoring the persisted admission list must recover all prior tints")
            let newcomer = MeetingSessionSpeaker(id: UUID(uuidString: "01234567-89ab-cdef-0123-456789abc008")!,
                displayName: "Synthetic new", isLocalUser: false)
            let appended = MeetingSpeakerPalette.tints(for: renamed + [newcomer], isDark: dark)
            for speaker in speakers {
                precondition(appended[speaker.id] == original[speaker.id],
                    "Admitting a new identity must not recolor prior participants")
            }
        }
        print("Speaker palette: \(immutableChecks) immutable RGB checks; \(contrasts) six-surface small-label contrast checks; \(liveChecks) source-bound live microphone/remote partial/final fill checks; \(legacyFailures) legacy dynamic negative controls; eight admission/name/owner/merge/filter/restored-list contracts")
        print("SKIP: actual native meeting header/row pixels, hot/cold UI replay, pointer and keyboard interactions")
    }
}
