import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main
struct BrandProfileTests {
    static func require(_ condition: @autoclosure () throws -> Bool) rethrows {
        let value = try condition()
        precondition(value)
    }

    static func reject(_ operation: () throws -> Void) {
        do { try operation(); fatalError("Accepted invalid brand data") } catch {}
    }

    static func main() throws {
        let packageData = try Data(contentsOf: URL(fileURLWithPath: "Sources/Fluid/Branding/brand-package.json"))
        let packaged = try BrandPackage.decode(packageData)
        precondition(packaged.profile.appName == "Pichi Voice")
        precondition(packaged.logos != nil && packaged.theme != nil)
        precondition(packaged.style?.defaultOnboardingLanguageID == "ru")
        let legacyStyle = try JSONDecoder().decode(BrandStyle.self, from: Data("{\"defaultAppearance\":\"system\",\"cornerRadiusScale\":1,\"spacingScale\":1}".utf8))
        precondition(legacyStyle.defaultOnboardingLanguageID == nil, "Old appearance files must remain decodable")
        precondition(legacyStyle.bodyFontDesign == nil && legacyStyle.titleFontDesign == nil)
        for design in BrandStyle.FontDesign.allCases {
            let style = BrandStyle(bodyFontDesign: design, titleFontDesign: design)
            try self.require(try JSONDecoder().decode(BrandStyle.self, from: JSONEncoder().encode(style)) == style)
        }
        self.reject { _ = try JSONDecoder().decode(BrandStyle.self, from: Data("{\"defaultAppearance\":\"system\",\"cornerRadiusScale\":1,\"spacingScale\":1,\"bodyFontDesign\":\"arbitrary-font-name\"}".utf8)) }
        try BrandStyle(defaultOnboardingLanguageID: "fr-CA").validate()
        self.reject { try BrandStyle(defaultOnboardingLanguageID: "invalid language!").validate() }
        for example in ["sber-demo", "alfa-demo"] {
            let data = try Data(contentsOf: URL(fileURLWithPath: "Configuration/BrandExamples/\(example).json"))
            let demo = try BrandPackage.decode(data)
            precondition(demo.logos != nil && demo.theme != nil)
            precondition(!demo.profile.appName.contains("Pichi"))
        }
        try self.verifyPaletteForegroundContrast(packaged)
        try self.require(try BrandPackage.decode(packaged.encoded()) == packaged)
        let valid = try JSONEncoder().encode(packaged.profile)
        try self.require(try BrandProfile.decode(valid) == packaged.profile)
        let custom = BrandProfile(appName: "Team Voice", meetingName: "Team Meetings", assistantName: "Team AI", tagline: "Private speech", accentLight: "#123456", accentDark: "#ABCDEF", website: "https://example.com", support: "https://example.com/support")
        try self.require(try BrandProfile.decode(JSONEncoder().encode(custom)) == custom)
        for (key, value) in [("appName", ""), ("meetingName", "Line\nBreak"), ("assistantName", String(repeating: "x", count: 121)), ("accentLight", "#ABC"), ("accentDark", "GGGGGG"), ("website", "http://example.com"), ("support", "https://user:password@example.com")] {
            var object = try JSONSerialization.jsonObject(with: valid) as! [String: Any]
            object[key] = value
            self.reject { _ = try BrandProfile.decode(JSONSerialization.data(withJSONObject: object)) }
        }
        self.reject { _ = try BrandProfile.decode(Data(repeating: 32, count: 32_769)) }
        self.reject { _ = try BrandPackage.decode(Data(repeating: 32, count: BrandPackage.maximumBytes + 1)) }
        var object = try JSONSerialization.jsonObject(with: packageData) as! [String: Any]
        object["formatVersion"] = 99
        self.reject { _ = try BrandPackage.decode(JSONSerialization.data(withJSONObject: object)) }
        object["formatVersion"] = 1
        for forbidden in ["bundleIdentifier", "updatesEnabled", "analytics", "remoteLogoURL", "feedbackEndpoint"] {
            var injected = object
            injected[forbidden] = "https://attacker.invalid"
            self.reject { _ = try BrandPackage.decode(JSONSerialization.data(withJSONObject: injected)) }
        }
        var invalidTheme = packaged
        var colors = packaged.theme!.light.colors
        colors["primaryText"] = colors["cardBackground"]
        invalidTheme.theme = BrandTheme(light: BrandPalette(colors: colors), dark: packaged.theme!.dark)
        self.reject { try invalidTheme.validate() }
        colors = packaged.theme!.light.colors
        colors["accentForeground"] = packaged.profile.accentLight
        invalidTheme.theme = BrandTheme(light: BrandPalette(colors: colors), dark: packaged.theme!.dark)
        self.reject { try invalidTheme.validate() }
        colors.removeValue(forKey: "separator")
        invalidTheme.theme = BrandTheme(light: BrandPalette(colors: colors), dark: packaged.theme!.dark)
        self.reject { try invalidTheme.validate() }
        self.reject { try BrandStyle(defaultAppearance: .light, cornerRadiusScale: 12, spacingScale: 1).validate() }
        self.reject { try BrandStyle(defaultAppearance: .light, cornerRadiusScale: 1, spacingScale: .infinity).validate() }
        self.reject { _ = try BrandLogo(data: Data("<svg><script>alert(1)</script></svg>".utf8)) }
        self.reject { _ = try BrandLogo(data: Data(repeating: 0, count: BrandLogo.maximumBytes + 1)) }
        var wrongLogo = object
        wrongLogo["logos"] = ["primary": ["mediaType": "image/jpeg", "base64": packaged.logos!.primary.base64]]
        self.reject { _ = try BrandPackage.decode(JSONSerialization.data(withJSONObject: wrongLogo)) }
        wrongLogo["logos"] = ["primary": ["mediaType": "image/png", "base64": "!!not-base64!!"]]
        self.reject { _ = try BrandPackage.decode(JSONSerialization.data(withJSONObject: wrongLogo)) }
        self.reject { _ = try BrandLogo(data: self.png(width: 4097, height: 1)) }

        let suite = "brand-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let active = directory.appendingPathComponent("active.json")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let store = BrandPackageStore(defaults: defaults, packaged: packaged, storageURL: active)
        precondition(!store.hasOverride && store.current() == packaged)
        var sizeable = BrandPackage(profile: custom, logos: BrandLogos(primary: try BrandLogo(data: self.png(width: 768, height: 768))))
        let largeData = try sizeable.encoded()
        precondition(largeData.count > 1_000_000)
        _ = try store.importData(largeData)
        precondition(defaults.data(forKey: BrandPackageStore.packageDefaultsKey) == nil)
        let previousFile = try Data(contentsOf: active)
        let previousRevision = store.revision
        self.reject { _ = try store.importData(Data("{invalid".utf8)) }
        // A structurally valid package with an invisible text accent must also
        // fail atomically, even though its dark button label is readable.
        let unsafeAccent = try self.invisibleAccentPackage(packaged, appearance: "light", background: "cardBackground")
        self.reject { _ = try store.importData(unsafeAccent) }
        for appearance in ["light", "dark"] {
            let unsafePolarity = try self.mixedSurfacePackage(packaged, appearance: appearance)
            self.reject { _ = try store.importData(unsafePolarity) }
            let unsafeHueBlend = try self.mixedSurfacePackage(packaged, appearance: appearance,
                firstBackground: "#FE0020", secondBackground: "#009A20", foreground: "#000000")
            self.reject { _ = try store.importData(unsafeHueBlend) }
        }
        precondition(store.current() == sizeable && store.revision == previousRevision)
        try self.require(try Data(contentsOf: active) == previousFile)
        try self.require(try BrandPackage.decode(store.exportData()) == sizeable)
        let started = Date()
        for _ in 0..<50_000 { precondition(store.current().profile == custom) }
        precondition(Date().timeIntervalSince(started) < 5, "Cached profile lookup must not decode embedded logos")
        try FileManager.default.removeItem(at: active)
        precondition(store.current() == sizeable, "The active snapshot must not reread the file while rendering")
        let blocked = directory.appendingPathComponent("cannot-overwrite-directory")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let failedPersistence = BrandPackageStore(defaults: defaults, packaged: packaged, storageURL: blocked)
        self.reject { _ = try failedPersistence.importData(largeData) }
        precondition(failedPersistence.current() == packaged && !failedPersistence.hasOverride, "Failed disk activation cannot change the cached package")
        // Imported legacy copy retains an existing separately selected logo and exports it in one file.
        _ = try store.importData(valid)
        precondition(store.current().profile == packaged.profile && store.current().logos == sizeable.logos)
        let cold = BrandPackageStore(defaults: defaults, packaged: packaged, storageURL: active)
        precondition(cold.current() == store.current())
        try store.reset()
        precondition(!store.hasOverride && store.current() == packaged && !FileManager.default.fileExists(atPath: active.path))
        defaults.set(valid, forKey: AppBrand.profileDefaultsKey)
        defaults.set(try sizeable.logos!.primary.validatedData(), forKey: BrandPackageStore.legacyLogoDefaultsKey)
        let legacy = BrandPackageStore(defaults: defaults, packaged: packaged, storageURL: active)
        try self.require(try BrandPackage.decode(legacy.exportData()).logos == sizeable.logos)
        try legacy.reset()

        for bank in ["Сбер", "Альфа-Банк", "Pichi"] {
            sizeable.profile = BrandProfile(appName: bank + " Голос", meetingName: bank + " Встречи", assistantName: bank + " AI", tagline: bank + " Your voice. Your ideas. Your Mac.", accentLight: "#123456", accentDark: "#ABCDEF", website: "https://example.com", support: "https://example.com/support")
            let brand = try BrandPackage.decode(sizeable.encoded())
            for original in ["FluidVoice", "Fluid Voice", "FLUIDVOICE", "fluidvoice", "FlUiDvOiCe", "FluidMeet", "Fluid Meet", "FLUID MEET", "Fluid Intelligence", "FLUID INTELLIGENCE"] {
                let label = AppBrand.substitutingProductNames(in: original, profile: brand.profile)
                precondition(!label.lowercased().contains("fluid"))
                precondition(label.lowercased().contains(bank.lowercased()))
            }
        }
        precondition(AppBrand.substitutingProductNames(in: "FluidVoice FluidMeet", profile: BrandProfile(appName: "FluidMeet Partner", meetingName: "Other", assistantName: "AI", tagline: "Voice", accentLight: "#123456", accentDark: "#ABCDEF", website: "https://example.com", support: "https://example.com")) == "FluidMeet Partner Other", "Imported names are data and must never be replaced recursively")
        // Imported product names may legitimately contain printf punctuation.
        // They must stay literal, consume no arguments and never transform argument data.
        for name in ["%@", "%lld", "100%", "100%@ Voice"] {
            let profile = BrandProfile(appName: name, meetingName: name + " Meet", assistantName: name + " AI", tagline: "Speech", accentLight: "#123456", accentDark: "#ABCDEF", website: "https://example.com", support: "https://example.com")
            let imported = try BrandPackage.decode(BrandPackage(profile: profile).encoded()).profile
            precondition(AppBrand.format("FluidVoice %@", profile: imported, language: .english, arguments: ["FluidVoice version %@ %lld 100%"]) == name + " FluidVoice version %@ %lld 100%")
            precondition(AppBrand.format("FLUIDVOICE %@", profile: imported, language: .english, arguments: ["1.6.10"]) == name.uppercased() + " 1.6.10")
            precondition(AppBrand.format("Rolled back to %@. FluidVoice will relaunch shortly.", profile: imported, language: .english, arguments: ["FluidVoice %@"]) == "Rolled back to FluidVoice %@. " + name + " will relaunch shortly.")
            precondition(AppBrand.format("FluidMeet + Fluid Intelligence: %lld%%", profile: imported, language: .english, arguments: [25]) == name + " Meet + " + name + " AI: 25%")
            let trainingWord = "FluidVoice ё %@ 100%"
            precondition(AppBrand.format("Say %@ naturally, then pause. FluidVoice records and listens again automatically.",
                profile: imported, language: .english, arguments: [trainingWord])
                == "Say " + trainingWord + " naturally, then pause. " + name + " records and listens again automatically.")
            precondition(AppBrand.substitutingProductNames(in: "FluidVoice", profile: imported) == name, "Plain text must not double percent characters")
        }
        precondition(AppBrand.filenamePrefix(for: "Сбер/Голос:Demo\\Preview") == "Сбер_Голос_Demo_Preview")
        precondition(AppBrand.filenamePrefix(for: "100%@ Voice") == "100%@ Voice")
        precondition(AppBrand.filenamePrefix(for: "..") == "Voice")
        precondition(AppBrand.filenamePrefix(for: String(repeating: "🗣", count: 120)).utf8.count <= 120)
        precondition(AppBrand.releaseBundleIdentifier(from: "ai.pichi.voice.debug") == "ai.pichi.voice")
        precondition(AppBrand.releaseBundleIdentifier(from: "com.partner.debug.voice") == "com.partner.debug.voice")
        precondition(AppBrand.keychainService.hasPrefix(AppBrand.bundleIdentifier))
        precondition(AppBrand.modelsDirectory.path.contains(AppBrand.bundleIdentifier))
        try self.verifyDiagnosticLogIsolation()
        precondition(!AppBrand.updatesEnabled && AppBrand.feedbackEndpoint == nil)
        self.reject { try BrandDistribution(formatVersion: 1, repository: "https://github.com/a/b", updatesEnabled: true).validate() }
        self.reject { try BrandDistribution(formatVersion: 1, repository: "https://attacker.invalid/a/b").validate() }
        let signedPolicy = BrandDistribution(formatVersion: 1, repository: "https://github.com/a/b", updatesEnabled: true, expectedSigningTeam: "ABCDEFGHIJ")
        try signedPolicy.validate()
        precondition(!signedPolicy.updatesAllowedForCurrentSignature, "Unsigned local tools must not enable the updater")
        print("Portable brand package: validation, atomic activation, cache, legacy migration and identity isolation passed")
    }

    static func invisibleAccentPackage(_ packaged: BrandPackage, appearance: String, background: String, paletteColors: [String: String]? = nil) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: packaged.encoded()) as! [String: Any]
        var profile = object["profile"] as! [String: Any]
        var theme = object["theme"] as! [String: Any]
        var palette = theme[appearance] as! [String: Any]
        var colors = paletteColors ?? (palette["colors"] as! [String: String])
        // Keep button ink valid so only the standalone accent contract rejects it.
        profile[appearance == "light" ? "accentLight" : "accentDark"] = colors[background]!
        colors["accentForeground"] = colors["primaryText"]!
        palette["colors"] = colors
        theme[appearance] = palette
        object["profile"] = profile
        object["theme"] = theme
        return try JSONSerialization.data(withJSONObject: object)
    }

    static func mixedSurfacePackage(_ packaged: BrandPackage, appearance: String,
                                    firstBackground: String = "#000000", secondBackground: String = "#FFFFFF",
                                    foreground: String = "#767676", accentForeground: String = "#FFFFFF") throws -> Data {
        var object = try JSONSerialization.jsonObject(with: packaged.encoded()) as! [String: Any]
        var profile = object["profile"] as! [String: Any]
        var theme = object["theme"] as! [String: Any]
        var colors = Dictionary(uniqueKeysWithValues: BrandPalette.tokens.map { ($0, foreground) })
        for (index, background) in ["windowBackground", "contentBackground", "sidebarBackground", "cardBackground", "elevatedCardBackground", "toolbarBackground"].enumerated() {
            colors[background] = index.isMultiple(of: 2) ? firstBackground : secondBackground
        }
        colors["accentForeground"] = accentForeground
        profile[appearance == "light" ? "accentLight" : "accentDark"] = foreground
        theme[appearance] = ["colors": colors]
        object["profile"] = profile
        object["theme"] = theme
        return try JSONSerialization.data(withJSONObject: object)
    }

    static func verifyPaletteForegroundContrast(_ packaged: BrandPackage) throws {
        let backgrounds = ["windowBackground", "contentBackground", "sidebarBackground", "cardBackground", "elevatedCardBackground", "toolbarBackground"]
        for (appearance, palette) in [("light", packaged.theme!.light), ("dark", packaged.theme!.dark)] {
            let accent = appearance == "light" ? packaged.profile.accentLight : packaged.profile.accentDark
            for background in backgrounds {
                // Isolate one background: #767676 passes 3:1 against BOTH black
                // and white but disappears only on that one selected surface.
                // Primary ink and every other role remain valid there, so skipping
                // any one of the six backgrounds would accept this fixture.
                let base = appearance == "light" ? "#FFFFFF" : "#000000"
                let ink = appearance == "light" ? "#000000" : "#FFFFFF"
                var colors = Dictionary(uniqueKeysWithValues: BrandPalette.tokens.map { ($0, ink) })
                for token in backgrounds { colors[token] = base }
                colors[background] = "#767676"
                colors["accentForeground"] = base
                try BrandPalette(colors: colors).validate(accent: ink)
                for token in ["secondaryText", "tertiaryText", "warning", "success"] {
                    var invalid = colors
                    invalid[token] = "#767676"
                    self.reject { try BrandPalette(colors: invalid).validate(accent: ink) }
                }
                self.reject { _ = try BrandPackage.decode(self.invisibleAccentPackage(packaged, appearance: appearance, background: background, paletteColors: colors)) }
            }
            for token in ["primaryText", "secondaryText", "tertiaryText", "warning", "success", "accentForeground", "cardBackground"] {
                for alphaColor in ["#FFFFFF00", "#FFFFFFFF"] {
                    var colors = palette.colors
                    colors[token] = alphaColor
                    self.reject { try BrandPalette(colors: colors).validate(accent: accent) }
                }
            }
        }
        for appearance in ["light", "dark"] {
            let data = try self.mixedSurfacePackage(packaged, appearance: appearance)
            // Decode without validation only to establish the adversarial fixture:
            // every opaque pairing meets the old thresholds, including button ink.
            let unsafe = try JSONDecoder().decode(BrandPackage.self, from: data)
            let palette = appearance == "light" ? unsafe.theme!.light : unsafe.theme!.dark
            for token in ["primaryText", "secondaryText", "tertiaryText", "warning", "success"] {
                for background in backgrounds {
                    precondition(BrandPalette.contrast(palette.colors[token]!, palette.colors[background]!) >= 4.5)
                }
            }
            precondition(BrandPalette.contrast(palette.colors["accentForeground"]!, "#767676") >= 4.5)
            for background in backgrounds {
                precondition(BrandPalette.contrast("#767676", palette.colors[background]!) >= 3)
            }
            // A black/white mixture can equal #767676 and erase all those roles.
            self.reject { _ = try BrandPackage.decode(data) }
        }
        for appearance in ["light", "dark"] {
            let data = try self.mixedSurfacePackage(packaged, appearance: appearance,
                firstBackground: "#FE0020", secondBackground: "#009A20", foreground: "#000000")
            let unsafe = try JSONDecoder().decode(BrandPackage.self, from: data)
            let palette = appearance == "light" ? unsafe.theme!.light : unsafe.theme!.dark
            for background in backgrounds {
                // Endpoint contrast and consistent luminance polarity are both
                // valid. The exact 50:50 sRGB mix nevertheless fails even 3:1.
                precondition(BrandPalette.contrast("#000000", palette.colors[background]!) >= 4.5)
                precondition(BrandPalette.luminance("#000000") < BrandPalette.luminance(palette.colors[background]!))
            }
            // Ink is outside even the RGB envelope's luminance interval;
            // enforcing the ratio at its minimum is necessary, not only polarity.
            precondition(BrandPalette.luminance("#000000") < BrandPalette.luminance("#000020"))
            precondition(BrandPalette.contrast("#000000", "#000020") < 3)
            precondition(BrandPalette.contrast("#000000", "#7F4D20") < 3)
            precondition(BrandPalette.contrast(palette.colors["accentForeground"]!, "#000000") >= 4.5)
            self.reject { _ = try BrandPackage.decode(data) }
        }
        // The new standalone-accent rule must still permit readable portable
        // themes. Shipped and both bank packages are decoded earlier in main.
        for (background, foreground, accent) in [("#FFFFFF", "#000000", "#0000FF"), ("#000000", "#FFFFFF", "#00FFFF")] {
            var colors = Dictionary(uniqueKeysWithValues: BrandPalette.tokens.map { ($0, foreground) })
            for token in backgrounds { colors[token] = background }
            colors["accentForeground"] = background
            try BrandPalette(colors: colors).validate(accent: accent)
        }
        print("Portable palette: 60 light/dark foreground rejection checks, 28 alpha rejections, 2 opposite-polarity rejections, 2 saturated-blend rejections and 2 readable palette checks passed")
    }

    static func verifyDiagnosticLogIsolation() throws {
        let library = FileManager.default.temporaryDirectory.appendingPathComponent("log-identity-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: library) }
        let identifiers = ["com.FluidApp.app", "ai.pichi.voice", "ai.pichi.voice.debug", "com.partner.voice"]
        let directories = identifiers.map { AppBrand.logsDirectory(in: library, storageNamespace: $0) }
        precondition(Set(directories).count == identifiers.count, "Installed identities must not share diagnostics")
        for (identifier, directory) in zip(identifiers, directories) {
            precondition(directory == library.appendingPathComponent("Logs", isDirectory: true).appendingPathComponent(identifier, isDirectory: true))
        }
        // Appearance imports cannot supply a log namespace or redirect another installation.
        let packageData = try Data(contentsOf: URL(fileURLWithPath: "Configuration/BrandExamples/sber-demo.json"))
        let object = try JSONSerialization.jsonObject(with: packageData) as! [String: Any]
        for forbidden in ["storageNamespace", "logDirectory", "logsDirectory"] {
            var injected = object
            injected[forbidden] = "com.FluidApp.app"
            self.reject { _ = try BrandPackage.decode(JSONSerialization.data(withJSONObject: injected)) }
        }
        precondition(AppBrand.logsDirectory(in: library, storageNamespace: AppBrand.storageNamespace)
            == library.appendingPathComponent("Logs", isDirectory: true).appendingPathComponent(AppBrand.bundleIdentifier, isDirectory: true))
        // The real logger smoke test is compiled only with the existing isolated baseline mode.
        #if FLUID_ASR_BASELINE
        let logger = FileLogger.shared
        let log = logger.currentLogFileURL()
        let logDirectory = log.deletingLastPathComponent()
        let baselineRoot = logDirectory.deletingLastPathComponent().deletingLastPathComponent()
        precondition(baselineRoot.deletingLastPathComponent().standardizedFileURL == URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).standardizedFileURL)
        precondition(baselineRoot.lastPathComponent.hasPrefix("FluidASRBaseline-"))
        precondition(logDirectory.lastPathComponent == AppBrand.storageNamespace)
        precondition(log.lastPathComponent == "diagnostics.log")
        defer { try? FileManager.default.removeItem(at: baselineRoot) }
        let oldDirectory = baselineRoot.appendingPathComponent("Logs/Fluid", isDirectory: true)
        try FileManager.default.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
        let oldLog = oldDirectory.appendingPathComponent("Fluid.log")
        let sentinel = Data("Another installation's synthetic log\n".utf8)
        try sentinel.write(to: oldLog)
        let line = String(repeating: "x", count: 32_768)
        for _ in 0..<80 { logger.appendSync(line: line) }
        logger.append(line: "asynchronous write")
        logger.appendSync(line: "joined queue barrier")
        FileLogger.writeCrashLineDirect("synthetic direct crash diagnostic")
        let current = try String(contentsOf: log, encoding: .utf8)
        precondition(current.contains("asynchronous write") && current.contains("joined queue barrier"))
        precondition(current.contains("synthetic direct crash diagnostic"), "Crash descriptor must follow the rotated current file")
        let files = try FileManager.default.contentsOfDirectory(at: logDirectory, includingPropertiesForKeys: [.fileSizeKey])
        precondition(Set(files.map(\.lastPathComponent)) == ["diagnostics.log", "diagnostics.log.1"])
        for file in files {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize!
            precondition(size <= 1_048_576 + line.utf8.count + 1, "The existing rotation bound includes at most one final line")
        }
        try self.require(try Data(contentsOf: oldLog) == sentinel)
        print("Diagnostic log identity, isolated baseline, rotation, joined queue and direct crash writes passed")
        #endif
    }

    static func png(width: Int, height: Int) throws -> Data {
        // Reproducible noise avoids a tiny compressed fixture while keeping all data synthetic.
        var random: UInt32 = 12345
        let pixels = (0..<(width * height * 4)).map { index -> UInt8 in
            random = random &* 1_664_525 &+ 1_013_904_223
            return index % 4 == 3 ? 255 : UInt8(truncatingIfNeeded: random >> 24)
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
