import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// This intentionally small reader exists only in the isolated design executable.
// The application should reuse AppBrand / AppTheme after their AppKit boundary is isolated.
struct PrototypeBrand: Decodable {
    struct Profile: Decodable {
        let appName: String
        let meetingName: String
        let accentLight: String
        let accentDark: String
    }
    struct Palette: Decodable { let colors: [String: String] }
    struct Theme: Decodable { let light: Palette; let dark: Palette }
    struct Style: Decodable {
        let bodyFontDesign: String?
        let titleFontDesign: String?
        let spacingScale: Double
        let cornerRadiusScale: Double
    }
    struct Logo: Decodable { let base64: String }
    struct Logos: Decodable { let primary: Logo }
    let profile: Profile
    let theme: Theme
    let style: Style
    let logos: Logos

    static let shared: Self = {
        guard let url = Bundle.main.url(forResource: "brand-package", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let brand = try? JSONDecoder().decode(Self.self, from: data) else {
            fatalError("The prototype requires the repository's portable brand package.")
        }
        return brand
    }()

    func font(_ role: TextRole, weight: Font.Weight? = nil) -> Font {
        let selected = role.isTitle ? style.titleFontDesign : style.bodyFontDesign
        let design: Font.Design = selected == "serif" ? .serif : selected == "rounded" ? .rounded : .default
        #if os(macOS)
        // Match iOS default text-role sizes in the native Mac concept window.
        // The iOS view uses scalable Apple text styles, never per-language fonts.
        return .system(size: role.previewPointSize, weight: weight ?? role.weight, design: design)
        #else
        return .system(role.style, design: design).weight(weight ?? role.weight)
        #endif
    }

    var logo: Image {
        let data = Data(base64Encoded: logos.primary.base64)!
        #if os(macOS)
        return Image(nsImage: NSImage(data: data)!)
        #else
        return Image(uiImage: UIImage(data: data)!)
        #endif
    }
}

enum TextRole {
    case display, title, section, body, caption
    var isTitle: Bool { self == .display || self == .title || self == .section }
    var style: Font.TextStyle {
        switch self {
        case .display: .largeTitle
        case .title: .title2
        case .section: .headline
        case .body: .body
        case .caption: .callout
        }
    }
    var weight: Font.Weight { isTitle ? .semibold : .regular }
    var previewPointSize: CGFloat {
        switch self { case .display: 34; case .title: 22; case .section: 17; case .body: 17; case .caption: 15 }
    }
}

struct PrototypeTheme {
    let dark: Bool
    var brand: PrototypeBrand { .shared }
    var palette: [String: String] { dark ? brand.theme.dark.colors : brand.theme.light.colors }
    func color(_ token: String) -> Color {
        let value = UInt32(palette[token]!.dropFirst(), radix: 16)!
        return Color(.sRGB, red: Double((value >> 16) & 255) / 255,
                     green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, opacity: 1)
    }
    var accent: Color {
        let hex = dark ? brand.profile.accentDark : brand.profile.accentLight
        let value = UInt32(hex.dropFirst(), radix: 16)!
        return Color(.sRGB, red: Double((value >> 16) & 255) / 255,
                     green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, opacity: 1)
    }
    var radius: CGFloat { 18 * brand.style.cornerRadiusScale }
    var gap: CGFloat { 20 * brand.style.spacingScale }
    func font(_ role: TextRole, weight: Font.Weight? = nil) -> Font { brand.font(role, weight: weight) }
}

enum Copy {
    static var bundle: Bundle = .main
    static func text(_ key: String) -> String {
        NSLocalizedString(key, tableName: "Localizable", bundle: bundle, comment: "")
    }
}

struct SyntheticFixtures: Decodable {
    struct Utterance: Decodable, Identifiable {
        let id: Int
        let time: String
        let owner: Bool
        let text: String
    }
    struct Session: Decodable, Identifiable {
        let id: Int
        let title: String
        let time: String
        let duration: String
        let place: String
    }
    struct SpeechModel: Decodable, Identifiable {
        let id: String
        let name: String
        let detailKey: String
        let languageKey: String
        let symbol: String
        let size: String
    }
    let utterances: [Utterance]
    let sessions: [Session]
    let speechModels: [SpeechModel]
    static let shared: Self = {
        let url = Bundle.main.url(forResource: "synthetic-fixtures", withExtension: "json")!
        return try! JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }()
}
