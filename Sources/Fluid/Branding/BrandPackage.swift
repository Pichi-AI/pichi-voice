import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Portable appearance data. There are no executable paths, remote assets or service credentials.
nonisolated struct BrandPackage: Codable, Equatable, Sendable {
    static let maximumBytes = 17_000_000
    let formatVersion: Int
    var profile: BrandProfile
    var theme: BrandTheme?
    var style: BrandStyle?
    var logos: BrandLogos?
    var links: BrandLinks?

    init(profile: BrandProfile, theme: BrandTheme? = nil, style: BrandStyle? = nil, logos: BrandLogos? = nil, links: BrandLinks? = nil) {
        self.formatVersion = 1
        self.profile = profile
        self.theme = theme
        self.style = style
        self.logos = logos
        self.links = links
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= self.maximumBytes else { throw BrandProfile.ValidationError.invalid("Brand package is larger than 17 MB.") }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BrandProfile.ValidationError.invalid("Choose a JSON brand package.")
        }
        // Previously exported eight-field profiles remain supported.
        if object["formatVersion"] == nil { return Self(profile: try BrandProfile.decode(data)) }
        let allowed = Set(["formatVersion", "profile", "theme", "style", "logos", "links"])
        guard Set(object.keys).isSubset(of: allowed) else {
            throw BrandProfile.ValidationError.invalid("Brand package contains unsupported fields.")
        }
        let result = try JSONDecoder().decode(Self.self, from: data)
        try result.validate()
        return result
    }

    func validate() throws {
        guard self.formatVersion == 1 else { throw BrandProfile.ValidationError.invalid("Unsupported brand package version.") }
        try self.profile.validate()
        try self.theme?.validate(profile: self.profile)
        try self.style?.validate()
        try self.logos?.validate()
        try self.links?.validate()
    }

    func encoded() throws -> Data {
        try self.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw BrandProfile.ValidationError.invalid("Brand package is larger than 17 MB.") }
        return data
    }
}

nonisolated struct BrandLinks: Codable, Equatable, Sendable {
    var repository: String?

    func validate() throws {
        if let repository { try BrandProfile.validateHTTPS(repository) }
    }
}

nonisolated struct BrandStyle: Codable, Equatable, Sendable {
    enum Appearance: String, Codable, Sendable { case system, light, dark }
    /// Native designs retain Apple's multilingual font coverage and font accessibility.
    enum FontDesign: String, Codable, CaseIterable, Sendable { case sans, serif, rounded }
    var defaultAppearance: Appearance = .system
    var cornerRadiusScale: Double = 1
    var spacingScale: Double = 1
    /// Preferred first-run speech language. Missing fields preserve legacy appearance packages.
    var defaultOnboardingLanguageID: String? = nil
    /// Missing fields retain the original body and editorial heading designs.
    var bodyFontDesign: FontDesign? = nil
    var titleFontDesign: FontDesign? = nil

    func validate() throws {
        if let languageID = self.defaultOnboardingLanguageID,
           PichiInterfaceLanguage(rawValue: languageID) == nil {
            throw BrandProfile.ValidationError.invalid("Choose a valid language identifier for the onboarding default.")
        }
        guard self.cornerRadiusScale.isFinite, (0.75...1.5).contains(self.cornerRadiusScale),
              self.spacingScale.isFinite, (0.8...1.3).contains(self.spacingScale) else {
            throw BrandProfile.ValidationError.invalid("Brand spacing or corner radius is outside the supported range.")
        }
    }
}

nonisolated struct BrandTheme: Codable, Equatable, Sendable {
    let light: BrandPalette
    let dark: BrandPalette

    func validate(profile: BrandProfile) throws {
        try self.light.validate(accent: profile.accentLight)
        try self.dark.validate(accent: profile.accentDark)
    }
}

/// Full shared AppTheme palette. Keeping these tokens central avoids screen-specific theme forks.
nonisolated struct BrandPalette: Codable, Equatable, Sendable {
    static let tokens = Set([
        "windowBackground", "contentBackground", "sidebarBackground", "cardBackground", "elevatedCardBackground", "toolbarBackground",
        "cardBorder", "separator", "primaryText", "secondaryText", "tertiaryText", "accentForeground", "warning", "success",
    ])
    let colors: [String: String]

    func validate(accent: String) throws {
        guard Set(self.colors.keys) == Self.tokens else {
            throw BrandProfile.ValidationError.invalid("Theme must define every supported color token.")
        }
        for value in self.colors.values { try BrandProfile.validateColor(value) }
        let backgrounds = ["windowBackground", "contentBackground", "sidebarBackground", "cardBackground", "elevatedCardBackground", "toolbarBackground"]
        // Validate readable text across the actual surfaces used by the shared theme.
        for background in backgrounds {
            let surface = self.colors[background]!
            guard Self.contrast(self.colors["primaryText"]!, surface) >= 4.5,
                  ["secondaryText", "tertiaryText", "warning", "success"].allSatisfy({
                      Self.contrast(self.colors[$0]!, surface) >= 3
                  }), Self.contrast(accent, surface) >= 3 else {
                // Accent and status colors are also used as text and standalone icons,
                // not only as button fills. Checking the paired button label alone
                // would accept a white accent that disappears on a light surface.
                throw BrandProfile.ValidationError.invalid("Theme text needs more contrast against its backgrounds.")
            }
        }
        // Opaque contrast alone admits mid-gray ink on both black and white.
        // Translucent layers can blend those surfaces into the ink's luminance.
        // Each shared foreground therefore needs one polarity across all surfaces.
        let backgroundLuminances = backgrounds.map { Self.luminance(self.colors[$0]!) }
        let darkest = backgroundLuminances.min()!
        let lightest = backgroundLuminances.max()!
        for foreground in ["primaryText", "secondaryText", "tertiaryText", "warning", "success"].map({ self.colors[$0]! }) + [accent] {
            let luminance = Self.luminance(foreground)
            guard luminance < darkest || luminance > lightest else {
                throw BrandProfile.ValidationError.invalid("Theme text needs more contrast against its backgrounds.")
            }
        }
        guard Self.contrast(self.colors["accentForeground"]!, accent) >= 4.5 else {
            throw BrandProfile.ValidationError.invalid("Theme button text needs more contrast against the accent.")
        }
    }

    static func contrast(_ first: String, _ second: String) -> Double {
        let values = [self.luminance(first), self.luminance(second)]
        return (values.max()! + 0.05) / (values.min()! + 0.05)
    }

    static func luminance(_ color: String) -> Double {
        guard let rgb = UInt32(color.dropFirst(), radix: 16) else { return 0 }
        let channels = [Double((rgb >> 16) & 255), Double((rgb >> 8) & 255), Double(rgb & 255)].map { value -> Double in
            let normalized = value / 255
            return normalized <= 0.04045 ? normalized / 12.92 : pow((normalized + 0.055) / 1.055, 2.4)
        }
        return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
    }
}

nonisolated struct BrandLogo: Codable, Equatable, Sendable {
    let mediaType: String
    let base64: String
    static let maximumBytes = 4_194_304

    init(data: Data) throws {
        let type = try Self.validatedType(data)
        self.mediaType = type == UTType.png.identifier ? "image/png" : "image/jpeg"
        self.base64 = data.base64EncodedString()
    }

    func validatedData() throws -> Data {
        guard self.base64.utf8.count <= 5_592_408, let data = Data(base64Encoded: self.base64) else {
            throw BrandProfile.ValidationError.invalid("Logo must contain valid base64 image data.")
        }
        let type = try Self.validatedType(data)
        guard (self.mediaType == "image/png" && type == UTType.png.identifier)
            || (self.mediaType == "image/jpeg" && type == UTType.jpeg.identifier) else {
            throw BrandProfile.ValidationError.invalid("Logo media type does not match its image data.")
        }
        return data
    }

    private static func validatedType(_ data: Data) throws -> String {
        guard data.count <= Self.maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source) as String?, [UTType.png.identifier, UTType.jpeg.identifier].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...4096).contains(width), (1...4096).contains(height),
              CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) != nil else {
            throw BrandProfile.ValidationError.invalid("Choose a valid PNG or JPEG logo up to 4 MB and 4096 pixels per side.")
        }
        return type
    }
}

nonisolated struct BrandLogos: Codable, Equatable, Sendable {
    var primary: BrandLogo
    var light: BrandLogo?
    var dark: BrandLogo?
    var menuBar: BrandLogo?

    func validate() throws {
        let logos = [self.primary, self.light, self.dark, self.menuBar].compactMap { $0 }
        let total = try logos.reduce(0) { try $0 + $1.validatedData().count }
        guard total <= 12_582_912 else { throw BrandProfile.ValidationError.invalid("Combined brand logos are larger than 12 MB.") }
    }
}

/// One write commits the entire validated package, so a failed import cannot partly change appearance.
nonisolated final class BrandPackageStore: @unchecked Sendable {
    static let packageDefaultsKey = "PichiBrandPackage"
    static let legacyLogoDefaultsKey = "PichiBrandLogo"
    static let shared = BrandPackageStore(
        defaults: .standard, packaged: AppBrand.packagedPackage,
        storageURL: AppBrand.applicationSupportDirectory.appendingPathComponent("Brand/active.json")
    )
    private let defaults: UserDefaults
    private let packaged: BrandPackage
    private let lock = NSLock()
    private let storageURL: URL?
    private var cachedPackage: BrandPackage?
    private var cachedOverride = false
    private var generation = 0

    init(defaults: UserDefaults, packaged: BrandPackage, storageURL: URL? = nil) {
        self.defaults = defaults
        self.packaged = packaged
        self.storageURL = storageURL
    }

    var revision: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.generation
    }

    var hasOverride: Bool {
        _ = self.current()
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.cachedOverride
    }

    func current() -> BrandPackage {
        self.lock.lock()
        defer { self.lock.unlock() }
        if let cachedPackage { return cachedPackage }
        let storedData: Data?
        if let storageURL = self.storageURL,
           let size = try? storageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size <= BrandPackage.maximumBytes {
            storedData = try? Data(contentsOf: storageURL)
        } else {
            storedData = self.defaults.data(forKey: Self.packageDefaultsKey)
        }
        if let data = storedData, let package = try? BrandPackage.decode(data) {
            self.cachedPackage = package
            self.cachedOverride = true
            return package
        }
        var result = self.packaged
        if let data = self.defaults.data(forKey: AppBrand.profileDefaultsKey), let profile = try? BrandProfile.decode(data) {
            result = BrandPackage(profile: profile, logos: self.packaged.logos)
            self.cachedOverride = true
        }
        if let data = self.defaults.data(forKey: Self.legacyLogoDefaultsKey), let logo = try? BrandLogo(data: data) {
            result.logos = BrandLogos(primary: logo)
            self.cachedOverride = true
        }
        self.cachedPackage = result
        return result
    }

    @discardableResult
    func importData(_ data: Data) throws -> BrandPackage {
        var candidate = try BrandPackage.decode(data)
        // A legacy profile only changes its eight historical fields. Keep its already selected logo.
        if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["formatVersion"] == nil {
            candidate.logos = self.current().logos
        }
        let encoded = try candidate.encoded()
        self.lock.lock()
        defer { self.lock.unlock() }
        if let storageURL {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoded.write(to: storageURL, options: .atomic)
            self.defaults.removeObject(forKey: Self.packageDefaultsKey)
        } else {
            self.defaults.set(encoded, forKey: Self.packageDefaultsKey)
        }
        self.cachedPackage = candidate
        self.cachedOverride = true
        self.generation += 1
        self.defaults.removeObject(forKey: AppBrand.profileDefaultsKey)
        self.defaults.removeObject(forKey: Self.legacyLogoDefaultsKey)
        return candidate
    }

    func exportData() throws -> Data { try self.current().encoded() }

    func reset() throws {
        self.lock.lock()
        defer { self.lock.unlock() }
        if let storageURL, FileManager.default.fileExists(atPath: storageURL.path) { try FileManager.default.removeItem(at: storageURL) }
        self.defaults.removeObject(forKey: Self.packageDefaultsKey)
        self.defaults.removeObject(forKey: AppBrand.profileDefaultsKey)
        self.defaults.removeObject(forKey: Self.legacyLogoDefaultsKey)
        self.cachedPackage = self.packaged
        self.cachedOverride = false
        self.generation += 1
    }
}
