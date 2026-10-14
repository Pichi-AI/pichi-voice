#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import SwiftUI

/// Edit these four choices to experiment across the app, then rebuild.
/// `.system` keeps Apple's native font. `.named("AvenirNext-Regular")` uses an installed
/// PostScript font name. `.newYork` uses Apple’s native serif at every size and weight.
/// Invalid names fall back to the original system design.
enum FluidTypography {
    enum Role { case body, title }
    enum Family {
        case system
        case newYork
        case named(String)
    }

    static let standard: Family = .system
    static let serif: Family = .system
    static let rounded: Family = .system
    static let monospace: Family = .system

    // Resolve each choice once, rather than looking up installed fonts during rendering.
    private static let standardName = resolvedName(for: standard)
    private static let serifName = resolvedName(for: serif)
    private static let roundedName = resolvedName(for: rounded)
    private static let monospaceName = resolvedName(for: monospace)

    static func resolvedName(for family: Family) -> String? {
        guard case let .named(name) = family else { return nil }
        #if canImport(AppKit)
        guard NSFont(name: name, size: 12) != nil else { return nil }
        #else
        guard UIFont(name: name, size: 12) != nil else { return nil }
        #endif
        return name
    }

    static func name(for design: Font.Design) -> String? {
        switch design {
        case .serif: self.serifName
        case .rounded: self.roundedName
        case .monospaced: self.monospaceName
        default: self.standardName
        }
    }

    static var overridesStandard: Bool {
        self.overridesStandard(style: AppBrand.package.style)
    }

    static func overridesStandard(style: BrandStyle?) -> Bool {
        if case .system = self.standard { return self.systemDesign(for: .default, style: style) != .default }
        return true
    }

    /// Package lookup uses the existing decoded package cache, never file or glyph lookup.
    /// Rounded metrics, monospaced code and native system symbols retain their own roles.
    static func systemDesign(for design: Font.Design, role: Role = .body, style: BrandStyle? = AppBrand.package.style) -> Font.Design {
        let family: Family = switch design {
        case .serif: self.serif
        case .rounded: self.rounded
        case .monospaced: self.monospace
        default: self.standard
        }
        let originalDesign: Font.Design = if case .newYork = family { .serif } else { design }
        if design == .monospaced || design == .rounded { return originalDesign }
        let configured = role == .title || design == .serif ? style?.titleFontDesign : style?.bodyFontDesign
        if let configured {
            return switch configured {
            case .sans: .default
            case .serif: .serif
            case .rounded: .rounded
            }
        }
        return originalDesign
    }

    static func pointSize(for style: Font.TextStyle) -> CGFloat {
        #if canImport(AppKit)
        switch style {
        case .largeTitle: NSFont.preferredFont(forTextStyle: .largeTitle).pointSize
        case .title: NSFont.preferredFont(forTextStyle: .title1).pointSize
        case .title2: NSFont.preferredFont(forTextStyle: .title2).pointSize
        case .title3: NSFont.preferredFont(forTextStyle: .title3).pointSize
        case .headline: NSFont.preferredFont(forTextStyle: .headline).pointSize
        case .subheadline: NSFont.preferredFont(forTextStyle: .subheadline).pointSize
        case .callout: NSFont.preferredFont(forTextStyle: .callout).pointSize
        case .footnote: NSFont.preferredFont(forTextStyle: .footnote).pointSize
        case .caption: NSFont.preferredFont(forTextStyle: .caption1).pointSize
        case .caption2: NSFont.preferredFont(forTextStyle: .caption2).pointSize
        default: NSFont.preferredFont(forTextStyle: .body).pointSize
        }
        #else
        let native: UIFont.TextStyle = switch style {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
        return UIFont.preferredFont(forTextStyle: native).pointSize
        #endif
    }
}

extension Font {
    /// Family indirection only: default size, weight, and design remain native.
    static func fluidSystem(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default,
                            role: FluidTypography.Role = .body, style: BrandStyle? = AppBrand.package.style) -> Font {
        guard let name = FluidTypography.name(for: design) else {
            return .system(size: size, weight: weight, design: FluidTypography.systemDesign(for: design, role: role, style: style))
        }
        return .custom(name, fixedSize: size).weight(weight)
    }

    static func fluidSystem(_ textStyle: Font.TextStyle, design: Font.Design = .default, style: BrandStyle? = AppBrand.package.style) -> Font {
        let role: FluidTypography.Role = [.largeTitle, .title, .title2, .title3].contains(textStyle) ? .title : .body
        guard let name = FluidTypography.name(for: design) else {
            return .system(textStyle, design: FluidTypography.systemDesign(for: design, role: role, style: style))
        }
        let font = Font.custom(name, size: FluidTypography.pointSize(for: textStyle), relativeTo: textStyle)
        return textStyle == .headline ? font.weight(.semibold) : font
    }
}

#if canImport(AppKit)
extension NSFont {
    static func fluidSystemFont(ofSize size: CGFloat, weight: NSFont.Weight = .regular,
                                style: BrandStyle? = AppBrand.package.style) -> NSFont {
        self.fluidFont(ofSize: size, weight: weight, design: .default, style: style)
    }

    static func fluidMonospacedSystemFont(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
        self.fluidFont(ofSize: size, weight: weight, design: .monospaced)
    }

    static func fluidFont(ofSize size: CGFloat, weight: NSFont.Weight, design: Font.Design,
                          role: FluidTypography.Role = .body, style: BrandStyle? = AppBrand.package.style) -> NSFont {
        if let name = FluidTypography.name(for: design), let font = NSFont(name: name, size: size) {
            let descriptor = font.fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue]])
            return NSFont(descriptor: descriptor, size: size) ?? font
        }
        let resolved = FluidTypography.systemDesign(for: design, role: role, style: style)
        if resolved == .monospaced { return .monospacedSystemFont(ofSize: size, weight: weight) }
        let nativeDesign: NSFontDescriptor.SystemDesign = resolved == .serif ? .serif : resolved == .rounded ? .rounded : .default
        if let descriptor = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor.withDesign(nativeDesign),
           let font = NSFont(descriptor: descriptor, size: size)
        {
            return font
        }
        return .systemFont(ofSize: size, weight: weight)
    }
}

#endif
