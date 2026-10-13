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
                let surface = AppTheme.adaptive(accent: theme.palette.accent, colorScheme: .dark).palette.cardBackground
                let expected = try XCTUnwrap(NSColor(surface).usingColorSpace(.sRGB))
                let width: CGFloat = 30
                let padding: CGFloat = 24
                let renderer = ImageRenderer(content: DictationMutedIndicator()
                    .appTheme(theme)
                    .environment(\.locale, Locale(identifier: language))
                    .environment(\.colorScheme, scheme)
                    .frame(width: width)
                    .padding(padding))
                renderer.scale = 1
                let image = try XCTUnwrap(renderer.cgImage)
                let bitmap = NSBitmapImageRep(cgImage: image)
                var inkPixels = 0
                for x in 0..<image.width {
                    for y in 0..<image.height {
                        let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y))
                        guard color.alphaComponent > 0.05 else { continue }
                        inkPixels += 1
                        XCTAssertGreaterThanOrEqual(x, Int(padding), "\(language)/\(scheme): label overflowed narrow waveform")
                        XCTAssertLessThan(x, Int(padding + width), "\(language)/\(scheme): label overflowed narrow waveform")
                    }
                }
                XCTAssertGreaterThan(inkPixels, 12, "Indicator must render, not silently disappear")
                // This point is inside the fallback icon circle, beyond the
                // microphone glyph. A clear-glass-only icon has no paired surface.
                let actual = try XCTUnwrap(bitmap.colorAt(x: image.width / 2 + 8, y: image.height / 2)?.usingColorSpace(.sRGB))
                XCTAssertGreaterThan(actual.alphaComponent, 0.95)
                XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.02)
                XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.02)
                XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.02)
                let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
                attachment.name = "muted-indicator-narrow-\(language)-\(scheme)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
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
