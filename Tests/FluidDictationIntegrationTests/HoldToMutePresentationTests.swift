import AppKit
@testable import FluidVoice_Debug
import SwiftUI
import XCTest

@MainActor
final class HoldToMutePresentationTests: XCTestCase {
    func testLocalizedMutedIndicatorFitsNarrowWidthWithOpaqueIconSurface() throws {
        // Render the production SwiftUI indicator itself. This intentionally
        // excludes the native glass overlay, whose final contrast needs E2E.
        for language in ["en", "ru"] {
            for scheme in [ColorScheme.light, .dark] {
                let theme = AppTheme.adaptive(accent: FluidBrandColors.blue, colorScheme: scheme)
                let overlayTheme = AppTheme.adaptive(accent: theme.palette.accent, colorScheme: .dark)
                // Resolve palette colors through the same renderer/environment as
                // the indicator. NSBitmapImageRep.colorAt can report calibrated
                // RGB for sRGB image bytes; converting it can reinterpret them.
                let reference = try self.srgbRaster(HStack(spacing: 0) {
                    overlayTheme.palette.cardBackground.frame(width: 3, height: 3)
                    overlayTheme.palette.warning.frame(width: 3, height: 3)
                }
                .appTheme(theme)
                .environment(\.locale, Locale(identifier: language))
                .environment(\.colorScheme, .dark))
                let expected = self.srgbPixel(reference, x: 1, y: 1)
                let warning = self.srgbPixel(reference, x: 4, y: 1)
                XCTAssertGreaterThan(expected[3], 0.95)
                XCTAssertGreaterThan(warning[3], 0.95)
                let width: CGFloat = 30
                let padding: CGFloat = 24
                let rendered = try self.srgbRaster(DictationMutedIndicator()
                    .appTheme(theme)
                    .environment(\.locale, Locale(identifier: language))
                    .environment(\.colorScheme, scheme)
                    .frame(width: width)
                    .padding(padding))
                let image = rendered.image
                let bitmap = NSBitmapImageRep(cgImage: image)
                var inkPixels = 0
                var warningPixels = 0
                for x in 0..<image.width {
                    for y in 0..<image.height {
                        let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y))
                        guard color.alphaComponent > 0.05 else { continue }
                        inkPixels += 1
                        XCTAssertGreaterThanOrEqual(x, Int(padding), "\(language)/\(scheme): label overflowed narrow waveform")
                        XCTAssertLessThan(x, Int(padding + width), "\(language)/\(scheme): label overflowed narrow waveform")
                        let pixel = self.srgbPixel(rendered, x: x, y: y)
                        if pixel[3] > 0.95, (0..<3).allSatisfy({ abs(pixel[$0] - warning[$0]) < 0.02 }) {
                            warningPixels += 1
                        }
                    }
                }
                XCTAssertGreaterThan(inkPixels, 12, "Indicator must render, not silently disappear")
                XCTAssertGreaterThanOrEqual(warningPixels, 4, "The mute glyph must render, not just its circle")
                // This point is inside the fallback icon circle, beyond the
                // microphone glyph. A clear-glass-only icon has no paired surface.
                let actual = self.srgbPixel(rendered, x: image.width / 2 + 8, y: image.height / 2)
                XCTAssertGreaterThan(actual[3], 0.95)
                for channel in 0..<3 {
                    XCTAssertEqual(actual[channel], expected[channel], accuracy: 0.02)
                }
                let lights = [self.relativeLuminance(warning), self.relativeLuminance(actual)]
                XCTAssertGreaterThanOrEqual((lights.max()! + 0.05) / (lights.min()! + 0.05), 3,
                                            "Mute icon must contrast with its actual opaque surface")
                let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
                attachment.name = "muted-indicator-narrow-\(language)-\(scheme)"
                attachment.lifetime = .keepAlways
                add(attachment)
                let referenceBitmap = NSBitmapImageRep(cgImage: reference.image)
                let referenceAttachment = XCTAttachment(data: try XCTUnwrap(referenceBitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
                referenceAttachment.name = "muted-indicator-palette-reference-\(language)-\(scheme)"
                referenceAttachment.lifetime = .keepAlways
                add(referenceAttachment)
            }
        }
    }

    private func srgbRaster(_ view: some View) throws -> (image: CGImage, pixels: [UInt8]) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: &pixels, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (image, pixels)
    }

    private func srgbPixel(_ raster: (image: CGImage, pixels: [UInt8]), x: Int, y: Int) -> [CGFloat] {
        let index = (y * raster.image.width + x) * 4
        let alpha = CGFloat(raster.pixels[index + 3]) / 255
        let channels = (0..<3).map { alpha > 0 ? CGFloat(raster.pixels[index + $0]) / 255 / alpha : 0 }
        return channels + [alpha]
    }

    private func relativeLuminance(_ color: [CGFloat]) -> CGFloat {
        let linear = color.prefix(3).map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
    }

    func testMutedOverlayFitsEverySizeAndPreservesPreview() throws {
        let state = NotchContentState.shared
        let settings = SettingsStore.shared
        let priorSize = settings.overlaySize
        let priorMuted = state.isDictationMuted
        let priorText = state.transcriptionText
        let priorProcessing = state.isProcessing
        let priorMode = state.mode
        defer {
            settings.overlaySize = priorSize
            state.isDictationMuted = priorMuted
            state.updateTranscription(priorText)
            state.isProcessing = priorProcessing
            state.mode = priorMode
        }
        state.mode = .dictation
        state.isProcessing = false
        state.isDictationMuted = true
        state.updateTranscription("This is the thought I want to keep.")

        for size in SettingsStore.OverlaySize.allCases {
            settings.overlaySize = size
            for scheme in [ColorScheme.light, .dark] {
                let layout = BottomOverlayView.LayoutConstants.get(for: size)
                let view = BottomOverlayView()
                    .padding(24)
                    .frame(width: max(400, layout.overlayWidth + 48), height: max(220, layout.overlayHeight + 80))
                    .background(scheme == .dark ? Color(white: 0.08) : Color(white: 0.94))
                    .appTheme(.adaptive(accent: FluidBrandColors.blue, colorScheme: scheme))
                    .environment(\.colorScheme, scheme)
                let host = NSHostingView(rootView: view)
                host.frame.size = host.fittingSize
                host.layoutSubtreeIfNeeded()
                XCTAssertTrue(host.frame.width.isFinite)
                XCTAssertTrue(host.frame.height.isFinite)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = "hold-to-mute-\(size.rawValue)-\(scheme)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        XCTAssertEqual(state.transcriptionText, "This is the thought I want to keep.")
        XCTAssertTrue(state.isDictationMuted)
    }
}
