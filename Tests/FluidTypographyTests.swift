import AppKit
import CoreText
import SwiftUI

@main
struct FluidTypographyTests {
    static func main() throws {
        precondition(FluidTypography.resolvedName(for: .named("FluidVoice-Missing-Font")) == nil)
        precondition(FluidTypography.resolvedName(for: .system) == nil)
        let custom = ProcessInfo.processInfo.environment["TEST_CUSTOM_FONTS"] == "1"
        for design: Font.Design in [.default, .serif, .rounded, .monospaced] {
            if custom {
                precondition(FluidTypography.name(for: design) == "AvenirNext-Regular")
                precondition(Font.fluidSystem(size: 23, weight: .semibold, design: design) == Font.custom("AvenirNext-Regular", fixedSize: 23).weight(.semibold))
            } else {
                precondition(FluidTypography.name(for: design) == nil)
                precondition(Font.fluidSystem(size: 23, weight: .semibold, design: design) == Font.system(
                    size: 23,
                    weight: .semibold,
                    design: FluidTypography.systemDesign(for: design)
                ))
                precondition(Font.fluidSystem(.caption, design: design) == Font.system(.caption, design: FluidTypography.systemDesign(for: design)))
            }
        }
        let native = NSFont.fluidSystemFont(ofSize: 18, weight: .semibold)
        let mono = NSFont.fluidMonospacedSystemFont(ofSize: 13, weight: .regular)
        precondition(native.pointSize == 18 && mono.pointSize == 13)
        if custom {
            precondition(native.familyName == "Avenir Next" && mono.familyName == "Avenir Next")
        } else {
            if FluidTypography.systemDesign(for: .default) == .serif {
                guard let descriptor = NSFont.systemFont(ofSize: 18, weight: .semibold).fontDescriptor.withDesign(.serif) else {
                    preconditionFailure("The system serif font must be available")
                }
                precondition(native == NSFont(descriptor: descriptor, size: 18))
            } else {
                precondition(native == NSFont.systemFont(ofSize: 18, weight: .semibold))
            }
            if FluidTypography.systemDesign(for: .monospaced) == .serif {
                guard let descriptor = NSFont.systemFont(ofSize: 13, weight: .regular).fontDescriptor.withDesign(.serif) else {
                    preconditionFailure("The system serif font must be available")
                }
                precondition(mono == NSFont(descriptor: descriptor, size: 13))
            } else {
                precondition(mono == NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
            }
        }
        print(custom ? "All four custom family routes and native editors passed" : "Configured system designs, sizes, weights, semantic styles, and missing-font fallback passed")
        if !custom {
            self.verifyNativeCoverage()
            self.verifyPackageDesigns()
            if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--specimens" {
                try self.renderSpecimens(to: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
            }
        }
    }

    // CoreText's direct cmap lookup deliberately excludes automatic font fallback.
    static let requiredCharacters = Array("АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯабвгдеёжзийклмнопрстуфхцчшщъыьэюяABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789№«»\u{0301}".utf16)

    static func missingCharacters(in font: NSFont) -> String {
        var glyphs = [CGGlyph](repeating: 0, count: self.requiredCharacters.count)
        CTFontGetGlyphsForCharacters(font as CTFont, self.requiredCharacters, &glyphs, glyphs.count)
        return String(decoding: zip(self.requiredCharacters, glyphs).filter { $0.1 == 0 }.map { $0.0 }, as: UTF16.self)
    }

    static func verifyNativeCoverage() {
        let weights: [NSFont.Weight] = [.ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black]
        var faces = 0
        for design: Font.Design in [.default, .serif, .rounded, .monospaced] {
            for size: CGFloat in [8, 11, 14, 28, 34, 42, 76] {
                for weight in weights {
                    let font = NSFont.fluidFont(ofSize: size, weight: weight, design: design, style: nil)
                    for face in [font, NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)] {
                        let missing = self.missingCharacters(in: face)
                        precondition(missing.isEmpty, "\(face.fontName) at \(size) lacks direct glyphs: \(missing)")
                        faces += 1
                    }
                }
            }
        }
        // A face used only for emoji must fail the same check, even though AppKit can fall back.
        guard let emoji = NSFont(name: "AppleColorEmoji", size: 14) else { preconditionFailure("Missing system emoji face") }
        precondition(!self.missingCharacters(in: emoji).isEmpty)
        print("\(faces) native design/size/weight/italic combinations directly map all 66 Russian letters, Latin, numerals, Russian punctuation and combining stress")
    }

    static func verifyPackageDesigns() {
        func native(_ design: BrandStyle.FontDesign) -> Font.Design {
            switch design { case .sans: .default; case .serif: .serif; case .rounded: .rounded }
        }
        for body in BrandStyle.FontDesign.allCases {
            for title in BrandStyle.FontDesign.allCases {
                let style = BrandStyle(bodyFontDesign: body, titleFontDesign: title)
                precondition(FluidTypography.systemDesign(for: .default, style: style) == native(body))
                precondition(FluidTypography.systemDesign(for: .default, role: .title, style: style) == native(title))
                precondition(FluidTypography.systemDesign(for: .serif, style: style) == native(title))
                precondition(Font.fluidSystem(.title3, style: style) == .system(.title3, design: native(title)))
                precondition(Font.fluidSystem(.caption, style: style) == .system(.caption, design: native(body)))
                for design: Font.Design in [.rounded, .monospaced] {
                    precondition(FluidTypography.systemDesign(for: design, role: .title, style: style) == design)
                }
                let font = NSFont.fluidSystemFont(ofSize: 14, weight: .medium, style: style)
                let titleFont = NSFont.fluidFont(ofSize: 34, weight: .regular, design: .serif, style: style)
                precondition(self.missingCharacters(in: font).isEmpty && self.missingCharacters(in: titleFont).isEmpty)
                precondition(font.pointSize == 14 && titleFont.pointSize == 34)
            }
        }
        print("All 9 body/title package combinations retain sizes, direct Russian glyphs and distinct mono/numeric roles")
    }

    /// Offscreen font specimens, not screenshots of the running app. No window or user data.
    static func renderSpecimens(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let samples = [
            ("pichi", "Sources/Fluid/Branding/brand-package.json"),
            ("sber", "Configuration/BrandExamples/sber-demo.json"),
            ("alfa", "Configuration/BrandExamples/alfa-demo.json"),
        ]
        for (name, path) in samples {
            let package = try BrandPackage.decode(Data(contentsOf: URL(fileURLWithPath: path)))
            let style = package.style
            let width = 1120, height = 980
            let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
            NSColor(calibratedWhite: 0.98, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
            var y: CGFloat = CGFloat(height) - 56
            func draw(_ text: String, font: NSFont, color: NSColor = .black) {
                for line in text.components(separatedBy: "\n") {
                    (line as NSString).draw(at: NSPoint(x: 40, y: y - font.pointSize), withAttributes: [.font: font, .foregroundColor: color])
                    y -= font.pointSize + 12
                }
            }
            func row(_ label: String, _ text: String, font: NSFont) {
                draw(label + " | " + font.fontName, font: .systemFont(ofSize: 11), color: .darkGray)
                draw(text, font: font)
                y -= 18
            }
            draw(package.profile.appName + " | RU / Latin native font specimen", font: .systemFont(ofSize: 19, weight: .semibold))
            y -= 16
            row("Greeting / 34 regular title", "Добрый вечер, Alex. Ёжик и Яков.",
                font: .fluidFont(ofSize: 34, weight: .regular, design: .serif, style: style))
            row("Heading / 22 bold title", "Запись встречи / Meeting recording",
                font: .fluidFont(ofSize: 22, weight: .bold, design: .default, role: .title, style: style))
            row("Body / 14 regular", "Ваши слова и идеи. Your words and ideas. Москва, Alex, №24.",
                font: .fluidSystemFont(ofSize: 14, style: style))
            row("Body strong / 14 medium", "Решения, задачи и сроки / Decisions, tasks and deadlines",
                font: .fluidSystemFont(ofSize: 14, weight: .medium, style: style))
            row("Caption / 12 regular", "Сохранено на вашем Mac. Saved on your Mac.",
                font: .fluidSystemFont(ofSize: 12, style: style))
            let body = NSFont.fluidSystemFont(ofSize: 16, style: style)
            row("Italic / 16", "Русский текст, English text: ёЁ, «да», cafe\u{0301}.",
                font: NSFontManager.shared.convert(body, toHaveTrait: .italicFontMask))
            row("Numeric / 28 rounded semibold", "1 240 слов / words | 24 мин / min",
                font: .fluidFont(ofSize: 28, weight: .semibold, design: .rounded, style: style))
            row("Code and transcript / 14 monospaced", "Счёт №24 | UTF-8 | ёЁ | Москва | Alex",
                font: .fluidFont(ofSize: 14, weight: .regular, design: .monospaced, style: style))
            row("Russian alphabet / direct cmap validated", "АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ\nабвгдеёжзийклмнопрстуфхцчшщъыьэюя",
                font: .fluidSystemFont(ofSize: 15, style: style))
            NSGraphicsContext.restoreGraphicsState()
            let data = image.representation(using: .png, properties: [:])!
            let target = directory.appendingPathComponent("font-specimen-\(name).png")
            try data.write(to: target)
            print("Rendered native specimen: \(target.path)")
        }
    }
}
